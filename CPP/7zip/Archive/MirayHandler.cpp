// MirayHandler.cpp - MFI/MAI disk-image reader

#include "StdAfx.h"

#include "../../../C/7zCrc.h"
#include "../../../C/Alloc.h"
#include "../../../C/Aes.h"
#include "../../../C/CpuArch.h"
#include "../../../C/LzmaDec.h"
#include "../../../C/Sha256.h"
#include "../../../C/Sha3.h"

#include "../../Common/ComTry.h"
#include "../../Common/IntToString.h"
#include "../../Common/MyBuffer.h"
#include "../../Common/UTFConvert.h"
#include "../../Windows/PropVariant.h"

#include "../Common/RegisterArc.h"
#include "../Common/CreateCoder.h"
#include "../Common/LimitedStreams.h"
#include "../Common/ProgressUtils.h"
#include "../Common/StreamObjects.h"
#include "../Common/StreamUtils.h"
#include "../Compress/ZlibDecoder.h"
#include "../Compress/CopyCoder.h"
#include "../IPassword.h"
#include "HandlerCont.h"
#include "Common/MultiStream.h"

using namespace NWindows;

namespace NArchive {
namespace NExt {
API_FUNC_IsArc IsArc_Ext(const Byte *data, size_t size);
}
namespace NMiray {

static const UInt32 kMetadataLimit = 1 << 24;
static const UInt32 kBlockLimit = 1 << 26;
static const unsigned kItemLimit = 1 << 20;
static const Byte kSignatures[] = { 4, 'M', 'S', 'F', 'C', 4, 'H', 'S', 'A', 'M',
    4, 'X', 'S', 'A', 'M', 4, 'M', 'F', 'I', 'C', 4, 'I', 'M', 'G', 'C' };
static const Byte kMsfcSignature[] = {
  'M', 'S', 'F', 'C', 0x61, 0x11, 0x5b, 0xc7, 0xb1, 0xf6,
  0x7a, 0x4a, 0x92, 0xfb, 0xac, 0xd3, 0x73, 0x71, 0x3e, 0x06
};
// Image-format wrapping slot 9.
static const Byte kImageWrapKey[32] = {
  0x47,0x5a,0xdf,0x9b,0x87,0x70,0x3a,0x15,0x31,0xfe,0xd1,0x8d,0xd2,0x73,0x12,0xf9,
  0x54,0xa7,0x40,0x7c,0x59,0x28,0x2b,0x13,0x75,0x15,0xcf,0xb6,0xd5,0x77,0x9a,0x60
};

// Legacy image-format wrapping slot 5.
static const Byte kLegacyImageWrapKey[32] = {
  0xde,0x06,0x46,0xa3,0xa1,0xc2,0xad,0xd3,0x36,0x73,0x0e,0x71,0xf3,0x33,0x3f,0x34,
  0xbc,0x8b,0xfc,0x20,0x3e,0xe8,0x73,0x1b,0xe6,0x06,0xfc,0x08,0xc1,0x14,0x92,0xf2
};

static const Byte *GetImageWrapKey(UInt32 slot)
{
  return slot == 9 ? kImageWrapKey : slot == 5 ? kLegacyImageWrapKey : NULL;
}

static void HashKeyData(CSha256 *hash, const Byte *data, size_t size)
{
  // Metadata fields can be unaligned. Short updates use the hash's aligned buffer.
  while (size)
  {
    const size_t take = size < 64 ? size : 63;
    Sha256_Update(hash, data, take);
    data += take;
    size -= take;
  }
}

#define MIRAY_CHECK(c) if (!(c)) return S_FALSE;

// Byte loads support unaligned disk fields.
static UInt16 Read16(const Byte *p)
{
  return (UInt16)((UInt16)p[0] | ((UInt16)p[1] << 8));
}

static UInt32 Read32(const Byte *p)
{
  return (UInt32)p[0] | ((UInt32)p[1] << 8)
      | ((UInt32)p[2] << 16) | ((UInt32)p[3] << 24);
}

static UInt32 ReadKeyField(const Byte *entry, unsigned offset)
{
  return Read32(entry + 4) >= offset + 4 ? Read32(entry + offset) : 0;
}

static UInt64 Read64(const Byte *p)
{
  return (UInt64)Read32(p) | ((UInt64)Read32(p + 4) << 32);
}

static UInt64 ReadNumber(const Byte *data, UInt32 size)
{
  UInt64 value = 0;
  for (UInt32 i = 0; i < size; i++)
    value |= (UInt64)data[i] << (i * 8);
  return value;
}

static bool ReadText(const Byte *data, UInt32 size, UInt32 encoding, AString &text)
{
  UString unicode;
  if (encoding == 1)
  {
    text.SetFrom((const char *)data, size);
    return ConvertUTF8ToUnicode(text, unicode);
  }
  if (encoding != 0)
    return false;
  for (UInt32 i = 0; i < size; i++)
    unicode += (wchar_t)(UInt16)(Int16)(signed char)data[i];
  ConvertUnicodeToUTF8(unicode, text);
  return true;
}

struct CExtent
{
  UInt64 Offset;
  UInt64 Size;
};

struct COverlayMap
{
  UInt64 Size;
  unsigned Width;
  unsigned Levels;
  UInt32 Entries[6];
  UInt64 Span[6];
  UInt64 End;
};

struct CImageStream
{
  AString Name;
  UInt64 Size;
  CRecordVector<CExtent> Extents;
};

static void AddChunkExtent(CImageStream &stream, UInt64 offset, UInt64 size)
{
  if (!stream.Extents.IsEmpty()
      && stream.Extents.Back().Offset + stream.Extents.Back().Size == offset)
    stream.Extents.Back().Size += size;
  else
  {
    CExtent extent;
    extent.Offset = offset;
    extent.Size = size;
    stream.Extents.Add(extent);
  }
}

struct CImageChecksum
{
  unsigned StreamIndex;
  unsigned Method;
  bool Physical;
  Byte Digest[32];
};

static const unsigned kDigestSizes[] = { 16, 20, 32, 32 };
static const unsigned kRegionDigestSizes[] = { 0, 4, 16, 20, 32, 64, 32, 64 };

struct CRegionChecksum
{
  UInt32 Method;
  Byte Digest[64];
};

struct CBlock
{
  UInt64 Virt;
  UInt64 Pos;
  UInt32 Packed;
  UInt32 Unpacked;
  unsigned Part;
  bool Compressed;
};

static int CompareBlocks(const CBlock *a, const CBlock *b, void *)
{
  return a->Virt < b->Virt ? -1 : a->Virt == b->Virt ? 0 : 1;
}

struct CPart
{
  AString Name;
  AString MaskName;
  UInt64 Base;
  UInt64 Sectors;
  UInt64 Stored;
  UInt64 Last;
  UInt64 StoredBytes;
  UInt32 Method;
  UInt32 Kind;
  unsigned StreamIndex;
  Byte LzmaProps[LZMA_PROPS_SIZE];
  bool HasLzmaProps;
  bool HasLast;
  bool HasStoredBytes;
  bool Incomplete;
  bool Uninitialized;
  bool Progress;
  bool Damaged;
  CRecordVector<CExtent> Errors;
  CRecordVector<CRegionChecksum> Checksums;
  bool IsMapped() const { return Kind >= 11 && Kind <= 13; }
  CPart(): Base(0), Sectors(0), Stored(0), Last(0), StoredBytes(0), Method(0), Kind(0), StreamIndex(0),
      HasLzmaProps(false), HasLast(false), HasStoredBytes(false), Incomplete(false), Uninitialized(false), Progress(false), Damaged(false) {}
};

static int CompareExtents(const CExtent *a, const CExtent *b, void *)
{
  return a->Offset < b->Offset ? -1 : a->Offset == b->Offset ? 0 : 1;
}

static void MergeExtents(CRecordVector<CExtent> &ranges)
{
  ranges.Sort(CompareExtents, NULL);
  unsigned count = 0;
  FOR_VECTOR (i, ranges)
  {
    const CExtent range = ranges[i];
    if (count && range.Offset <= ranges[count - 1].Offset + ranges[count - 1].Size)
    {
      CExtent &previous = ranges[count - 1];
      if (range.Offset + range.Size > previous.Offset + previous.Size)
        previous.Size = range.Offset + range.Size - previous.Offset;
    }
    else
      ranges[count++] = range;
  }
  ranges.DeleteFrom(count);
}

static bool ReadAreaList(const Byte *list, UInt32 length, CRecordVector<CExtent> &ranges, bool ordered = true)
{
  if (length < 8 || Read32(list) != 1)
    return false;
  const UInt32 count = Read32(list + 4);
  if (count > kItemLimit || (UInt64)8 + (UInt64)count * 16 != length
      || ranges.Size() > kItemLimit - count)
    return false;
  UInt64 end = 0;
  for (UInt32 i = 0; i < count; i++)
  {
    CExtent range;
    range.Offset = Read64(list + 8 + (size_t)i * 16);
    range.Size = Read64(list + 16 + (size_t)i * 16);
    if (!range.Size || range.Offset > (UInt64)-1 - range.Size || (ordered && range.Offset < end))
      return false;
    ranges.Add(range);
    end = range.Offset + range.Size;
  }
  return true;
}

static bool IsUnavailableRange(const CPart &part, UInt64 start, UInt64 end)
{
  if (start == end)
    return true;
  unsigned low = 0, high = part.Errors.Size();
  while (low < high)
  {
    const unsigned mid = low + (high - low) / 2;
    if (part.Errors[mid].Offset <= start)
      low = mid + 1;
    else
      high = mid;
  }
  for (unsigned i = low ? low - 1 : 0; i < part.Errors.Size(); i++)
  {
    const CExtent &error = part.Errors[i];
    if (error.Offset > start)
      return false;
    const UInt64 stop = error.Offset + error.Size;
    if (stop > start)
    {
      if (stop >= end)
        return true;
      start = stop;
    }
  }
  return false;
}

static bool CheckZeroCrc(CByteBuffer &data)
{
  const UInt32 crc = Read32(data + 8);
  SetUi32(data + 8, 0);
  const bool result = CrcCalc(data, data.Size()) == crc;
  SetUi32(data + 8, crc);
  return result;
}

static bool CheckMaiRecordCrc(CByteBuffer &data)
{
  const UInt32 size = Read32(data + 4);
  if (size < 12 || size > data.Size())
    return false;
  const UInt32 crc = Read32(data + 8);
  SetUi32(data + 8, 0);
  const bool result = CrcCalc(data, size) == crc;
  SetUi32(data + 8, crc);
  return result;
}

static bool Lz4Length(const Byte *src, size_t size, size_t &pos, size_t limit, size_t &length)
{
  if (length == 15)
    for (;;)
    {
      if (pos == size)
        return false;
      const unsigned n = src[pos++];
      if (length > limit || n > limit - length)
        return false;
      length += n;
      if (n != 255)
        break;
    }
  return length <= limit;
}

static bool CheckPadding(size_t size, size_t consumed, bool encrypted)
{
  return consumed == size || (encrypted && consumed < size && size - consumed < AES_BLOCK_SIZE);
}

static bool DecodeLz4(const Byte *src, size_t size, Byte *dest, size_t expected, bool encrypted)
{
  size_t pos = 0, out = 0;
  while (pos < size)
  {
    const unsigned token = src[pos++];
    size_t length = token >> 4;
    if (!Lz4Length(src, size, pos, expected - out, length)
        || length > size - pos)
      return false;
    memcpy(dest + out, src + pos, length);
    out += length;
    pos += length;
    if (encrypted && out == expected)
      return CheckPadding(size, pos, true);
    if (pos == size)
      return out == expected;
    if (size - pos < 2)
      return false;
    const unsigned distance = Read16(src + pos);
    pos += 2;
    if (distance == 0 || distance > out)
      return false;
    length = token & 15;
    if (!Lz4Length(src, size, pos, expected - out, length)
        || expected - out < 4 || length > expected - out - 4)
      return false;
    length += 4;
    const size_t origin = out - distance;
    while (length)
    {
      const size_t available = out - origin;
      const size_t take = length < available ? length : available;
      memcpy(dest + out, dest + origin, take);
      out += take;
      length -= take;
    }
  }
  return out == expected;
}

static void HashPassword(const Byte *data, size_t size, const Byte *salt, Byte *digest)
{
  CSha256 hash;
  Sha256_Init(&hash);
  if (salt)
    Sha256_Update(&hash, salt, SHA256_DIGEST_SIZE);
  Sha256_Update(&hash, data, size);
  Sha256_Final(&hash, digest);
}

static bool DecryptEcb(Byte *data, size_t size, const Byte *key, unsigned keySize)
{
  if (size % AES_BLOCK_SIZE)
    return false;
  MY_ALIGN(16) UInt32 aes[AES_NUM_IVMRK_WORDS];
  MY_ALIGN(16) Byte buffer[4096];
  Aes_SetKey_Dec(aes + 4, key, keySize);
  while (size)
  {
    const size_t take = size < sizeof(buffer) ? size : sizeof(buffer);
    memcpy(buffer, data, take);
    memset(aes, 0, AES_BLOCK_SIZE);
    // Undo CBC's previous-block xor to obtain ECB using the existing AES code.
    // Ciphertext remains intact until the decrypted bytes are copied back.
    g_AesCbc_Decode(aes, buffer, take / AES_BLOCK_SIZE);
    for (size_t i = AES_BLOCK_SIZE; i < take; i++)
      buffer[i] ^= data[i - AES_BLOCK_SIZE];
    memcpy(data, buffer, take);
    data += take;
    size -= take;
  }
  memset(aes, 0, sizeof(aes));
  memset(buffer, 0, sizeof(buffer));
  return true;
}

static HRESULT AddVolumeRange(CMultiStream *combined, IInStream *input, UInt64 offset, UInt64 size)
{
  CMyComPtr2<IInStream, CLimitedInStream> limited;
  limited.Create_if_Empty();
  limited->SetStream(input);
  RINOK(limited->InitAndSeek(offset, size))
  CMultiStream::CSubStreamInfo entry;
  entry.Stream = limited;
  entry.Size = size;
  combined->Streams.Add(entry);
  return S_OK;
}

static void AddVolumeRecord(CMultiStream *combined, const Byte *data)
{
  CReferenceBuf *reference = new CReferenceBuf;
  CMyComPtr<IUnknown> owner = reference;
  reference->Buf.CopyFrom(data, 4096);
  CMyComPtr2<IInStream, CBufInStream> input;
  input.Create_if_Empty();
  input->Init(reference);
  CMultiStream::CSubStreamInfo entry;
  entry.Stream = input;
  entry.Size = 4096;
  combined->Streams.Add(entry);
}

class CEmbeddedViewStream;

Z7_class_CHandler_final:
  public IInArchive,
  public IInArchiveGetStream,
  public IInStream,
  public CMyUnknownImp
{
  friend class CEmbeddedViewStream;
  Z7_COM_UNKNOWN_IMP_4(IInArchive, IInArchiveGetStream, ISequentialInStream, IInStream)
  Z7_IFACE_COM7_IMP(IInArchive_Img)
  Z7_IFACE_COM7_IMP(IInArchiveGetStream)
  Z7_IFACE_COM7_IMP(ISequentialInStream)
  Z7_COM7F_IMP(GetNumberOfItems(UInt32 *numItems))
  Z7_COM7F_IMP(Extract(const UInt32 *indices, UInt32 numItems, Int32 testMode, IArchiveExtractCallback *extractCallback))
  Z7_COM7F_IMP(Open(IInStream *stream, const UInt64 *maxCheckStartPosition, IArchiveOpenCallback *openCallback))
  Z7_COM7F_IMP(Seek(Int64 offset, UInt32 seekOrigin, UInt64 *newPosition))

  CMyComPtr<IInStream> Stream;
  UInt64 _virtPos, _size;
  const char *_imgExt;
  bool _stream_unavailData, _stream_unsupportedMethod, _stream_dataError;
  bool _damaged;

  void Reset_VirtPos() { _virtPos = 0; }
  void ClearStreamVars()
  {
    _stream_unavailData = _stream_unsupportedMethod = _stream_dataError = false;
  }
  void ResetDiskView()
  {
    _virtPos = _size = 0;
    _imgExt = NULL;
    _damaged = false;
    ClearStreamVars();
  }

  CObjectVector<CImageStream> _streams;
  CObjectVector<CPart> _parts;
  CRecordVector<CExtent> _maiVolumes;
  CObjectVector<CByteBuffer> _maiVolumeRecords;
  CRecordVector<CImageChecksum> _maiChecksums;
  CSha256 _keyPrefixHash;
  CRecordVector<CBlock> _blocks;
  CRecordVector<CBlock> _embeddedBlocks;
  unsigned _embeddedStream;
  CRecordVector<CExtent> _unavailable;
  UInt64 _phySize;
  UInt64 _totalPhysicalSize;
  UInt64 _firstPhysicalSize;
  UInt32 _numVolumes;
  UInt32 _maiChunkSize;
  UInt32 _maiMaxChunks;
  UInt64 _splitSize;
  UInt32 _sectorSize;
  UInt32 _method;
  UInt32 _version;
  unsigned _cacheIndex;
  unsigned _depth;
  bool _isMai;
  bool _maiRecovered;
  bool _smart;
  bool _regionGaps;
  bool _dependent;
  bool _overlay;
  bool _growableMfi;
  bool _legacyDirectory;
  bool _skipLegacyOverlays;
  UInt32 _encryption;
  UInt32 _passwordType;
  bool _protected;
  bool _hasKeyStore;
  bool _baseEncrypted;
  CByteBuffer _salt, _verifier, _keyStore, _key;
  CByteBuffer _imageId, _baseId;
  UString _parentName, _sourceName;
  CMyComPtr<IInStream> _base;
  CMyComPtr<IInStream> _legacyComposite;
  CByteBuffer _cache;
  CByteBuffer _packed;
  CMyComPtr2<ISequentialInStream, CBufInStream> _bufIn;
  CMyComPtr2<ISequentialOutStream, CBufPtrSeqOutStream> _bufOut;
  CMyComPtr2<ICompressCoder, NCompress::NZlib::CDecoder> _zlib;

  HRESULT ReadAt(UInt64 pos, void *data, size_t size)
  {
    MIRAY_CHECK(pos <= _phySize && size <= _phySize - pos)
    RINOK(InStream_SeekSet(Stream, pos))
    return ReadStream_FALSE(Stream, data, size);
  }

  HRESULT ReadData(const CImageStream &s, UInt64 pos, void *data, size_t size)
  {
    MIRAY_CHECK(pos <= s.Size && size <= s.Size - pos)
    Byte *dest = (Byte *)data;
    FOR_VECTOR (i, s.Extents)
    {
      const CExtent &e = s.Extents[i];
      if (pos >= e.Size)
      {
        pos -= e.Size;
        continue;
      }
      const size_t take = (UInt64)size < e.Size - pos ? size : (size_t)(e.Size - pos);
      RINOK(ReadAt(e.Offset + pos, dest, take))
      size -= take;
      dest += take;
      if (!size)
        return S_OK;
      pos = 0;
    }
    return size == 0 ? S_OK : S_FALSE;
  }

  HRESULT CheckStream(const CImageStream &s)
  {
    MIRAY_CHECK(!s.Name.IsEmpty())
    UInt64 total = 0;
    FOR_VECTOR (i, s.Extents)
    {
      const CExtent &e = s.Extents[i];
      MIRAY_CHECK(e.Offset <= _phySize && e.Size <= _phySize - e.Offset)
      MIRAY_CHECK(total <= (UInt64)(Int64)-1 - e.Size)
      total += e.Size;
    }
    MIRAY_CHECK(total >= s.Size)
    for (unsigned i = 0; i + 1 < _streams.Size(); i++)
      MIRAY_CHECK(s.Name != _streams[i].Name)
    return S_OK;
  }

  HRESULT OpenMfi(IArchiveOpenCallback *openCallback);
  HRESULT OpenLegacy(IArchiveOpenCallback *openCallback);
  HRESULT OpenLegacyStream(IArchiveOpenVolumeCallback *callback, const UString &name,
      CMyComPtr<IInStream> &input, UInt64 &size);
  HRESULT ReadDirectoryData(const CImageStream &directory, UInt64 base,
      UInt64 chunk, UInt64 position, void *data, size_t size)
  {
    MIRAY_CHECK(position <= directory.Size && size <= directory.Size - position)
    if (position < chunk && size <= chunk - position)
      return ReadAt(base + position, data, size);
    return ReadData(directory, position, data, size);
  }
  HRESULT OpenVolumes(const Byte *header, IArchiveOpenCallback *openCallback);
  HRESULT OpenMai(IArchiveOpenCallback *openCallback);
  HRESULT FindMaiRecovery(const Byte *header, UInt64 &position, UInt64 &size);
  HRESULT OpenMaiVolumes(const Byte *header, const Byte *footer, IArchiveOpenCallback *openCallback);
  HRESULT ReadMaiChecksums(const CByteBuffer &descriptor, UInt32 offset, UInt32 size,
      unsigned streamIndex, bool physical = false);
  HRESULT VerifyMaiChecksums();
  HRESULT ReadMetadata();
  HRESULT ReadKeyStore(CRecordVector<UInt32> &offsets);
  HRESULT OpenBase(IArchiveOpenCallback *openCallback);
  HRESULT Unlock(IArchiveOpenCallback *openCallback);
  HRESULT ReadBlocks();
  HRESULT VerifyRegionChecksums();
  HRESULT ReadPartBlocks(unsigned partIndex);
  HRESULT ReadOverlay(CRecordVector<CBlock> &blocks, unsigned &streamIndex);
  HRESULT ReadMsff(unsigned headerIndex, UInt64 logicalSize,
      CRecordVector<CBlock> &blocks, unsigned &streamIndex);
  HRESULT ReadLegacyMask(CRecordVector<CBlock> &blocks, unsigned &streamIndex,
      const AString &dataName, const AString &maskName);
  HRESULT OpenLegacyOverlay(IArchiveOpenCallback *openCallback);
  HRESULT ReadOverlayTable(unsigned streamIndex, const COverlayMap &map,
      unsigned level, UInt64 position, UInt64 virt,
      unsigned &items, CRecordVector<CBlock> &blocks);
  HRESULT ReadView(bool overlay, UInt64 position, void *data, UInt32 size, UInt32 *processedSize);
  HRESULT DecodeBlock(unsigned index);
  HRESULT OpenStructure(IInStream *stream, IArchiveOpenCallback *openCallback);
  HRESULT OpenContent(IArchiveOpenCallback *openCallback);
  HRESULT Open2(IInStream *stream, IArchiveOpenCallback *openCallback);
public:
  CHandler(): _embeddedStream((unsigned)-1),
      _phySize(0), _totalPhysicalSize(0), _firstPhysicalSize(0), _numVolumes(1),
      _maiChunkSize(0), _maiMaxChunks(0),
      _splitSize((UInt64)(Int64)-1),
      _sectorSize(512), _method(0), _version(0),
      _cacheIndex((unsigned)-1), _depth(0), _isMai(false), _maiRecovered(false), _smart(false), _regionGaps(false), _dependent(false),
      _overlay(false), _growableMfi(false), _legacyDirectory(false), _skipLegacyOverlays(false),
      _encryption(0), _passwordType((UInt32)-1), _protected(false), _hasKeyStore(false),
      _baseEncrypted(false) { ResetDiskView(); }
  ~CHandler() { Close(); }
};

Z7_CLASS_IMP_COM_1(CEmbeddedViewStream, IInStream)
  Z7_IFACE_COM7_IMP(ISequentialInStream)
  CMyComPtr<IInStream> _owner;
  CHandler *_handler;
  UInt64 _position, _size;
  bool _overlay;
public:
  CEmbeddedViewStream(CHandler *handler, UInt64 size, bool overlay):
      _owner(handler), _handler(handler), _position(0), _size(size), _overlay(overlay) {}
};

Z7_COM7F_IMF(CEmbeddedViewStream::Read(void *data, UInt32 size, UInt32 *processedSize))
{
  UInt32 processed = 0;
  const HRESULT result = _handler->ReadView(_overlay, _position, data, size, &processed);
  _position += processed;
  if (processedSize)
    *processedSize = processed;
  if (result == S_OK && size && !processed && _position < _size)
    return S_FALSE;
  return result;
}

Z7_COM7F_IMF(CEmbeddedViewStream::Seek(Int64 offset, UInt32 origin, UInt64 *newPosition))
{
  UInt64 position;
  if (origin == STREAM_SEEK_SET)
    position = 0;
  else if (origin == STREAM_SEEK_CUR)
    position = _position;
  else if (origin == STREAM_SEEK_END)
    position = _size;
  else
    return STG_E_INVALIDFUNCTION;
  if (offset < 0)
  {
    const UInt64 backwards = (UInt64)(-(offset + 1)) + 1;
    if (backwards > position)
      return HRESULT_WIN32_ERROR_NEGATIVE_SEEK;
    position -= backwards;
  }
  else
  {
    if ((UInt64)offset > ((UInt64)1 << 63) - 1 - position)
      return E_INVALIDARG;
    position += (UInt64)offset;
  }
  _position = position;
  if (newPosition)
    *newPosition = position;
  return S_OK;
}

HRESULT CHandler::OpenVolumes(const Byte *header, IArchiveOpenCallback *openCallback)
{
  const UInt64 count64 = Read64(header + 60);
  const UInt64 total = Read64(header + 52), base = Read32(header + 24);
  MIRAY_CHECK(openCallback && count64 > 1 && count64 <= 1024
      && base + Read64(header + 28) == _phySize && total <= ((UInt64)1 << 60) - base)
  const UInt32 count = (UInt32)count64;
  Z7_DECL_CMyComPtr_QI_FROM(IArchiveOpenVolumeCallback, callback, openCallback)
  MIRAY_CHECK(callback)
  NCOM::CPropVariant prop;
  RINOK(callback->GetProperty(kpidName, &prop))
  MIRAY_CHECK(prop.vt == VT_BSTR)
  const UString name = _sourceName.IsEmpty() ? UString(prop.bstrVal) : _sourceName;
  UString lower(name);
  lower.MakeLower_Ascii();
  MIRAY_CHECK(name.Len() > 6)
  const bool differentialName = StringsAreEqual_Ascii(lower.RightPtr(4), ".mfd");
  MIRAY_CHECK(differentialName || StringsAreEqual_Ascii(lower.RightPtr(4), ".mfi"))
  const unsigned end = name.Len() - 4;
  unsigned start = end;
  while (start && name[start - 1] >= L'0' && name[start - 1] <= L'9')
    start--;
  const unsigned width = end - start;
  MIRAY_CHECK(start && width > 0 && width <= 6 && name[start - 1] == L'.' && name[end - 1] == L'1')
  for (unsigned i = start; i + 1 < end; i++)
    MIRAY_CHECK(name[i] == L'0')
  CMyComPtr2<IInStream, CMultiStream> combined;
  combined.Create_if_Empty();
  CMultiStream::CSubStreamInfo first;
  first.Stream = Stream;
  first.Size = _phySize;
  RINOK(InStream_SeekSet(Stream, 0))
  combined->Streams.Add(first);
  UInt64 offset = Read64(header + 28);
  _splitSize = Read64(header + 68);
  _numVolumes = count;
  MIRAY_CHECK(_splitSize > 0)
  for (UInt32 index = 1; index < count; index++)
  {
    wchar_t digits[16];
    ConvertUInt32ToString(index + 1, digits);
    UString next = name.Left(start);
    const unsigned numDigits = (unsigned)wcslen(digits);
    for (unsigned i = numDigits; i < width; i++)
      next += L'0';
    next += digits;
    next += differentialName ? L".mfds" : L".mfis";
    CMyComPtr<IInStream> input;
    RINOK(callback->GetStream(next, &input))
    MIRAY_CHECK(input)
    UInt64 physical;
    RINOK(InStream_GetSize_SeekToEnd(input, physical))
    RINOK(InStream_SeekSet(input, 0))
    Byte h[112];
    RINOK(ReadStream_FALSE(input, h, sizeof(h)))
    MIRAY_CHECK(memcmp(h, header, 24) == 0 && memcmp(h + 36, header + 36, 16) == 0
        && CrcCalc(h, 108) == Read32(h + 108))
    const UInt64 dataBase = Read32(h + 24), length = Read64(h + 28);
    MIRAY_CHECK(dataBase >= sizeof(h) && length > 0 && dataBase <= physical
        && length == physical - dataBase && Read64(h + 76) == index
        && Read64(h + 84) == offset && Read64(h + 52) == 0
        && offset <= total && length <= total - offset
        && physical <= ((UInt64)1 << 60) - _totalPhysicalSize)
    CMyComPtr2<IInStream, CLimitedInStream> limited;
    limited.Create_if_Empty();
    limited->SetStream(input);
    RINOK(limited->InitAndSeek(dataBase, length))
    CMultiStream::CSubStreamInfo entry;
    entry.Stream = limited;
    entry.Size = length;
    combined->Streams.Add(entry);
    offset += length;
    _totalPhysicalSize += physical;
  }
  MIRAY_CHECK(offset == total)
  RINOK(combined->Init())
  Stream = combined;
  _phySize = base + total;
  return S_OK;
}

HRESULT CHandler::OpenMfi(IArchiveOpenCallback *openCallback)
{
  Byte h[112];
  RINOK(ReadAt(0, h, sizeof(h)))
  MIRAY_CHECK(memcmp(h, kMsfcSignature, sizeof(kMsfcSignature)) == 0
      && Read32(h + 20) == 1 && CrcCalc(h, 108) == Read32(h + 108))
  const UInt64 base = Read32(h + 24);
  UInt64 size = Read64(h + 28);
  MIRAY_CHECK(base >= sizeof(h) && base <= _phySize && size <= _phySize - base)
  MIRAY_CHECK(Read64(h + 76) == 0 && Read64(h + 84) == 0)
  if (size == 0 && Read64(h + 52) == 0)
  {
    MIRAY_CHECK(Read64(h + 60) == 1 && Read64(h + 68) == 0)
    _growableMfi = true;
    size = _phySize - base;
  }
  if (!_growableMfi && Read64(h + 52) != size)
  {
    MIRAY_CHECK(Read64(h + 52) > size)
    RINOK(OpenVolumes(h, openCallback))
    size = Read64(h + 52);
  }
  else
    MIRAY_CHECK(Read64(h + 60) == 1)
  Byte m[80];
  RINOK(ReadAt(base, m, sizeof(m)))
  MIRAY_CHECK(memcmp(m, "MDSC", 4) == 0 && Read32(m + 4) == 80 && Read32(m + 24) == 1)
  const UInt64 chunk = Read64(m + 60);
  const UInt32 numChunks = Read32(m + 68);
  MIRAY_CHECK(chunk >= 512 && chunk <= kMetadataLimit && (chunk & (chunk - 1)) == 0
      && numChunks <= size / chunk)
  CByteBuffer first;
  first.Alloc((size_t)chunk);
  RINOK(ReadAt(base, first, first.Size()))
  CImageStream bootstrap;
  bootstrap.Name = "Stream0";
  UInt32 head = Read32(m + 72);
  CRecordVector<UInt32> visited;
  while (head)
  {
    MIRAY_CHECK(head >= 80 && head <= chunk - 60 && visited.Size() < 4096)
    FOR_VECTOR (i, visited)
      MIRAY_CHECK(visited[i] != head)
    visited.Add(head);
    const Byte *entry = first + head;
    if (memcmp(entry + 24, "Stream0", 7) == 0 && entry[31] == 0)
      break;
    head = Read32(entry);
  }
  MIRAY_CHECK(head != 0 && Read32(first + head + 4) == 60 && Read32(first + head + 8) == 2)
  bootstrap.Size = Read64(first + head + 16);
  MIRAY_CHECK(bootstrap.Size >= sizeof(m) && bootstrap.Size <= kMetadataLimit)
  const UInt64 directoryChunks = bootstrap.Size / chunk + (bootstrap.Size % chunk != 0);
  MIRAY_CHECK(directoryChunks <= numChunks)
  UInt64 directoryAdded = 0;
  UInt32 directoryExtra = Read32(first + head + 56);
  CByteBuffer used;
  used.Alloc((size_t)bootstrap.Size);
  memset(used, 0, used.Size());
  unsigned directoryLists = 0;
  while (directoryExtra)
  {
    MIRAY_CHECK(directoryExtra >= 80 && directoryExtra <= bootstrap.Size - 8
        && !used[directoryExtra] && directoryLists++ < kItemLimit)
    used[directoryExtra] = 1;
    Byte header[8];
    RINOK(ReadDirectoryData(bootstrap, base, chunk, directoryExtra, header, sizeof(header)))
    const UInt32 bytes = Read32(header + 4);
    MIRAY_CHECK(bytes >= 8 && bytes % 4 == 0 && bytes <= bootstrap.Size - directoryExtra)
    for (UInt32 j = 8; j < bytes && directoryAdded < directoryChunks; j += 4, directoryAdded++)
    {
      Byte word[4];
      RINOK(ReadDirectoryData(bootstrap, base, chunk, directoryExtra + j, word, sizeof(word)))
      const UInt32 index = Read32(word);
      MIRAY_CHECK(index < numChunks)
      AddChunkExtent(bootstrap, base + (UInt64)index * chunk, chunk);
    }
    directoryExtra = Read32(header);
  }
  MIRAY_CHECK(directoryAdded == directoryChunks)
  RINOK(CheckStream(bootstrap))
  CByteBuffer dir;
  dir.Alloc((size_t)bootstrap.Size);
  RINOK(ReadData(bootstrap, 0, dir, dir.Size()))
  MIRAY_CHECK(memcmp(dir, m, sizeof(m)) == 0)
  memset(used, 0, used.Size());
  UInt32 offset = Read32(m + 72);
  while (offset)
  {
    MIRAY_CHECK(offset >= 80 && offset <= dir.Size() - 60 && !used[offset] && _streams.Size() < 4096)
    used[offset] = 1;
    const Byte *p = dir + offset;
    const UInt32 kind = Read32(p + 8);
    MIRAY_CHECK(Read32(p + 4) == 60 && (kind == 0 || kind == 2))
    CImageStream &s = _streams.AddNew();
    s.Name.SetFrom((const char *)p + 24, 32);
    const int nul = s.Name.Find((char)0);
    if (nul >= 0)
      s.Name.DeleteFrom((unsigned)nul);
    s.Size = Read64(p + 16);
    if (kind == 0)
    {
      const UInt32 extra = Read32(p + 56);
      MIRAY_CHECK(extra >= 80 && extra <= dir.Size() - 8 && Read32(dir + extra) == 0
          && s.Size <= dir.Size() - extra - 8)
      UInt64 position = (UInt64)extra + 8;
      UInt64 remaining = s.Size;
      FOR_VECTOR (i, bootstrap.Extents)
      {
        const CExtent &source = bootstrap.Extents[i];
        if (position >= source.Size)
        {
          position -= source.Size;
          continue;
        }
        const UInt64 take = remaining < source.Size - position ? remaining : source.Size - position;
        CExtent e;
        e.Offset = source.Offset + position;
        e.Size = take;
        s.Extents.Add(e);
        remaining -= take;
        if (!remaining)
          break;
        position = 0;
      }
      MIRAY_CHECK(remaining == 0)
      RINOK(CheckStream(s))
      offset = Read32(p);
      continue;
    }
    const UInt64 needed = s.Size / chunk + (s.Size % chunk != 0);
    MIRAY_CHECK(needed <= numChunks && needed <= kItemLimit)
    UInt32 extra = Read32(p + 56);
    UInt64 added = 0;
    while (extra)
    {
      MIRAY_CHECK(extra >= 80 && extra <= dir.Size() - 8 && !used[extra])
      used[extra] = 1;
      const UInt32 bytes = Read32(dir + extra + 4);
      MIRAY_CHECK(bytes >= 8 && bytes % 4 == 0 && bytes <= dir.Size() - extra)
      for (UInt32 j = 8; j < bytes && added < needed; j += 4, added++)
      {
        const UInt32 c = Read32(dir + extra + j);
        MIRAY_CHECK(c < numChunks)
        AddChunkExtent(s, base + (UInt64)c * chunk, chunk);
      }
      extra = Read32(dir + extra);
    }
    MIRAY_CHECK(added == needed)
    RINOK(CheckStream(s))
    offset = Read32(p);
  }
  unsigned directoryIndex = 0;
  for (; directoryIndex < _streams.Size(); directoryIndex++)
    if (_streams[directoryIndex].Name == "Stream0")
      break;
  MIRAY_CHECK(directoryIndex < _streams.Size())
  const CImageStream &directoryStream = _streams[directoryIndex];
  MIRAY_CHECK(directoryStream.Size == bootstrap.Size)
  CByteBuffer checkedDirectory;
  checkedDirectory.Alloc((size_t)directoryStream.Size);
  RINOK(ReadData(directoryStream, 0, checkedDirectory, checkedDirectory.Size()))
  MIRAY_CHECK(memcmp(checkedDirectory, dir, dir.Size()) == 0)
  SetUi32(checkedDirectory + 76, 0);
  MIRAY_CHECK(CrcCalc(checkedDirectory, checkedDirectory.Size()) == Read32(m + 76))
  return S_OK;
}

HRESULT CHandler::OpenMaiVolumes(const Byte *header, const Byte *footer, IArchiveOpenCallback *openCallback)
{
  const UInt32 count = Read32(header + 32);
  const UInt32 rootChunk = Read32(header + 36);
  const UInt32 rootChunks = Read32(footer + 52);
  const UInt64 rootDataSize = (UInt64)rootChunks * _maiChunkSize;
  MIRAY_CHECK(count > 0 && count <= 1024 && rootChunks > 0
      && (_maiRecovered ? rootDataSize <= _phySize - 4096
          && _phySize - 4096 - rootDataSize < _maiChunkSize : rootDataSize == _phySize - 8192))
  if (count == 1)
  {
    MIRAY_CHECK(rootChunk == 0)
    return S_OK;
  }
  MIRAY_CHECK(openCallback && _maiMaxChunks != (UInt32)-1)
  Z7_DECL_CMyComPtr_QI_FROM(IArchiveOpenVolumeCallback, callback, openCallback)
  MIRAY_CHECK(callback)
  NCOM::CPropVariant prop;
  RINOK(callback->GetProperty(kpidName, &prop))
  MIRAY_CHECK(prop.vt == VT_BSTR)
  const UString name = _sourceName.IsEmpty() ? UString(prop.bstrVal) : _sourceName;
  UString lower(name);
  lower.MakeLower_Ascii();
  const bool snapshot = memcmp(header, "XSAM", 4) == 0;
  MIRAY_CHECK(name.Len() > (snapshot ? 5u : 4u) && (snapshot ? StringsAreEqual_Ascii(lower.RightPtr(5), ".mais")
      : StringsAreEqual_Ascii(lower.RightPtr(4), ".mai") || StringsAreEqual_Ascii(lower.RightPtr(4), ".mfd")))
  UString stem = name.Left(name.Len() - (snapshot ? 5 : 4));
  if (snapshot)
  {
    const int dot = stem.ReverseFind_Dot();
    MIRAY_CHECK(dot > 0 && stem.Len() - (unsigned)dot <= 7)
    UInt32 ordinal = 0;
    for (unsigned j = (unsigned)dot + 1; j < stem.Len(); j++)
    {
      MIRAY_CHECK(stem[j] >= L'0' && stem[j] <= L'9')
      ordinal = ordinal * 10 + (unsigned)(stem[j] - L'0');
    }
    MIRAY_CHECK(ordinal == count)
    stem.DeleteFrom((unsigned)dot);
  }
  CMyComPtr<IInStream> root = Stream;
  CMyComPtr2<IInStream, CMultiStream> combined;
  combined.Create_if_Empty();
  AddVolumeRecord(combined.ClsPtr(), header);
  UInt64 chunks = 0;
  unsigned width = 0;
  for (UInt32 index = 1; index < count; index++)
  {
    CMyComPtr<IInStream> input;
    wchar_t digits[16];
    ConvertUInt32ToString(index, digits);
    const unsigned numDigits = (unsigned)wcslen(digits);
    const unsigned widths[] = { 3, 1, 2, 4, 5, 6 };
    for (unsigned attempt = 0; attempt < Z7_ARRAY_SIZE(widths); attempt++)
    {
      const unsigned candidate = width ? width : widths[attempt];
      UString next = stem;
      next += L'.';
      for (unsigned j = numDigits; j < candidate; j++)
        next += L'0';
      next += digits;
      next += L".mais";
      const HRESULT result = callback->GetStream(next, &input);
      if (result == S_OK && input)
      {
        width = candidate;
        break;
      }
      input.Release();
      if (width)
        break;
    }
    MIRAY_CHECK(input)
    UInt64 physical;
    RINOK(InStream_GetSize_SeekToEnd(input, physical))
    MIRAY_CHECK(physical >= 8192)
    Byte h[4096], f[4096];
    RINOK(InStream_SeekSet(input, 0))
    RINOK(ReadStream_FALSE(input, h, sizeof(h)))
    RINOK(InStream_SeekSet(input, physical - sizeof(f)))
    RINOK(ReadStream_FALSE(input, f, sizeof(f)))
    CByteBuffer record;
    record.CopyFrom(h, sizeof(h));
    MIRAY_CHECK(CheckMaiRecordCrc(record) && memcmp(h, "XSAM", 4) == 0
        && Read32(h + 12) <= 1
        && memcmp(h + 16, header + 16, 16) == 0
        && Read32(h + 32) == index && Read32(h + 36) == chunks
        && memcmp(h + 40, header + 40, 16) == 0)
    record.CopyFrom(f, sizeof(f));
    MIRAY_CHECK(CheckMaiRecordCrc(record) && memcmp(f, "NSAM", 4) == 0
        && memcmp(f + 12, h + 12, 40) == 0 && Read32(f + 76) == 0)
    const UInt32 length = Read32(f + 52);
    MIRAY_CHECK(length > 0
        && (UInt64)length * _maiChunkSize == physical - 8192
        && chunks <= rootChunk && length <= rootChunk - chunks
        && physical <= ((UInt64)1 << 60) - _totalPhysicalSize)
    const UInt64 descriptorPos = Read64(f + 56), descriptorSize = Read64(f + 64);
    MIRAY_CHECK(descriptorPos >= 4096 && descriptorPos <= physical - 4096
        && descriptorSize >= 44 && descriptorSize <= kMetadataLimit
        && descriptorSize <= physical - 4096 - descriptorPos)
    record.Alloc((size_t)descriptorSize);
    RINOK(InStream_SeekSet(input, descriptorPos))
    RINOK(ReadStream_FALSE(input, record, record.Size()))
    MIRAY_CHECK(memcmp(record, "DSAM", 4) == 0 && Read32(record + 4) == descriptorSize
        && CheckZeroCrc(record))
    RINOK(AddVolumeRange(combined.ClsPtr(), input, 4096, physical - 8192))
    CExtent volume;
    volume.Offset = chunks;
    volume.Size = length;
    _maiVolumes.Add(volume);
    CByteBuffer &physicalRecords = _maiVolumeRecords.AddNew();
    physicalRecords.Alloc(8192);
    memcpy(physicalRecords, h, sizeof(h));
    memcpy(physicalRecords + 4096, f, sizeof(f));
    chunks += length;
    _totalPhysicalSize += physical;
  }
  MIRAY_CHECK(chunks == rootChunk)
  RINOK(AddVolumeRange(combined.ClsPtr(), root, 4096, rootDataSize))
  AddVolumeRecord(combined.ClsPtr(), footer);
  RINOK(combined->Init())
  Stream = combined;
  _phySize = 8192 + (chunks + rootChunks) * _maiChunkSize;
  _numVolumes = count;
  return S_OK;
}

HRESULT CHandler::FindMaiRecovery(const Byte *header, UInt64 &position, UInt64 &size)
{
  const UInt32 interval = Read32(header + 56);
  MIRAY_CHECK(interval && Read32(header + 64) == 0)
  const UInt64 chunks = (_phySize - 4096) / _maiChunkSize;
  UInt64 candidate = chunks / interval * interval;
  for (unsigned attempt = 0; candidate && attempt < 4096; attempt++, candidate -= interval)
  {
    const UInt64 offset = 4096 + candidate * _maiChunkSize;
    if (_phySize - offset < 44)
      continue;
    Byte record[44];
    RINOK(ReadAt(offset, record, sizeof(record)))
    const UInt32 length = Read32(record + 4);
    if (memcmp(record, "DSAM", 4) != 0 || length < 44 || length > kMetadataLimit
        || length > _phySize - offset
        || (UInt64)Read32(record + 12) + Read32(record + 32) > chunks - candidate)
      continue;
    CByteBuffer descriptor;
    descriptor.Alloc(length);
    RINOK(ReadAt(offset, descriptor, length))
    if (CheckZeroCrc(descriptor))
    {
      position = offset;
      size = length;
      return S_OK;
    }
  }
  return S_FALSE;
}

HRESULT CHandler::OpenMai(IArchiveOpenCallback *openCallback)
{
  CByteBuffer h, f;
  h.Alloc(4096);
  f.Alloc(4096);
  RINOK(ReadAt(0, h, h.Size()))
  const bool snapshot = memcmp(h, "XSAM", 4) == 0;
  MIRAY_CHECK(Read32(h + 12) <= 1 && CheckMaiRecordCrc(h))
  const UInt32 chunk = Read32(h + 44);
  _maiChunkSize = chunk;
  _maiMaxChunks = Read32(h + 40);
  MIRAY_CHECK(chunk >= 512 && chunk <= kMetadataLimit && (chunk & (chunk - 1)) == 0
      && Read32(h + 48) == 4096 && Read32(h + 52) == 4096 && _phySize >= 8192)
  RINOK(ReadAt(_phySize - 4096, f, f.Size()))
  UInt64 descriptorPos = 0, descriptorSize = 0;
  if (memcmp(f, snapshot ? "NSAM" : "FSAM", 4) == 0 && memcmp(f + 12, h + 12, 40) == 0
      && Read32(f + 76) == 0 && CheckMaiRecordCrc(f))
  {
    MIRAY_CHECK(Read64(f + 56) >= 4096 && Read64(f + 56) <= _phySize - 4096
        && Read64(f + 64) <= _phySize - 4096 - Read64(f + 56))
    RINOK(OpenMaiVolumes(h, f, openCallback))
    descriptorPos = Read64(f + 56) + (UInt64)Read32(h + 36) * chunk;
    descriptorSize = Read64(f + 64);
  }
  else
  {
    RINOK(FindMaiRecovery(h, descriptorPos, descriptorSize))
    _maiRecovered = true;
    const UInt64 rootChunks = (_phySize - 4096) / chunk;
    MIRAY_CHECK(rootChunks <= (UInt32)-1)
    memset(f, 0, f.Size());
    SetUi32(f + 52, (UInt32)rootChunks);
    RINOK(OpenMaiVolumes(h, f, openCallback))
    descriptorPos += (UInt64)Read32(h + 36) * chunk;
  }
  const UInt64 dataEnd = _maiRecovered && _numVolumes == 1
      ? 4096 + (_phySize - 4096) / chunk * chunk : _phySize - 4096;
  MIRAY_CHECK(descriptorSize >= 44 && descriptorSize <= kMetadataLimit
      && descriptorPos >= 4096 && descriptorPos <= dataEnd
      && descriptorSize <= dataEnd - descriptorPos)
  CByteBuffer d;
  d.Alloc((size_t)descriptorSize);
  RINOK(ReadAt(descriptorPos, d, d.Size()))
  MIRAY_CHECK(memcmp(d, "DSAM", 4) == 0 && Read32(d + 4) == descriptorSize
      && (UInt64)Read32(d + 12) + Read32(d + 32)
          <= (dataEnd - descriptorPos) / chunk && CheckZeroCrc(d))
  const UInt32 table = Read32(d + 16), tableSize = Read32(d + 20);
  MIRAY_CHECK(table >= 44 && table <= descriptorSize && tableSize >= 4
      && tableSize <= descriptorSize - table)
  const UInt32 volumeTable = Read32(d + 24), volumeTableSize = Read32(d + 28);
  if (_numVolumes > 1)
  {
    MIRAY_CHECK(volumeTable >= 44 && volumeTable <= descriptorSize
        && volumeTableSize <= descriptorSize - volumeTable
        && volumeTableSize == 4 + (_numVolumes - 1) * 16
        && Read32(d + volumeTable) == _maiVolumes.Size())
    FOR_VECTOR (i, _maiVolumes)
    {
      const Byte *entry = d + volumeTable + 4 + i * 16;
      MIRAY_CHECK(Read32(entry) == _maiVolumes[i].Offset
          && Read32(entry + 4) == _maiVolumes[i].Size)
      RINOK(ReadMaiChecksums(d, Read32(entry + 8), Read32(entry + 12), i, true))
    }
  }
  else
    MIRAY_CHECK(volumeTable == 0 && volumeTableSize == 0)
  const UInt32 count = Read32(d + table);
  MIRAY_CHECK(count > 0 && count <= 4096 && (UInt64)count * 72 + 4 == tableSize)
  for (UInt32 i = 0; i < count; i++)
  {
    const Byte *p = d + table + 4 + i * 72;
    CImageStream &s = _streams.AddNew();
    s.Name.SetFrom((const char *)p, 32);
    const int nul = s.Name.Find((char)0);
    if (nul >= 0)
      s.Name.DeleteFrom((unsigned)nul);
    s.Size = Read64(p + 40);
    const UInt32 inlinePos = Read32(p + 48), inlineSize = Read32(p + 52);
    const UInt32 runs = Read32(p + 56), runsSize = Read32(p + 60);
    MIRAY_CHECK(runsSize % 8 == 0 && runs <= descriptorSize && runsSize <= descriptorSize - runs)
    UInt64 externalSize = 0;
    if (runsSize)
    {
      for (UInt32 j = 0; j < runsSize; j += 8)
      {
        CExtent e;
        e.Offset = 4096 + (UInt64)Read32(d + runs + j) * chunk;
        e.Size = (UInt64)Read32(d + runs + j + 4) * chunk;
        const UInt64 allocatedEnd = descriptorPos + (descriptorSize + chunk - 1) / chunk * chunk;
        MIRAY_CHECK(e.Offset <= dataEnd && e.Size <= dataEnd - e.Offset
            && ((e.Offset <= descriptorPos && e.Size <= descriptorPos - e.Offset)
                || (_maiRecovered && e.Offset >= allocatedEnd)))
        MIRAY_CHECK(externalSize <= (UInt64)-1 - e.Size)
        externalSize += e.Size;
        s.Extents.Add(e);
      }
    }
    if (inlineSize)
    {
      MIRAY_CHECK(inlinePos <= descriptorSize && inlineSize <= descriptorSize - inlinePos
          && (externalSize >= s.Size || inlineSize == s.Size - externalSize)
          && (!runsSize || Read32(p + 32) == 3))
      CExtent e;
      e.Offset = descriptorPos + inlinePos;
      e.Size = inlineSize;
      if (externalSize < s.Size)
        s.Extents.Add(e);
    }
    RINOK(CheckStream(s))
    RINOK(ReadMaiChecksums(d, Read32(p + 64), Read32(p + 68), i))
  }
  if (snapshot)
    _maiRecovered = true;
  return S_OK;
}

HRESULT CHandler::ReadMaiChecksums(const CByteBuffer &descriptor, UInt32 offset, UInt32 size,
    unsigned streamIndex, bool physical)
{
  if (!size)
  {
    MIRAY_CHECK(offset == 0)
    return S_OK;
  }
  MIRAY_CHECK(offset >= 44 && offset <= descriptor.Size() && size <= descriptor.Size() - offset)
  const Byte *p = descriptor + offset;
  size_t position = 0;
  unsigned seen = 0;
  while (size - position >= 4)
  {
    const unsigned length = Read16(p + position), type = Read16(p + position + 2);
    position += 4;
    if (!length && !type)
    {
      for (; position < size; position++)
        MIRAY_CHECK(p[position] == 0)
      return S_OK;
    }
    const unsigned method = type == 2 ? 0 : type == 3 ? 1 : type == 4 ? 2 : type == 6 ? 3 : 4;
    MIRAY_CHECK(method < Z7_ARRAY_SIZE(kDigestSizes) && length == kDigestSizes[method]
        && length <= size - position && !(seen & (1 << method)))
    seen |= 1 << method;
    CImageChecksum item;
    item.StreamIndex = streamIndex;
    item.Method = method;
    item.Physical = physical;
    memset(item.Digest, 0, sizeof(item.Digest));
    memcpy(item.Digest, p + position, length);
    _maiChecksums.Add(item);
    position += length;
  }
  return S_FALSE;
}

HRESULT CHandler::VerifyMaiChecksums()
{
  if (_maiChecksums.IsEmpty())
    return S_OK;
  static const CMethodId methods[] = { 0x208, 0x201, 0xA, 0x231 };
  CByteBuffer buffer;
  buffer.Alloc(1 << 20);
  for (unsigned unit = 0; unit < _streams.Size() + _maiVolumes.Size(); unit++)
  {
    const bool physical = unit >= _streams.Size();
    const unsigned streamIndex = physical ? unit - _streams.Size() : unit;
    CMyComPtr<IHasher> hashers[4];
    bool needed = false;
    FOR_VECTOR (i, _maiChecksums)
      if (_maiChecksums[i].Physical == physical && _maiChecksums[i].StreamIndex == streamIndex)
      {
        const unsigned method = _maiChecksums[i].Method;
        AString name;
        RINOK(CreateHasher(
          #ifdef Z7_EXTERNAL_CODECS
          NULL,
          #endif
          methods[method], name, hashers[method]))
        MIRAY_CHECK(hashers[method])
        hashers[method]->Init();
        if (physical)
          hashers[method]->Update(_maiVolumeRecords[streamIndex], 4096);
        needed = true;
      }
    if (!needed)
      continue;
    const UInt64 size = physical ? _maiVolumes[streamIndex].Size * _maiChunkSize : _streams[streamIndex].Size;
    for (UInt64 offset = 0; offset < size;)
    {
      const UInt32 take = size - offset < buffer.Size() ? (UInt32)(size - offset) : (UInt32)buffer.Size();
      if (physical)
        RINOK(ReadAt(4096 + _maiVolumes[streamIndex].Offset * _maiChunkSize + offset, buffer, take))
      else
        RINOK(ReadData(_streams[streamIndex], offset, buffer, take))
      for (unsigned method = 0; method < Z7_ARRAY_SIZE(hashers); method++)
        if (hashers[method])
          hashers[method]->Update(buffer, take);
      offset += take;
    }
    FOR_VECTOR (i, _maiChecksums)
      if (_maiChecksums[i].Physical == physical && _maiChecksums[i].StreamIndex == streamIndex)
      {
        Byte digest[32];
        const unsigned method = _maiChecksums[i].Method;
        if (physical)
          hashers[method]->Update(_maiVolumeRecords[streamIndex] + 4096, 4096);
        hashers[method]->Final(digest);
        MIRAY_CHECK(memcmp(digest, _maiChecksums[i].Digest, kDigestSizes[method]) == 0)
      }
  }
  return S_OK;
}

HRESULT CHandler::ReadMetadata()
{
  unsigned index = 0;
  for (; index < _streams.Size(); index++)
    if (_streams[index].Name == "mfic.img")
      break;
  if (index == _streams.Size())
  {
    for (index = 0; index < _streams.Size(); index++)
      if (_streams[index].Name == "meta.ovl")
        break;
    _overlay = index < _streams.Size();
  }
  MIRAY_CHECK(index < _streams.Size() && (!_growableMfi || _overlay))
  const CImageStream &s = _streams[index];
  MIRAY_CHECK(s.Size >= 8 && s.Size <= kMetadataLimit)
  CByteBuffer data;
  data.Alloc((size_t)s.Size);
  RINOK(ReadData(s, 0, data, data.Size()))
  _version = Read32(data + 4);
  const bool legacy = memcmp(data, "IMGC", 4) == 0 && _version == 1;
  MIRAY_CHECK(legacy || (memcmp(data, "MFIC", 4) == 0
      && _version >= 2 && _version <= 4 && s.Size >= 12))
  UInt64 sectors = 0;
  UInt64 imageType = 0, splitSize = (UInt64)(Int64)-1;
  UInt32 splitMode = (UInt32)-1;
  bool hasSectors = false, hasImageType = false;
  CRecordVector<UInt32> globalSeen, partSeen;
  CRecordVector<CExtent> missingRanges;
  Sha256_Init(&_keyPrefixHash);
  size_t pos = legacy ? 8 : 12;
  UInt32 textEncoding = 0;
  unsigned properties = 0;
  bool inPart = false;
  while (pos < data.Size())
  {
    MIRAY_CHECK(data.Size() - pos >= 8 && properties++ < 4096)
    const UInt32 rawTag = Read32(data + pos);
    const UInt32 key = rawTag & 0x7fffffff;
    const UInt32 size = Read32(data + pos + 4);
    pos += 8;
    MIRAY_CHECK(size <= data.Size() - pos)
    const Byte *p = data + pos;
    const bool regionExtra = key == 0x2000 && inPart;
    const bool regionKey = (key >= 0x1000 && key < 0x2000) || (inPart && key >= 0x1000);
    const bool knownKey = regionKey ? (key == 0x2000 || (key >= 0x1000 && key <= 0x100e && key != 0x1005))
        : key == 0x2000 || (key <= 33 && key != 3);
    MIRAY_CHECK(!(rawTag & 0x80000000) || knownKey)
    if (key == 0x2000 && size)
    {
      MIRAY_CHECK(size >= 4)
      const UInt32 count = Read32(p);
      MIRAY_CHECK(count > 0 && count <= 4096)
      UInt32 offset = 4;
      for (UInt32 i = 0; i < count; i++)
      {
        MIRAY_CHECK(size - offset >= 8)
        const UInt32 length = Read32(p + offset + 4);
        MIRAY_CHECK(length <= size - offset - 8)
        offset += 8 + length;
      }
      MIRAY_CHECK(offset == size)
    }
    if (key == 5)
    {
      MIRAY_CHECK(size == 0 && !inPart && _parts.Size() < 4096)
      _parts.AddNew();
      partSeen.Clear();
      inPart = true;
    }
    else
    {
      const bool isPart = regionKey;
      MIRAY_CHECK(!isPart || (inPart && !_parts.IsEmpty()))
      CRecordVector<UInt32> &seen = isPart ? partSeen : globalSeen;
      if (knownKey && key != 0x100e && (isPart || key != 7))
      {
        FOR_VECTOR (i, seen)
          MIRAY_CHECK(seen[i] != key)
        seen.Add(key);
      }
      if (isPart)
      {
        HashKeyData(&_keyPrefixHash, data + pos - 8, (size_t)size + 8);
        CPart &part = _parts.Back();
        if (regionExtra)
        {
          MIRAY_CHECK(size >= 4)
          UInt32 offset = 4;
          for (UInt32 i = 0; i < Read32(p); i++)
          {
            const UInt32 length = Read32(p + offset + 4);
            if (memcmp(p + offset, "ELST", 4) == 0)
            {
              MIRAY_CHECK(part.Errors.IsEmpty()
                  && ReadAreaList(p + offset + 8, length, part.Errors))
            }
            offset += 8 + length;
          }
        }
        else if (key == 0x1000)
        {
          MIRAY_CHECK(size > 0 && size <= (_legacyDirectory ? 4095 : 32))
          MIRAY_CHECK(ReadText(p, size, textEncoding, part.Name))
        }
        else if (key == 0x100c)
        {
          MIRAY_CHECK(size == LZMA_PROPS_SIZE)
          memcpy(part.LzmaProps, p, LZMA_PROPS_SIZE);
          part.HasLzmaProps = true;
        }
        else if (key == 0x100d)
        {
          MIRAY_CHECK(size < 4096)
          MIRAY_CHECK(ReadText(p, size, textEncoding, part.MaskName))
        }
        else if (key == 0x100e)
        {
          MIRAY_CHECK(size >= 4)
          const UInt32 method = Read32(p);
          MIRAY_CHECK(method > 0 && method < Z7_ARRAY_SIZE(kRegionDigestSizes)
              && size == 4 + kRegionDigestSizes[method])
          FOR_VECTOR (i, part.Checksums)
            MIRAY_CHECK(part.Checksums[i].Method != method)
          CRegionChecksum &checksum = part.Checksums.AddNew_NoConstruct();
          checksum.Method = method;
          memset(checksum.Digest, 0, sizeof(checksum.Digest));
          memcpy(checksum.Digest, p + 4, size - 4);
        }
        else if (key == 0x1009)
        {
          MIRAY_CHECK(size == 0)
          part.Incomplete = true;
        }
        else if (key == 0x1006)
        {
          MIRAY_CHECK(size == 0)
          part.Uninitialized = true;
        }
        else if (key == 0x1008)
        {
          MIRAY_CHECK(size == 0)
          inPart = false;
        }
        else if (key == 0x1001 || key == 0x1002 || key == 0x1003 || key == 0x1004
            || key == 0x1007 || key == 0x100a || key == 0x100b)
        {
          MIRAY_CHECK(size >= 1 && size <= ((key == 0x1007 || key == 0x100b) ? 4 : 8))
          UInt64 value = ReadNumber(p, size);
          // Short start addresses retain the high bytes of the all-ones default.
          if (key == 0x1001 && size < 8)
            value |= (UInt64)-1 << (size * 8);
          switch (key)
          {
            case 0x1001: part.Base = value; break;
            case 0x1002: part.StoredBytes = value; part.HasStoredBytes = true; break;
            case 0x1003: part.Stored = value; break;
            case 0x1004: part.Last = value; part.HasLast = true; break;
            case 0x1007: MIRAY_CHECK(value <= 13) part.Kind = (UInt32)value; break;
            case 0x100a: part.Sectors = value; break;
            case 0x100b: MIRAY_CHECK(value <= 3) part.Method = (UInt32)value; break;
          }
        }
      }
      else if (key == 13 || key == 14)
      {
        MIRAY_CHECK(size == 16)
        CByteBuffer &dest = key == 13 ? _imageId : _baseId;
        dest.CopyFrom(p, size);
      }
      else if (key == 26)
      {
        MIRAY_CHECK(size > 0 && size <= 4096)
        for (UInt32 i = 0; i < size; i++)
          MIRAY_CHECK(p[i] != 0)
        AString encoded;
        encoded.SetFrom((const char *)p, size);
        UString path;
        if (textEncoding)
        {
          MIRAY_CHECK(ConvertUTF8ToUnicode(encoded, path))
        }
        else
          for (UInt32 i = 0; i < size; i++)
            path += (wchar_t)(UInt16)(Int16)(signed char)p[i];
        unsigned start = 0;
        for (unsigned i = 0; i < path.Len(); i++)
          if (path[i] == L'/' || path[i] == L'\\')
            start = i + 1;
        _parentName = path;
        _parentName.DeleteFrontal(start);
        MIRAY_CHECK(!_parentName.IsEmpty() && _parentName != L"." && _parentName != L".."
            && _parentName.Find(L':') < 0)
      }
      else if (key == 7)
      {
        MIRAY_CHECK(size >= 1 && size <= 4)
        UInt32 encoding = 0;
        for (UInt32 i = 0; i < size; i++)
          encoding |= (UInt32)p[i] << (i * 8);
        MIRAY_CHECK(encoding <= 1)
        textEncoding = encoding;
      }
      else if (key == 8 || key == 9 || key == 0x2000)
      {
        MIRAY_CHECK(key == 0x2000 || size == 0 || size == SHA256_DIGEST_SIZE)
        CByteBuffer &dest = key == 8 ? _verifier : key == 9 ? _salt : _keyStore;
        dest.CopyFrom(p, size);
        if (key == 0x2000 && size)
        {
          UInt32 offset = 4;
          for (UInt32 i = 0; i < Read32(p); i++)
          {
            const UInt32 length = Read32(p + offset + 4);
            if (memcmp(p + offset, "KSTO", 4) == 0)
              _hasKeyStore = true;
            if (memcmp(p + offset, "MLST", 4) == 0 || memcmp(p + offset, "ELST", 4) == 0
                || memcmp(p + offset, "SLST", 4) == 0)
            {
              MIRAY_CHECK(ReadAreaList(p + offset + 8, length, missingRanges, false))
            }
            offset += 8 + length;
          }
        }
      }
      else if (key == 6 || key == 10 || key == 11 || key == 12 || key == 15 || key == 17 || key == 27)
      {
        MIRAY_CHECK(size >= 1 && size <= (key == 10 || key == 11 || key == 27 ? 4 : 8))
        MIRAY_CHECK((key != 6 && key != 15 && key != 17) || size == 8)
        const UInt64 value = ReadNumber(p, size);
        if (key == 6)
        {
          MIRAY_CHECK(value >= 512 && value <= kBlockLimit && (value & (value - 1)) == 0)
          _sectorSize = (UInt32)value;
        }
        else if (key == 10)
          _passwordType = (UInt32)value;
        else if (key == 11)
        {
          MIRAY_CHECK(value <= 2)
          _encryption = (UInt32)value;
        }
        else if (key == 12)
        {
          sectors = value;
          hasSectors = true;
        }
        else if (key == 15)
          splitSize = value;
        else if (key == 27)
          splitMode = (UInt32)value;
        else
        {
          imageType = value;
          hasImageType = true;
        }
      }
    }
    pos += size;
  }
  _protected = _verifier.Size() != 0 || _salt.Size() != 0;
  MIRAY_CHECK(!_protected || (_verifier.Size() == SHA256_DIGEST_SIZE && _salt.Size() == SHA256_DIGEST_SIZE))
  MIRAY_CHECK(!_protected || (_passwordType >= 1 && _passwordType <= 3))
  // Absent global geometry is bounded by the declared region ends.
  if (!hasSectors)
    FOR_VECTOR (i, _parts)
    {
      const CPart &part = _parts[i];
      const UInt64 limit = ((UInt64)1 << 60) / _sectorSize;
      MIRAY_CHECK(part.Base <= limit && part.Sectors <= limit - part.Base)
      if (sectors < part.Base + part.Sectors)
        sectors = part.Base + part.Sectors;
    }
  const UInt64 fullType = _isMai ? 24 : 8;
  if (!hasImageType)
  {
    MIRAY_CHECK(!_parts.IsEmpty())
    const UInt32 kind = _parts[0].Kind;
    if (_parts.Size() == 1 && (kind == 4 || kind == 5))
    {
      imageType = kind == 4 ? (_isMai ? 26 : 10) : (_isMai ? 28 : 20);
    }
    else
    {
      FOR_VECTOR (i, _parts)
        MIRAY_CHECK(kind == 8 ? _parts[i].Kind == 8
            : _parts[i].Kind >= 1 && _parts[i].Kind <= 3)
      imageType = kind == 8 ? 14 : fullType + 1;
    }
  }
  MIRAY_CHECK(!inPart && !_parts.IsEmpty() && sectors > 0 && sectors <= ((UInt64)1 << 60) / _sectorSize)
  MergeExtents(missingRanges);
  FOR_VECTOR (i, missingRanges)
  {
    const CExtent &range = missingRanges[i];
    MIRAY_CHECK(range.Offset <= sectors && range.Size <= sectors - range.Offset)
    CExtent missing;
    missing.Offset = range.Offset * _sectorSize;
    missing.Size = range.Size * _sectorSize;
    _unavailable.Add(missing);
  }
  _size = sectors * _sectorSize;
  if (_overlay)
  {
    MIRAY_CHECK(!_isMai && (imageType == 15 || imageType == 21) && _numVolumes == 1
        && splitSize == 0 && _parts.Size() == 1 && _encryption == 0)
    CPart &part = _parts[0];
    MIRAY_CHECK((part.Kind == 9 || (_legacyDirectory && part.Kind == 7))
        && part.Base == (UInt64)-1 && part.Stored == 0
        && part.Sectors == sectors && part.Method == 0 && (part.Kind == 7 || part.Name == "_overlay")
        && part.Errors.IsEmpty() && part.Checksums.IsEmpty() && (!part.HasLast || part.Last == 0)
        && (!part.HasStoredBytes || part.StoredBytes == 0))
    _splitSize = 0;
    return S_OK;
  }
  _dependent = imageType == 14;
  MIRAY_CHECK(imageType >= 1 && imageType <= 28 && imageType != 15)
  const bool rawMethod = imageType == 4 || imageType == 5 || imageType == 10 || imageType == 11;
  const bool bitImage = rawMethod || imageType == 20 || imageType == 26 || imageType == 28;
  if (_numVolumes == 1 && _splitSize == (UInt64)-1 && splitMode <= 1
      && (!_isMai || _maiMaxChunks == (UInt32)-1))
  {
    _splitSize = 0;
  }
  else if (splitSize == 0 && (_dependent || (_numVolumes == 1
      && _splitSize == (UInt64)-1 && (!_isMai || _maiMaxChunks == (UInt32)-1))))
  {
    if (_numVolumes == 1)
      _splitSize = 0;
  }
  else if (_isMai && _maiMaxChunks != (UInt32)-1)
  {
    MIRAY_CHECK(splitSize >= 8192 && splitSize != (UInt64)(Int64)-1
        && (splitSize - 8192) / _maiChunkSize == _maiMaxChunks)
    _splitSize = splitSize;
  }
  else
    MIRAY_CHECK(splitSize == _splitSize
        || (!_isMai && _numVolumes > 1 && splitSize == (UInt64)-1))
  _smart = imageType == 3 || imageType == 7 || imageType == 9 || imageType == 13
      || imageType == 21 || imageType == 25;
  _regionGaps = !bitImage;
  UInt64 next = 0;
  unsigned missingIndex = 0;
  FOR_VECTOR (i, _parts)
  {
    CPart &part = _parts[i];
    MIRAY_CHECK(part.Kind != 4 || part.Method == 0)
    MIRAY_CHECK(part.Base >= next && (_regionGaps || part.Base == next)
        && part.Sectors > 0 && part.Stored <= part.Sectors
        && part.Base <= sectors && part.Sectors <= sectors - part.Base
        && (_dependent ? part.Kind == 8 : (part.Kind >= 1 && part.Kind <= 6)
            || part.Kind == 10 || part.IsMapped()))
    MIRAY_CHECK(!part.IsMapped() || (!_isMai && part.Method == 0
        && !part.Incomplete && !part.Uninitialized))
    for (part.StreamIndex = 0; part.StreamIndex < _streams.Size(); part.StreamIndex++)
      if (_streams[part.StreamIndex].Name == part.Name)
        break;
    MIRAY_CHECK(part.StreamIndex < _streams.Size())
    const UInt64 streamSize = _streams[part.StreamIndex].Size;
    part.Progress = _maiRecovered && part.Uninitialized && !part.Stored
        && (!part.HasStoredBytes || !part.StoredBytes) && (!part.HasLast || !part.Last)
        && (part.Kind <= 3 || part.Kind == 5 || part.Kind == 6 || part.Kind == 10);
    if (part.Progress)
      part.Incomplete = true;
    if (part.Kind == 4 && part.Uninitialized)
    {
      MIRAY_CHECK(part.HasStoredBytes && part.StoredBytes == 0 && part.Stored == part.Sectors
          && (!part.HasLast || part.Last == part.Sectors - 1)
          && streamSize % _sectorSize == 0 && streamSize / _sectorSize <= part.Sectors)
      part.Stored = streamSize / _sectorSize;
      if (part.Stored < part.Sectors)
      {
        MIRAY_CHECK(part.Errors.Size() < kItemLimit)
        CExtent missing;
        missing.Offset = part.Stored;
        missing.Size = part.Sectors - part.Stored;
        part.Errors.Add(missing);
      }
    }
    MIRAY_CHECK(!part.HasStoredBytes || part.StoredBytes == streamSize
        || (part.IsMapped() && part.StoredBytes == 0)
        || (part.Progress && part.StoredBytes == 0)
        || (part.Kind == 4 && part.Uninitialized && part.StoredBytes == 0))
    if (part.Incomplete && !part.Progress && part.Kind != 4
        && ((bitImage && part.Kind == 5)
            || (!bitImage && !_dependent && part.Kind >= 1 && part.Kind <= 3)))
    {
      MIRAY_CHECK(part.HasLast && (part.Stored ? part.Last < part.Sectors
          : part.Last == 0 || part.Last == (UInt64)-1))
      const UInt64 end = part.Stored ? part.Last + 1 : 0;
      MIRAY_CHECK(part.Stored <= end && (part.Errors.IsEmpty()
          || part.Errors.Back().Offset + part.Errors.Back().Size <= end))
      if (end < part.Sectors)
      {
        MIRAY_CHECK(part.Errors.Size() < kItemLimit)
        CExtent missing;
        missing.Offset = end;
        missing.Size = part.Sectors - end;
        part.Errors.Add(missing);
      }
    }
    FOR_VECTOR (j, part.Errors)
    {
      const CExtent &error = part.Errors[j];
      MIRAY_CHECK(error.Offset <= part.Sectors && error.Size <= part.Sectors - error.Offset
          && _unavailable.Size() < kItemLimit)
      CExtent range;
      range.Offset = (part.Base + error.Offset) * _sectorSize;
      range.Size = error.Size * _sectorSize;
      _unavailable.Add(range);
    }
    while (missingIndex < missingRanges.Size()
        && missingRanges[missingIndex].Offset + missingRanges[missingIndex].Size <= part.Base)
      missingIndex++;
    for (unsigned j = missingIndex; j < missingRanges.Size()
        && missingRanges[j].Offset < part.Base + part.Sectors; j++)
    {
      const CExtent &range = missingRanges[j];
      const UInt64 start = range.Offset > part.Base ? range.Offset : part.Base;
      const UInt64 stop = range.Offset + range.Size < part.Base + part.Sectors
          ? range.Offset + range.Size : part.Base + part.Sectors;
      MIRAY_CHECK(part.Errors.Size() < kItemLimit)
      CExtent missing;
      missing.Offset = start - part.Base;
      missing.Size = stop - start;
      part.Errors.Add(missing);
    }
    MergeExtents(part.Errors);
    UInt64 errorSectors = 0;
    FOR_VECTOR (j, part.Errors)
    {
      const CExtent &error = part.Errors[j];
      MIRAY_CHECK(error.Offset <= part.Sectors && error.Size <= part.Sectors - error.Offset)
      errorSectors += error.Size;
    }
    MIRAY_CHECK((_smart || _dependent || part.IsMapped() || part.Progress || part.Stored + errorSectors >= part.Sectors)
        && (part.Kind != 4 || part.Uninitialized || part.Stored == part.Sectors))
    if (part.Method == 3)
      MIRAY_CHECK(part.HasLzmaProps && part.LzmaProps[0] < 225
          && Read32(part.LzmaProps + 1) >= 4096 && Read32(part.LzmaProps + 1) <= kBlockLimit)
    next = part.Base + part.Sectors;
    if (i == 0)
      _method = part.Method;
    else if (_method != part.Method)
      _method = 4;
  }
  MIRAY_CHECK(_regionGaps || next == sectors)
  FOR_VECTOR (i, _parts)
    if (_parts[i].IsMapped())
      _regionGaps = true;
  MergeExtents(_unavailable);
  return S_OK;
}

HRESULT CHandler::OpenBase(IArchiveOpenCallback *openCallback)
{
  if (!_dependent && !_overlay)
    return S_OK;
  MIRAY_CHECK(_depth < 15 && _imageId.Size() == 16 && _baseId.Size() == 16
      && memcmp(_imageId, _baseId, 16) != 0 && openCallback)
  Z7_DECL_CMyComPtr_QI_FROM(IArchiveOpenVolumeCallback, callback, openCallback)
  MIRAY_CHECK(callback)
  UStringVector candidates;
  if (!_parentName.IsEmpty())
    candidates.Add(_parentName);
  else
  {
    MIRAY_CHECK(_overlay)
    if (_legacyDirectory)
    {
      UString prefix;
      for (unsigned i = 0; i < _sourceName.Len(); i++)
        if (_sourceName[i] == L'/' || _sourceName[i] == L'\\')
          prefix = _sourceName.Left(i + 1);
      candidates.Add(prefix + L"mfic.img");
    }
    else
    {
      NCOM::CPropVariant prop;
      RINOK(callback->GetProperty(kpidName, &prop))
      MIRAY_CHECK(prop.vt == VT_BSTR)
      const UString name = _sourceName.IsEmpty() ? UString(prop.bstrVal) : _sourceName;
      UString lower(name);
      lower.MakeLower_Ascii();
      MIRAY_CHECK(name.Len() > 4 && StringsAreEqual_Ascii(lower.RightPtr(4), ".mfo"))
      static const wchar_t * const suffixes[] = { L".mfi", L".mai", L".mfd", L".001.mfi", L".001.mfd" };
      for (unsigned i = 0; i < Z7_ARRAY_SIZE(suffixes); i++)
      {
        UString next = name.Left(name.Len() - 4);
        next += suffixes[i];
        candidates.Add(next);
      }
    }
  }
  FOR_VECTOR (candidate, candidates)
  {
    CMyComPtr<IInStream> input;
    const HRESULT result = callback->GetStream(candidates[candidate], &input);
    if (result == S_FALSE || (result == S_OK && !input))
      continue;
    RINOK(result)
    CHandler *parent = new CHandler;
    CMyComPtr<IInStream> owner = parent;
    parent->_sourceName = candidates[candidate];
    parent->_depth = _depth + 1;
    const HRESULT structure = parent->OpenStructure(input, openCallback);
    if (structure == S_FALSE && _overlay)
      continue;
    RINOK(structure)
    if (parent->_imageId.Size() != 16 || memcmp(parent->_imageId, _baseId, 16) != 0)
      continue;
    MIRAY_CHECK(parent->_size == _size && parent->_sectorSize == _sectorSize)
    if (!_overlay)
    {
      MIRAY_CHECK(parent->_parts.Size() == _parts.Size())
      FOR_VECTOR (i, _parts)
        MIRAY_CHECK(_parts[i].Name == parent->_parts[i].Name && _parts[i].Base == parent->_parts[i].Base
            && _parts[i].Sectors == parent->_parts[i].Sectors)
    }
    parent->_skipLegacyOverlays = true;
    RINOK(parent->OpenContent(openCallback))
    if (_overlay && parent->_protected)
      _protected = true;
    _baseEncrypted = parent->_protected || parent->_encryption != 0 || parent->_baseEncrypted;
    _base = owner;
    return S_OK;
  }
  return S_FALSE;
}

HRESULT CHandler::ReadKeyStore(CRecordVector<UInt32> &offsets)
{
  const Byte *p = _keyStore;
  const size_t size = _keyStore.Size();
  MIRAY_CHECK(size >= 4)
  const UInt32 chunks = Read32(p);
  MIRAY_CHECK(chunks > 0 && chunks <= 4096)
  size_t position = 4;
  bool seen = false;
  for (UInt32 chunk = 0; chunk < chunks; chunk++)
  {
    MIRAY_CHECK(size - position >= 8)
    const UInt32 length = Read32(p + position + 4);
    MIRAY_CHECK(length <= size - position - 8)
    const size_t end = position + 8 + length;
    if (memcmp(p + position, "KSTO", 4) == 0)
    {
      MIRAY_CHECK(!seen && length >= 8 && Read32(p + position + 8) <= 1)
      seen = true;
      const UInt32 count = Read32(p + position + 12);
      MIRAY_CHECK(count > 0 && count <= 4096)
      position += 16;
      for (UInt32 entry = 0; entry < count; entry++)
      {
        MIRAY_CHECK(end - position >= 8)
        const UInt32 entrySize = Read32(p + position), headerSize = Read32(p + position + 4);
        MIRAY_CHECK(entrySize >= 8 && entrySize <= end - position
            && headerSize >= 8 && headerSize <= entrySize)
        const Byte *entryData = p + position;
        const Byte *wrapKey = GetImageWrapKey(ReadKeyField(entryData, 12));
        const UInt32 mode = ReadKeyField(entryData, 16);
        if (wrapKey && (_encryption ? (mode >= 1 && mode <= 5) : mode == 0))
        {
          const bool derived = mode == 1 || mode == 2;
          const unsigned keySize = _encryption == 0 || derived ? 0 : _encryption == 1 ? 16 : 32;
          const UInt32 passwordMethod = ReadKeyField(entryData, 24);
          const bool needsPassword = derived || mode == 3 || mode == 5 || (mode == 0 && _protected);
          MIRAY_CHECK((headerSize >= 40 || (!_encryption && !_protected
                  && (headerSize == 16 || headerSize == 20)))
              && (UInt64)headerSize + keySize + 32 <= entrySize
              && ReadKeyField(entryData, 8) == 0 && ReadKeyField(entryData, 20) == keySize
              && (!derived || _encryption == 2)
              && (needsPassword ? (_protected && (passwordMethod == 1 || passwordMethod == 2)) : passwordMethod == 0)
              && (UInt64)headerSize + keySize + ReadKeyField(entryData, 28)
                  + ReadKeyField(entryData, 32) + ReadKeyField(entryData, 36) + 32 == entrySize)
          CSha256 hash = _keyPrefixHash;
          Byte expected[SHA256_DIGEST_SIZE];
          HashKeyData(&hash, p + position, entrySize - SHA256_DIGEST_SIZE);
          Sha256_Final(&hash, expected);
          CByteBuffer trailer;
          trailer.CopyFrom(p + position + entrySize - SHA256_DIGEST_SIZE, SHA256_DIGEST_SIZE);
          DecryptEcb(trailer, trailer.Size(), wrapKey, 32);
          MIRAY_CHECK(memcmp(trailer, expected, sizeof(expected)) == 0)
          offsets.Add((UInt32)position);
        }
        position += entrySize;
      }
      MIRAY_CHECK(position == end)
    }
    position = end;
  }
  MIRAY_CHECK(position == size && !offsets.IsEmpty())
  return S_OK;
}

HRESULT CHandler::Unlock(IArchiveOpenCallback *openCallback)
{
  unsigned keySize = 0;
  CRecordVector<UInt32> keyOffsets;
  if (_hasKeyStore)
    RINOK(ReadKeyStore(keyOffsets))
  if (!_protected && !_encryption)
    return S_OK;
  MIRAY_CHECK(_hasKeyStore || (_protected && (_passwordType == 1 || _passwordType == 2)))
  if (_encryption)
    keySize = _encryption == 1 ? 16 : 32;
  Byte digest[SHA256_DIGEST_SIZE], passwordKeys[2][SHA256_DIGEST_SIZE];
  bool passwordMatches[2] = { false, false };
  if (_protected)
  {
    CMyComPtr<ICryptoGetTextPassword> callback;
    if (openCallback)
      openCallback->QueryInterface(IID_ICryptoGetTextPassword, (void **)&callback);
    if (!callback)
      return E_NOTIMPL;
    CMyComBSTR_Wipe password;
    RINOK(callback->CryptoGetTextPassword(&password))
    UString_Wipe unicode;
    if (password)
      unicode.SetFromBstr(password);
    AString_Wipe utf8;
    ConvertUnicodeToUTF8(unicode, utf8);
    HashPassword((const Byte *)utf8.Ptr(), utf8.Len(), NULL, digest);
    HashPassword(digest, sizeof(digest), _salt, passwordKeys[1]);
    HashPassword((const Byte *)utf8.Ptr(), utf8.Len(), _salt, passwordKeys[0]);
    for (unsigned method = 0; method < 2; method++)
    {
      HashPassword(passwordKeys[method], sizeof(passwordKeys[method]), _salt, digest);
      unsigned difference = 0;
      for (unsigned i = 0; i < sizeof(digest); i++)
        difference |= digest[i] ^ _verifier[i];
      passwordMatches[method] = difference == 0;
    }
  }
  bool keysAgree = true, haveKey = false;
  bool passwordAccepted = !_protected || (!_hasKeyStore && passwordMatches[_passwordType - 1]);
  if (!_hasKeyStore && passwordAccepted && keySize)
  {
    _key.CopyFrom(passwordKeys[_passwordType - 1], keySize);
    haveKey = true;
  }
  FOR_VECTOR (i, keyOffsets)
  {
    const Byte *entry = _keyStore + keyOffsets[i];
    const UInt32 passwordMethod = ReadKeyField(entry, 24);
    if (_protected && !passwordMatches[passwordMethod == 1 ? 0 : 1])
      continue;
    passwordAccepted = true;
    if (keySize)
    {
      CByteBuffer key;
      const UInt32 mode = ReadKeyField(entry, 16);
      if (mode == 1 || mode == 2)
        key.CopyFrom(passwordKeys[mode - 1], keySize);
      else
        key.CopyFrom(entry + Read32(entry + 4), keySize);
      if (mode == 3 || mode == 5)
        DecryptEcb(key, keySize, passwordKeys[1], sizeof(passwordKeys[1]));
      if (mode == 4 || mode == 5)
      {
        const Byte *wrapKey = GetImageWrapKey(Read32(entry + 12));
        DecryptEcb(key, keySize, wrapKey, 32);
      }
      if (!haveKey)
      {
        _key.CopyFrom(key, keySize);
        haveKey = true;
      }
      else if (memcmp(_key, key, keySize) != 0)
        keysAgree = false;
      key.Wipe();
    }
  }
  if (!keysAgree)
    _key.Wipe();
  memset(digest, 0, sizeof(digest));
  memset(passwordKeys, 0, sizeof(passwordKeys));
  // Win32 ERROR_INVALID_PASSWORD; preserves the error through the open callback.
  return !passwordAccepted ? (HRESULT)0x80070056 : keysAgree ? S_OK : S_FALSE;
}

HRESULT CHandler::ReadBlocks()
{
  FOR_VECTOR (i, _parts)
    RINOK(ReadPartBlocks(i))
  _blocks.Sort(CompareBlocks, NULL);
  unsigned blockIndex = 0;
  FOR_VECTOR (i, _parts)
  {
    CPart &part = _parts[i];
    UInt64 next = 0;
    auto unavailable = [&](UInt64 start, UInt64 end) -> HRESULT
    {
      if (start == end)
        return S_OK;
      MIRAY_CHECK(start < end && end <= part.Sectors
          && part.Errors.Size() < kItemLimit && _unavailable.Size() < kItemLimit)
      CExtent range;
      range.Offset = start;
      range.Size = end - start;
      part.Errors.Add(range);
      range.Offset = (part.Base + start) * _sectorSize;
      range.Size *= _sectorSize;
      _unavailable.Add(range);
      return S_OK;
    };
    while (blockIndex < _blocks.Size() && _blocks[blockIndex].Part == i)
    {
      const CBlock &block = _blocks[blockIndex++];
      const UInt64 sector = block.Virt / _sectorSize - part.Base;
      MIRAY_CHECK(sector >= next)
      if (part.Damaged)
      {
        RINOK(unavailable(next, sector))
      }
      else
        MIRAY_CHECK(_smart || _dependent || part.IsMapped() || IsUnavailableRange(part, next, sector))
      next = sector + block.Unpacked / _sectorSize;
    }
    if (part.Damaged)
    {
      RINOK(unavailable(next, part.Sectors))
      MergeExtents(part.Errors);
    }
    else
      MIRAY_CHECK(_smart || _dependent || part.IsMapped() || IsUnavailableRange(part, next, part.Sectors))
  }
  MIRAY_CHECK(blockIndex == _blocks.Size())
  MergeExtents(_unavailable);
  return S_OK;
}

HRESULT CHandler::VerifyRegionChecksums()
{
  static const CMethodId methods[] = { 0, 1, 0x208, 0x201, 0xA, 0x223, 0xA, 0x223 };
  CByteBuffer buffer;
  FOR_VECTOR (partIndex, _parts)
  {
    const CPart &part = _parts[partIndex];
    if (part.Checksums.IsEmpty())
      continue;
    if (!buffer.Size())
      buffer.Alloc(1 << 20);
    CMyComPtr<IHasher> hashers[Z7_ARRAY_SIZE(methods)];
    CSha3 sha3[2];
    bool useSha3[2] = { false, false };
    FOR_VECTOR (i, part.Checksums)
    {
      const UInt32 method = part.Checksums[i].Method;
      AString name;
      RINOK(CreateHasher(
        #ifdef Z7_EXTERNAL_CODECS
        NULL,
        #endif
        methods[method], name, hashers[method]))
      MIRAY_CHECK(hashers[method] && hashers[method]->GetDigestSize() == kRegionDigestSizes[method])
      hashers[method]->Init();
      if (method >= 6)
      {
        const unsigned index = method - 6;
        useSha3[index] = true;
        sha3[index].blockSize = SHA3_BLOCK_SIZE_FROM_DIGEST_SIZE(kRegionDigestSizes[method]);
        Sha3_Init(&sha3[index]);
      }
    }
    _virtPos = part.Base * _sectorSize;
    const UInt64 end = _virtPos + part.Sectors * _sectorSize;
    bool available = true;
    while (_virtPos < end)
    {
      const UInt32 take = end - _virtPos < buffer.Size() ? (UInt32)(end - _virtPos) : (UInt32)buffer.Size();
      UInt32 processed = 0;
      RINOK(Read(buffer, take, &processed))
      if (_stream_unavailData)
      {
        available = false;
        break;
      }
      MIRAY_CHECK(processed > 0)
      for (unsigned method = 1; method < Z7_ARRAY_SIZE(methods); method++)
        if (hashers[method])
          hashers[method]->Update(buffer, processed);
      for (unsigned index = 0; index < 2; index++)
        if (useSha3[index])
          Sha3_Update(&sha3[index], buffer, processed);
    }
    if (available)
      FOR_VECTOR (i, part.Checksums)
      {
        const CRegionChecksum &checksum = part.Checksums[i];
        const UInt32 method = checksum.Method;
        const unsigned size = kRegionDigestSizes[method];
        Byte digest[64];
        hashers[method]->Final(digest);
        bool matches = memcmp(digest, checksum.Digest, size) == 0;
        // Some producers use SHA-2 for the two SHA-3 selections.
        if (method >= 6)
        {
          Sha3_Final(&sha3[method - 6], digest, size, false);
          matches |= memcmp(digest, checksum.Digest, size) == 0;
        }
        MIRAY_CHECK(matches)
      }
    _stream_unavailData = false;
  }
  _virtPos = 0;
  return S_OK;
}

HRESULT CHandler::ReadPartBlocks(unsigned partIndex)
{
  CPart &part = _parts[partIndex];
  if (part.IsMapped())
  {
    const unsigned first = _blocks.Size();
    const unsigned headerIndex = part.StreamIndex;
    RINOK(ReadMsff(headerIndex, part.Sectors * _sectorSize, _blocks, part.StreamIndex))
    for (unsigned i = first; i < _blocks.Size(); i++)
    {
      _blocks[i].Part = partIndex;
      _blocks[i].Virt += part.Base * _sectorSize;
    }
    return S_OK;
  }
  const CImageStream &s = _streams[part.StreamIndex];
  auto damaged = [&]() -> HRESULT
  {
    MIRAY_CHECK(part.Incomplete)
    part.Damaged = _damaged = true;
    return S_OK;
  };
  if (part.Kind == 4)
  {
    MIRAY_CHECK(s.Size == part.Stored * _sectorSize)
    for (UInt64 offset = 0; offset < s.Size;)
    {
      const UInt64 remain = s.Size - offset;
      CBlock b;
      b.Virt = part.Base * _sectorSize + offset;
      b.Pos = offset;
      b.Unpacked = remain < (1 << 22) ? (UInt32)remain : (1 << 22);
      b.Packed = b.Unpacked;
      b.Part = partIndex;
      b.Compressed = false;
      MIRAY_CHECK(_blocks.Size() < kItemLimit)
      _blocks.Add(b);
      offset += b.Unpacked;
    }
    return S_OK;
  }
  if (part.Incomplete && part.Stored == 0 && s.Size == 22
      && IsUnavailableRange(part, 0, part.Sectors))
  {
    Byte header[22];
    RINOK(ReadData(s, 0, header, sizeof(header)))
    unsigned nonzero = 0;
    for (unsigned i = 0; i < sizeof(header); i++)
      nonzero |= header[i];
    if (!nonzero)
      return S_OK;
  }
  UInt64 pos = 0, next = 0, stored = 0, previousEnd = 0;
  bool hasPrevious = false, previousCompressed = false;
  unsigned recordCount = 0;
  while (pos < s.Size)
  {
    Byte h[34];
    MIRAY_CHECK(++recordCount <= kItemLimit)
    if (s.Size - pos < 4)
      return damaged();
    RINOK(ReadData(s, pos, h, 4))
    const bool continuation = memcmp(h, "BLOC", 4) != 0 && memcmp(h, "CBLO", 4) != 0;
    bool compressed = false, end = false;
    UInt64 sector;
    UInt32 count = 0;
    if (continuation)
    {
      count = Read32(h);
      if (!hasPrevious || previousCompressed || !count || count > 4096)
        return damaged();
      sector = previousEnd;
      pos += 4;
    }
    else
    {
      if (s.Size - pos < 22)
        return damaged();
      RINOK(ReadData(s, pos, h, 22))
      compressed = memcmp(h, "CBLOCK1.0.00", 12) == 0;
      if (!compressed && memcmp(h, "BLOCKS0.0.01", 12) != 0
          && memcmp(h, "BLOCKS0.1.01", 12) != 0)
        return damaged();
      sector = Read64(h + 12);
      end = sector == (UInt64)(Int64)-1;
      pos += 22;
      if (!end)
      {
        if (s.Size - pos < (compressed ? 8u : 4u))
          return damaged();
        RINOK(ReadData(s, pos, h + 22, compressed ? 8u : 4u))
        count = Read32(h + 22);
      }
      const unsigned headerSize = compressed && !end ? 30 : 22;
      UInt32 sum = 0;
      for (unsigned i = 0; i < headerSize; i += 2)
        sum += Read16(h + i);
      while (sum >> 16)
        sum = (sum & 0xffff) + (sum >> 16);
      if (sum != 0xffff)
        return damaged();
    }
    if (end)
    {
      MIRAY_CHECK(pos == s.Size && (part.Progress || stored == part.Stored)
          && (part.Progress || _smart || _dependent || IsUnavailableRange(part, next, part.Sectors)))
      if (part.HasLast && !part.Progress)
        MIRAY_CHECK(stored ? part.Last == next - 1 : part.Last == 0 || part.Last == (UInt64)(Int64)-1)
      if (part.Progress)
        part.Damaged = true;
      return S_OK;
    }
    if (!(sector <= part.Sectors
        && count > 0 && count <= part.Sectors - sector
        && stored <= (part.Progress ? part.Sectors : part.Stored)
        && count <= (part.Progress ? part.Sectors : part.Stored) - stored
        && (UInt64)count * _sectorSize <= kBlockLimit))
      return damaged();
    MIRAY_CHECK(_blocks.Size() < kItemLimit)
    if (!continuation)
      pos += 4;
    CBlock b;
    b.Virt = (part.Base + sector) * _sectorSize;
    b.Part = partIndex;
    b.Unpacked = count * _sectorSize;
    b.Compressed = compressed;
    if (compressed)
    {
      if (s.Size - pos < 8)
        return damaged();
      RINOK(ReadData(s, pos, h + 26, 8))
      if (part.Method == 0)
        return damaged();
      b.Packed = Read32(h + 30);
      pos += 8;
    }
    else
    {
      // A compressed region can store incompressible blocks verbatim.
      b.Packed = b.Unpacked;
    }
    if (!(b.Packed > 0 && b.Packed <= kBlockLimit && pos <= s.Size && b.Packed <= s.Size - pos
        && (!_encryption || b.Packed % AES_BLOCK_SIZE == 0)))
      return damaged();
    b.Pos = pos;
    _blocks.Add(b);
    pos += b.Packed;
    if (sector + count > next)
      next = sector + count;
    stored += count;
    previousEnd = sector + count;
    previousCompressed = compressed;
    hasPrevious = true;
  }
  return damaged();
}

HRESULT CHandler::DecodeBlock(unsigned index)
{
  const CBlock &b = _blocks[index];
  const CPart &part = _parts[b.Part];
  _cacheIndex = (unsigned)-1;
  _cache.Alloc(b.Unpacked);
  if (!b.Compressed)
  {
    RINOK(ReadData(_streams[part.StreamIndex], b.Pos, _cache, b.Unpacked))
    MIRAY_CHECK(part.IsMapped() || !_encryption || DecryptEcb(_cache, b.Unpacked, _key, (unsigned)_key.Size()))
  }
  else
  {
    _packed.Alloc(b.Packed);
    RINOK(ReadData(_streams[part.StreamIndex], b.Pos, _packed, b.Packed))
    MIRAY_CHECK(!_encryption || DecryptEcb(_packed, b.Packed, _key, (unsigned)_key.Size()))
    if (part.Method == 2)
    {
      MIRAY_CHECK(DecodeLz4(_packed, b.Packed, _cache, b.Unpacked, _encryption != 0))
    }
    else if (part.Method == 1)
    {
      _bufIn.Create_if_Empty();
      _bufOut.Create_if_Empty();
      _zlib.Create_if_Empty();
      _bufIn->Init(_packed, b.Packed);
      _bufOut->Init(_cache, b.Unpacked);
      const UInt64 size = b.Unpacked;
      RINOK(_zlib.Interface()->Code(_bufIn, _bufOut, NULL, &size, NULL))
      MIRAY_CHECK(_bufOut->GetPos() == b.Unpacked
          && CheckPadding(b.Packed, (size_t)_zlib->GetInputProcessedSize(), _encryption != 0))
    }
    else if (part.Method == 3)
    {
      SizeT out = b.Unpacked, in = b.Packed;
      ELzmaStatus status;
      const SRes result = LzmaDecode(_cache, &out, _packed, &in, part.LzmaProps,
          LZMA_PROPS_SIZE, LZMA_FINISH_END, &status, &g_Alloc);
      MIRAY_CHECK(result == SZ_OK && out == b.Unpacked && CheckPadding(b.Packed, in, _encryption != 0)
          && (status == LZMA_STATUS_FINISHED_WITH_MARK || status == LZMA_STATUS_MAYBE_FINISHED_WITHOUT_MARK))
    }
    else
      return S_FALSE;
  }
  _cacheIndex = index;
  return S_OK;
}

HRESULT CHandler::ReadOverlayTable(unsigned streamIndex, const COverlayMap &map,
    unsigned level, UInt64 position, UInt64 virt,
    unsigned &items, CRecordVector<CBlock> &blocks)
{
  const UInt64 bytes = (UInt64)map.Entries[level] * map.Width;
  MIRAY_CHECK(position <= map.End && bytes <= map.End - position
      && map.Entries[level] <= kItemLimit - items)
  items += map.Entries[level];
  CByteBuffer data;
  data.Alloc((size_t)bytes);
  RINOK(ReadData(_streams[streamIndex], position, data, data.Size()))
  for (UInt32 i = 0; i < map.Entries[level] && virt < map.Size; i++)
  {
    const UInt64 pointer = map.Width == 4 ? Read32(data + (size_t)i * 4) : Read64(data + (size_t)i * 8);
    const UInt64 unused = map.Width == 4 ? (UInt64)(UInt32)-1 : (UInt64)-1;
    if (pointer != unused)
    {
      MIRAY_CHECK(pointer > 0 && pointer < map.End / _sectorSize)
      const UInt64 offset = pointer * _sectorSize;
      if (level + 1 < map.Levels)
      {
        RINOK(ReadOverlayTable(streamIndex, map, level + 1, offset, virt, items, blocks))
      }
      else
      {
        MIRAY_CHECK(map.Span[level] <= map.End - offset)
        UInt64 remaining = map.Size - virt < map.Span[level] ? map.Size - virt : map.Span[level];
        UInt64 relative = 0;
        while (remaining)
        {
          MIRAY_CHECK(blocks.Size() < kItemLimit)
          const UInt32 take = remaining < kBlockLimit ? (UInt32)remaining : kBlockLimit;
          CBlock &block = blocks.AddNew_NoConstruct();
          block.Virt = virt + relative;
          block.Pos = offset + relative;
          block.Packed = block.Unpacked = take;
          block.Part = 0;
          block.Compressed = false;
          relative += take;
          remaining -= take;
        }
      }
    }
    if (map.Span[level] >= map.Size - virt)
      break;
    virt += map.Span[level];
  }
  return S_OK;
}

HRESULT CHandler::ReadOverlay(CRecordVector<CBlock> &blocks, unsigned &streamIndex)
{
  unsigned headerIndex = _streams.Size();
  FOR_VECTOR (i, _streams)
    if (_streams[i].Name == "_overlay")
      headerIndex = i;
  MIRAY_CHECK(_overlay ? _baseId.Size() == 16 : _imageId.Size() == 16)
  return ReadMsff(headerIndex, _size, blocks, streamIndex);
}

HRESULT CHandler::ReadMsff(unsigned headerIndex, UInt64 logicalSize,
    CRecordVector<CBlock> &blocks, unsigned &streamIndex)
{
  MIRAY_CHECK(headerIndex < _streams.Size() && _streams[headerIndex].Size == 132)
  Byte h[132];
  RINOK(ReadData(_streams[headerIndex], 0, h, sizeof(h)))
  MIRAY_CHECK(memcmp(h, "MSFF", 4) == 0 && Read32(h + 4) == 0x01000000
      && Read64(h + 96) == _sectorSize && Read64(h + 104) == logicalSize / _sectorSize
      && Read64(h + 88) == logicalSize && Read64(h + 72) >= logicalSize)
  AString name;
  name.SetFrom((const char *)h + 8, 32);
  const int nul = name.Find((char)0);
  if (nul >= 0)
    name.DeleteFrom((unsigned)nul);
  streamIndex = 0;
  for (; streamIndex < _streams.Size(); streamIndex++)
    if (_streams[streamIndex].Name == name)
      break;
  MIRAY_CHECK(streamIndex < _streams.Size() && streamIndex != headerIndex)
  COverlayMap map;
  map.Size = logicalSize;
  map.Width = h[131];
  map.Levels = 0;
  MIRAY_CHECK((map.Width == 4 || map.Width == 8) && h[130] < 32
      && ((UInt64)1 << h[130]) * map.Width == _sectorSize && Read32(h + 120) > 0)
  for (unsigned i = 0; i < 6; i++)
  {
    if (!h[124 + i])
    {
      for (unsigned j = i + 1; j < 6; j++)
        MIRAY_CHECK(h[124 + j] == 0)
      break;
    }
    map.Entries[map.Levels++] = (UInt32)h[124 + i] * (_sectorSize / map.Width);
  }
  MIRAY_CHECK(map.Levels > 0)
  map.Span[map.Levels - 1] = (UInt64)Read32(h + 120) * _sectorSize;
  for (unsigned i = map.Levels - 1; i > 0; i--)
  {
    MIRAY_CHECK(map.Span[i] <= (UInt64)-1 / map.Entries[i])
    map.Span[i - 1] = map.Span[i] * map.Entries[i];
  }
  MIRAY_CHECK(map.Span[0] <= (UInt64)-1 / map.Entries[0]
      && map.Span[0] * map.Entries[0] >= logicalSize
      && Read64(h + 112) > 0 && Read64(h + 112) <= _streams[streamIndex].Size / _sectorSize)
  map.End = Read64(h + 112) * _sectorSize;
  unsigned items = 0;
  RINOK(ReadOverlayTable(streamIndex, map, 0, 0, 0, items, blocks))
  return S_OK;
}

HRESULT CHandler::OpenLegacyOverlay(IArchiveOpenCallback *openCallback)
{
  Z7_DECL_CMyComPtr_QI_FROM(IArchiveOpenVolumeCallback, callback, openCallback)
  MIRAY_CHECK(callback && _depth < 15)
  UString prefix;
  if (!_sourceName.IsEmpty())
    for (unsigned i = 0; i < _sourceName.Len(); i++)
      if (_sourceName[i] == L'/' || _sourceName[i] == L'\\')
        prefix = _sourceName.Left(i + 1);
  UStringVector candidates;
  candidates.Add(prefix + L"ovl.mfo");
  bool locator = false;
  FOR_VECTOR (i, _streams)
    if (_streams[i].Name == "mfo_locator.inf" || _streams[i].Name == "ovl_locator.inf")
    {
      locator = true;
      const CImageStream &stream = _streams[i];
      MIRAY_CHECK(stream.Size <= (1 << 16))
      CByteBuffer data;
      data.Alloc((size_t)stream.Size);
      RINOK(ReadData(stream, 0, data, data.Size()))
      for (size_t pos = 0; pos < data.Size();)
      {
        size_t end = pos;
        while (end < data.Size() && data[end] != '\n') end++;
        while (pos < end && (data[pos] == ' ' || data[pos] == '\t' || data[pos] == '\r')) pos++;
        if (pos < end && data[pos] == '{')
        {
          while (pos < end && data[pos] != '}') pos++;
          MIRAY_CHECK(pos < end)
          pos++;
          while (pos < end)
          {
            while (pos < end && (data[pos] == ' ' || data[pos] == '\t' || data[pos] == '\r')) pos++;
            if (pos == end) break;
            MIRAY_CHECK(data[pos++] == '"')
            const size_t start = pos;
            while (pos < end && data[pos] != '"') pos++;
            MIRAY_CHECK(pos < end && pos > start && pos - start <= 4096)
            AString name;
            name.SetFrom((const char *)(const Byte *)data + start, (unsigned)(pos - start));
            for (unsigned j = 0; j < name.Len(); j++)
              MIRAY_CHECK((Byte)name[j] >= 32)
            UString filename;
            MIRAY_CHECK(ConvertUTF8ToUnicode(name, filename) && candidates.Size() < 4096)
            if (filename[0] != L'/' && filename[0] != L'\\'
                && !(filename.Len() >= 2 && filename[1] == L':'))
              filename.Insert(0, prefix);
            if (_streams[i].Name == "ovl_locator.inf")
              filename += L"/meta.ovl";
            candidates.Add(filename);
            pos++;
          }
        }
        pos = end + 1;
      }
    }
  FOR_VECTOR (i, candidates)
  {
    CMyComPtr<IInStream> input;
    const HRESULT result = callback->GetStream(candidates[i], &input);
    if (result == S_FALSE || (result == S_OK && !input))
      continue;
    RINOK(result)
    CHandler *overlay = new CHandler;
    CMyComPtr<IInStream> owner = overlay;
    overlay->_sourceName = candidates[i];
    overlay->_depth = _depth + 1;
    RINOK(overlay->OpenStructure(input, openCallback))
    MIRAY_CHECK(overlay->_overlay && overlay->_baseId.Size() == 16 && _imageId.Size() == 16)
    if (memcmp(overlay->_baseId, _imageId, 16) != 0)
      continue;
    MIRAY_CHECK(overlay->_sectorSize == _sectorSize && overlay->_size == _size)
    overlay->_parentName = prefix + L"mfic.img";
    RINOK(overlay->OpenContent(openCallback))
    _legacyComposite = owner;
    _embeddedStream = 0;
    return S_OK;
  }
  MIRAY_CHECK(!locator)
  return ReadLegacyMask(_embeddedBlocks, _embeddedStream, AString("data.ovl"), AString("mask.ovl"));
}

HRESULT CHandler::ReadLegacyMask(CRecordVector<CBlock> &blocks, unsigned &streamIndex,
    const AString &dataName, const AString &maskName)
{
  unsigned mask = (unsigned)-1, data = (unsigned)-1;
  FOR_VECTOR (i, _streams)
  {
    if (_streams[i].Name == maskName) mask = i;
    if (_streams[i].Name == dataName) data = i;
  }
  if (mask == (unsigned)-1 && data == (unsigned)-1)
    return S_OK;
  MIRAY_CHECK(mask != (unsigned)-1 && data != (unsigned)-1)
  const UInt64 sectors = _size / _sectorSize;
  const UInt64 bytes = (sectors + 7) / 8;
  MIRAY_CHECK(_streams[mask].Size >= bytes && _streams[data].Size <= _size
      && _streams[data].Size % _sectorSize == 0)
  CByteBuffer buffer;
  buffer.Alloc(1 << 16);
  for (UInt64 offset = 0; offset < bytes;)
  {
    const size_t take = bytes - offset < buffer.Size() ? (size_t)(bytes - offset) : buffer.Size();
    RINOK(ReadData(_streams[mask], offset, buffer, take))
    for (size_t i = 0; i < take; i++)
      for (unsigned bit = 0; bit < 8 && ((offset + i) * 8 + bit) < sectors; bit++)
        if (buffer[i] & (1 << bit))
        {
          const UInt64 position = ((offset + i) * 8 + bit) * _sectorSize;
          MIRAY_CHECK(position <= _streams[data].Size && _sectorSize <= _streams[data].Size - position)
          if (!blocks.IsEmpty() && blocks.Back().Virt + blocks.Back().Unpacked == position
              && blocks.Back().Unpacked <= kBlockLimit - _sectorSize)
          {
            blocks.Back().Unpacked += _sectorSize;
            blocks.Back().Packed += _sectorSize;
          }
          else
          {
            MIRAY_CHECK(blocks.Size() < kItemLimit)
            CBlock &block = blocks.AddNew_NoConstruct();
            block.Virt = block.Pos = position;
            block.Unpacked = block.Packed = _sectorSize;
            block.Part = 0;
            block.Compressed = false;
          }
        }
    offset += take;
  }
  streamIndex = data;
  return S_OK;
}

HRESULT CHandler::OpenLegacyStream(IArchiveOpenVolumeCallback *callback, const UString &name,
    CMyComPtr<IInStream> &input, UInt64 &size)
{
  UString stem = name;
  UString ending = L".dat";
  if (name.Len() > 3 && StringsAreEqual_Ascii(name.RightPtr(3), ".ix"))
  {
    stem = name.Left(name.Len() - 3);
    ending = L".ix";
  }
  else if (name.Len() > 4 && StringsAreEqual_Ascii(name.RightPtr(4), ".ovl"))
  {
    stem = name.Left(name.Len() - 4);
    ending = L".ovl";
  }
  CMyComPtr2<IInStream, CMultiStream> combined;
  combined.Create_if_Empty();
  size = 0;
  for (unsigned index = 0;; index++)
  {
    wchar_t decimal[16];
    char hexadecimal[16], suffix[16];
    ConvertUInt32ToString(index + 1, decimal);
    ConvertUInt32ToHex(index + 1, hexadecimal);
    ConvertUInt32ToHex(index, suffix);
    UStringVector candidates;
    UString next = stem;
    next += L'.';
    for (unsigned i = (unsigned)wcslen(decimal); i < 4; i++) next += L'0';
    next += decimal;
    next += ending;
    candidates.Add(next);
    next = stem;
    next += L'.';
    for (unsigned i = (unsigned)strlen(hexadecimal); i < 3; i++) next += L'0';
    for (const char *p = hexadecimal; *p; p++) next += (wchar_t)*p;
    next += ending;
    candidates.Add(next);
    next = name;
    if (index)
    {
      next += L'.';
      for (const char *p = suffix; *p; p++) next += (wchar_t)*p;
    }
    candidates.Add(next);
    if (index)
    {
      next = name;
      next += L'.';
      for (unsigned i = (unsigned)strlen(suffix); i < 8; i++) next += L'0';
      for (const char *p = suffix; *p; p++) next += (wchar_t)*p;
      candidates.Add(next);
    }
    input.Release();
    FOR_VECTOR (i, candidates)
    {
      const HRESULT result = callback->GetStream(candidates[i], &input);
      if (result != S_OK && result != S_FALSE) return result;
      if (input) break;
    }
    if (!input)
    {
      if (index == 0) return S_FALSE;
      break;
    }
    UInt64 length;
    RINOK(InStream_GetSize_SeekToEnd(input, length))
    MIRAY_CHECK(length <= (UInt64)(Int64)-1 - size && combined->Streams.Size() < 1024)
    RINOK(InStream_SeekSet(input, 0))
    CMultiStream::CSubStreamInfo entry;
    entry.Stream = input;
    entry.Size = length;
    combined->Streams.Add(entry);
    size += length;
  }
  RINOK(combined->Init())
  input = combined;
  return S_OK;
}

HRESULT CHandler::OpenLegacy(IArchiveOpenCallback *openCallback)
{
  MIRAY_CHECK(_phySize >= 8 && _phySize <= kMetadataLimit && openCallback)
  Z7_DECL_CMyComPtr_QI_FROM(IArchiveOpenVolumeCallback, callback, openCallback)
  MIRAY_CHECK(callback)
  CByteBuffer metadata;
  metadata.Alloc((size_t)_phySize);
  RINOK(ReadAt(0, metadata, metadata.Size()))
  const UInt32 version = Read32(metadata + 4);
  const bool legacy = memcmp(metadata, "IMGC", 4) == 0 && version == 1;
  MIRAY_CHECK(legacy || (memcmp(metadata, "MFIC", 4) == 0
      && version >= 2 && version <= 4 && metadata.Size() >= 12))
  AStringVector names;
  AString maskName;
  UInt64 imageType = 0;
  UInt32 regionKind = 0;
  unsigned count = 0;
  UInt32 textEncoding = 0;
  bool inPart = false;
  for (size_t pos = legacy ? 8 : 12; pos < metadata.Size();)
  {
    MIRAY_CHECK(++count <= 4096 && metadata.Size() - pos >= 8)
    const UInt32 key = Read32(metadata + pos) & 0x7fffffff;
    const UInt32 size = Read32(metadata + pos + 4);
    pos += 8;
    MIRAY_CHECK(size <= metadata.Size() - pos)
    if (key == 5)
      inPart = true;
    else if (key == 0x1008)
      inPart = false;
    else if (key == 7 && !inPart)
    {
      MIRAY_CHECK(size >= 1 && size <= 4)
      const UInt64 encoding = ReadNumber(metadata + pos, size);
      MIRAY_CHECK(encoding <= 1)
      textEncoding = (UInt32)encoding;
    }
    if (key == 0x1000)
    {
      MIRAY_CHECK(size > 0 && size < 4096)
      AString name;
      MIRAY_CHECK(ReadText(metadata + pos, size, textEncoding, name))
      for (unsigned i = 0; i < name.Len(); i++)
        MIRAY_CHECK((Byte)name[i] >= 32 && name[i] != '/' && name[i] != '\\' && name[i] != ':')
      MIRAY_CHECK(name != "." && name != ".." && name != "mfic.img")
      FOR_VECTOR (i, names)
        MIRAY_CHECK(names[i] != name)
      names.Add(name);
    }
    else if (key == 0x100d && size > 0 && size < 4096)
    {
      MIRAY_CHECK(ReadText(metadata + pos, size, textEncoding, maskName))
    }
    else if (key == 0x1007 && size >= 1 && size <= 4)
    {
      regionKind = 0;
      for (unsigned i = 0; i < size; i++)
        regionKind |= (UInt32)metadata[pos + i] << (8 * i);
    }
    else if (key == 17 && size == 8)
      imageType = Read64(metadata + pos);
    pos += size;
  }
  MIRAY_CHECK(!names.IsEmpty())
  const bool maskOverlay = (imageType == 15 || imageType == 21) && regionKind == 7;
  if (maskOverlay)
  {
    MIRAY_CHECK(names.Size() == 1 && !maskName.IsEmpty() && maskName != "." && maskName != "..")
    for (unsigned i = 0; i < maskName.Len(); i++)
      MIRAY_CHECK((Byte)maskName[i] >= 32 && maskName[i] != '/' && maskName[i] != '\\' && maskName[i] != ':')
    names[0] += ".ovl";
    names.Add(maskName + ".ovl");
  }
  const unsigned required = names.Size();
  names.Add(AString("data.ovl"));
  names.Add(AString("mask.ovl"));
  names.Add(AString("mfo_locator.inf"));
  names.Add(AString("ovl_locator.inf"));
  UString prefix;
  if (!_sourceName.IsEmpty())
    for (unsigned i = 0; i < _sourceName.Len(); i++)
      if (_sourceName[i] == L'/' || _sourceName[i] == L'\\')
        prefix = _sourceName.Left(i + 1);
  CMyComPtr2<IInStream, CMultiStream> combined;
  combined.Create_if_Empty();
  CMultiStream::CSubStreamInfo first;
  first.Stream = Stream;
  first.Size = _phySize;
  RINOK(InStream_SeekSet(Stream, 0))
  combined->Streams.Add(first);
  CImageStream &meta = _streams.AddNew();
  meta.Name = maskOverlay ? "meta.ovl" : "mfic.img";
  meta.Size = _phySize;
  CExtent extent;
  extent.Offset = 0;
  extent.Size = _phySize;
  meta.Extents.Add(extent);
  FOR_VECTOR (i, names)
  {
    bool exists = false;
    FOR_VECTOR (j, _streams)
      exists |= _streams[j].Name == names[i];
    if (exists)
      continue;
    UString filename;
    MIRAY_CHECK(ConvertUTF8ToUnicode(names[i], filename))
    filename.Insert(0, prefix);
    CMyComPtr<IInStream> input;
    UInt64 size = 0;
    const HRESULT result = OpenLegacyStream(callback, filename, input, size);
    if (i >= required && (result == S_FALSE || (result == S_OK && !input)))
      continue;
    RINOK(result)
    MIRAY_CHECK(input)
    MIRAY_CHECK(size <= (UInt64)(Int64)-1 - _phySize)
    RINOK(InStream_SeekSet(input, 0))
    CMultiStream::CSubStreamInfo entry;
    entry.Stream = input;
    entry.Size = size;
    combined->Streams.Add(entry);
    CImageStream &part = _streams.AddNew();
    part.Name = names[i];
    part.Size = size;
    extent.Offset = _phySize;
    extent.Size = size;
    part.Extents.Add(extent);
    _phySize += size;
  }
  RINOK(combined->Init())
  Stream = combined;
  _totalPhysicalSize = _phySize;
  _legacyDirectory = true;
  return S_OK;
}

HRESULT CHandler::OpenStructure(IInStream *stream, IArchiveOpenCallback *openCallback)
{
  Stream = stream;
  _sectorSize = 512;
  _method = 0;
  _cacheIndex = (unsigned)-1;
  RINOK(InStream_GetSize_SeekToEnd(stream, _phySize))
  _totalPhysicalSize = _phySize;
  _firstPhysicalSize = _phySize;
  Byte sig[4];
  RINOK(ReadAt(0, sig, 4))
  _isMai = memcmp(sig, "HSAM", 4) == 0 || memcmp(sig, "XSAM", 4) == 0;
  if (memcmp(sig, "MFIC", 4) == 0 || memcmp(sig, "IMGC", 4) == 0)
    RINOK(OpenLegacy(openCallback))
  else if (_isMai)
    RINOK(OpenMai(openCallback))
  else
    RINOK(OpenMfi(openCallback))
  return ReadMetadata();
}

HRESULT CHandler::OpenContent(IArchiveOpenCallback *openCallback)
{
  RINOK(Unlock(openCallback))
  RINOK(VerifyMaiChecksums())
  RINOK(OpenBase(openCallback))
  if (_overlay)
  {
    CPart &part = _parts[0];
    if (part.Kind == 7)
      return ReadLegacyMask(_blocks, part.StreamIndex, part.Name + ".ovl", part.MaskName + ".ovl");
    return ReadOverlay(_blocks, part.StreamIndex);
  }
  RINOK(ReadBlocks())
  RINOK(VerifyRegionChecksums())
  if (_legacyDirectory)
    return _skipLegacyOverlays ? S_OK : OpenLegacyOverlay(openCallback);
  if (!_isMai)
    FOR_VECTOR (i, _streams)
      if (_streams[i].Name == "_overlay")
        return ReadOverlay(_embeddedBlocks, _embeddedStream);
  return S_OK;
}

HRESULT CHandler::Open2(IInStream *stream, IArchiveOpenCallback *openCallback)
{
  RINOK(OpenStructure(stream, openCallback))
  return OpenContent(openCallback);
}

Z7_COM7F_IMF(CHandler::Open(IInStream *stream, const UInt64 *, IArchiveOpenCallback *callback))
{
  COM_TRY_BEGIN
  Close();
  HRESULT result;
  try
  {
    result = Open2(stream, callback);
  }
  catch (...)
  {
    Close();
    throw;
  }
  if (result != S_OK)
  {
    Close();
    return result;
  }
  CMyComPtr<ISequentialInStream> input;
  RINOK(GetStream(0, &input))
  Byte data[8192];
  size_t processed = sizeof(data);
  if (ReadStream(input, data, &processed) == S_OK)
  {
    if (processed >= 512 && data[510] == 0x55 && data[511] == 0xaa)
    {
      _imgExt = "mbr";
      for (unsigned sector = 512; sector <= 4096; sector <<= 3)
        if (processed >= sector + 8 && memcmp(data + sector, "EFI PART", 8) == 0)
          _imgExt = "gpt";
    }
    else if (NExt::IsArc_Ext(data, processed) == k_IsArc_Res_YES)
      _imgExt = "ext";
  }
  Reset_VirtPos();
  return S_OK;
  COM_TRY_END
}

Z7_COM7F_IMF(CHandler::Seek(Int64 offset, UInt32 origin, UInt64 *newPosition))
{
  UInt64 position;
  if (origin == STREAM_SEEK_SET)
    position = 0;
  else if (origin == STREAM_SEEK_CUR)
    position = _virtPos;
  else if (origin == STREAM_SEEK_END)
    position = _size;
  else
    return STG_E_INVALIDFUNCTION;
  if (offset < 0)
  {
    const UInt64 backwards = (UInt64)(-(offset + 1)) + 1;
    if (backwards > position)
      return HRESULT_WIN32_ERROR_NEGATIVE_SEEK;
    position -= backwards;
  }
  else
  {
    if ((UInt64)offset > ((UInt64)1 << 63) - 1 - position)
      return E_INVALIDARG;
    position += (UInt64)offset;
  }
  _virtPos = position;
  if (newPosition)
    *newPosition = position;
  return S_OK;
}

HRESULT CHandler::ReadView(bool overlay, UInt64 position, void *data, UInt32 size, UInt32 *processedSize)
{
  *processedSize = 0;
  if (position >= _size || !size)
    return S_OK;
  if (_size - position < size)
    size = (UInt32)(_size - position);
  if (overlay)
  {
    if (_legacyComposite)
    {
      RINOK(InStream_SeekSet(_legacyComposite, position))
      return _legacyComposite->Read(data, size, processedSize);
    }
    unsigned low = 0, high = _embeddedBlocks.Size();
    while (low < high)
    {
      const unsigned mid = low + (high - low) / 2;
      if (_embeddedBlocks[mid].Virt <= position)
        low = mid + 1;
      else
        high = mid;
    }
    if (low && position - _embeddedBlocks[low - 1].Virt < _embeddedBlocks[low - 1].Unpacked)
    {
      const CBlock &block = _embeddedBlocks[low - 1];
      const UInt64 offset = position - block.Virt;
      const UInt32 take = block.Unpacked - (UInt32)offset < size ? block.Unpacked - (UInt32)offset : size;
      RINOK(ReadData(_streams[_embeddedStream], block.Pos + offset, data, take))
      *processedSize = take;
      return S_OK;
    }
    if (low < _embeddedBlocks.Size() && _embeddedBlocks[low].Virt - position < size)
      size = (UInt32)(_embeddedBlocks[low].Virt - position);
  }
  RINOK(InStream_SeekSet(this, position))
  return Read(data, size, processedSize);
}

Z7_COM7F_IMF(CHandler::Read(void *data, UInt32 size, UInt32 *processedSize))
{
  if (processedSize)
    *processedSize = 0;
  if (_virtPos >= _size || size == 0)
    return S_OK;
  unsigned errorLow = 0, errorHigh = _unavailable.Size();
  while (errorLow < errorHigh)
  {
    const unsigned mid = errorLow + (errorHigh - errorLow) / 2;
    if (_unavailable[mid].Offset <= _virtPos)
      errorLow = mid + 1;
    else
      errorHigh = mid;
  }
  if (errorLow && _virtPos - _unavailable[errorLow - 1].Offset < _unavailable[errorLow - 1].Size)
  {
    _stream_unavailData = true;
    return S_OK;
  }
  if (errorLow < _unavailable.Size() && _unavailable[errorLow].Offset - _virtPos < size)
    size = (UInt32)(_unavailable[errorLow].Offset - _virtPos);
  unsigned low = 0, high = _blocks.Size();
  while (low < high)
  {
    const unsigned mid = low + (high - low) / 2;
    if (_blocks[mid].Virt <= _virtPos)
      low = mid + 1;
    else
      high = mid;
  }
  // Omitted logical-image gaps read as zero. Gaps require no block entries
  // or buffers proportional to the logical disk size.
  if (low == 0 || _virtPos - _blocks[low - 1].Virt >= _blocks[low - 1].Unpacked)
  {
    MIRAY_CHECK(_regionGaps || _base)
    const UInt64 end = low < _blocks.Size() ? _blocks[low].Virt : _size;
    MIRAY_CHECK(end > _virtPos)
    const UInt32 take = end - _virtPos < size ? (UInt32)(end - _virtPos) : size;
    if (_base)
    {
      RINOK(InStream_SeekSet(_base, _virtPos))
      RINOK(ReadStream_FALSE(_base, data, take))
    }
    else
      memset(data, 0, take);
    _virtPos += take;
    if (processedSize)
      *processedSize = take;
    return S_OK;
  }
  const unsigned index = low - 1;
  const CBlock &b = _blocks[index];
  const UInt64 offset = _virtPos - b.Virt;
  MIRAY_CHECK(offset < b.Unpacked)
  if (_cacheIndex != index)
  {
    const HRESULT result = DecodeBlock(index);
    if (result != S_OK)
    {
      _stream_dataError = true;
      return result;
    }
  }
  const UInt32 take = size < b.Unpacked - offset ? size : (UInt32)(b.Unpacked - offset);
  memcpy(data, _cache + (size_t)offset, take);
  _virtPos += take;
  if (processedSize)
    *processedSize = take;
  return S_OK;
}

Z7_COM7F_IMF(CHandler::GetStream(UInt32 index, ISequentialInStream **stream))
{
  COM_TRY_BEGIN
  *stream = NULL;
  if (!Stream || index > (_embeddedStream == (unsigned)-1 ? 0 : 1))
    return S_FALSE;
  CMyComPtr<ISequentialInStream> result = new CEmbeddedViewStream(this, _size, index != 0);
  *stream = result.Detach();
  return S_OK;
  COM_TRY_END
}

Z7_COM7F_IMF(CHandler::GetNumberOfItems(UInt32 *numItems))
{
  *numItems = _embeddedStream == (unsigned)-1 ? 1 : 2;
  return S_OK;
}

Z7_COM7F_IMF(CHandler::Extract(const UInt32 *indices, UInt32 numItems,
    Int32 testMode, IArchiveExtractCallback *callback))
{
  COM_TRY_BEGIN
  if (numItems == 0)
    return S_OK;
  const UInt32 count = _embeddedStream == (unsigned)-1 ? 1 : 2;
  const bool all = numItems == (UInt32)-1;
  if (all)
    numItems = count;
  else if (!indices)
    return E_INVALIDARG;
  for (UInt32 i = 0; i < numItems; i++)
    if ((all ? i : indices[i]) >= count)
      return E_INVALIDARG;
  RINOK(callback->SetTotal((UInt64)numItems * _size))
  CMyComPtr2_Create<ICompressProgressInfo, CLocalProgress> progress;
  progress->Init(callback, false);
  CMyComPtr2_Create<ICompressCoder, NCompress::CCopyCoder> copy;
  for (UInt32 i = 0; i < numItems; i++)
  {
    progress->InSize = progress->OutSize = (UInt64)i * _size;
    RINOK(progress->SetCur())
    const UInt32 index = all ? i : indices[i];
    const Int32 askMode = testMode ? NExtract::NAskMode::kTest : NExtract::NAskMode::kExtract;
    CMyComPtr<ISequentialOutStream> output;
    RINOK(callback->GetStream(index, &output, askMode))
    if (!testMode && !output)
      continue;
    RINOK(callback->PrepareOperation(askMode))
    ClearStreamVars();
    CMyComPtr<ISequentialInStream> input;
    RINOK(GetStream(index, &input))
    const HRESULT result = copy.Interface()->Code(input, output, NULL, &_size, progress);
    if (result != S_OK && result != S_FALSE)
      return result;
    int operation = NExtract::NOperationResult::kOK;
    if (_stream_unavailData)
      operation = NExtract::NOperationResult::kUnavailable;
    else if (_stream_unsupportedMethod)
      operation = NExtract::NOperationResult::kUnsupportedMethod;
    else if (result != S_OK || _stream_dataError || _damaged)
      operation = NExtract::NOperationResult::kDataError;
    else if (copy->TotalSize != _size)
      operation = NExtract::NOperationResult::kUnexpectedEnd;
    output.Release();
    RINOK(callback->SetOperationResult(operation))
  }
  progress->InSize = progress->OutSize = (UInt64)numItems * _size;
  return progress->SetCur();
  COM_TRY_END
}

Z7_COM7F_IMF(CHandler::Close())
{
  _streams.Clear();
  _parts.Clear();
  _maiVolumes.Clear();
  _maiVolumeRecords.Clear();
  _maiChecksums.Clear();
  _base.Release();
  _legacyComposite.Release();
  _imageId.Free();
  _baseId.Free();
  _parentName.Empty();
  _sourceName.Empty();
  _depth = 0;
  _dependent = false;
  _overlay = false;
  _growableMfi = false;
  _legacyDirectory = false;
  _skipLegacyOverlays = false;
  _blocks.Clear();
  _embeddedBlocks.Clear();
  _embeddedStream = (unsigned)-1;
  _unavailable.Clear();
  _cache.Free();
  _packed.Free();
  _key.Wipe();
  _key.Free();
  _keyStore.Free();
  _salt.Free();
  _verifier.Free();
  Stream.Release();
  _phySize = 0;
  _totalPhysicalSize = 0;
  _firstPhysicalSize = 0;
  _numVolumes = 1;
  _maiChunkSize = 0;
  _maiMaxChunks = 0;
  _splitSize = (UInt64)(Int64)-1;
  _version = 0;
  _method = 0;
  _smart = false;
  _regionGaps = false;
  _maiRecovered = false;
  _encryption = 0;
  _passwordType = (UInt32)-1;
  _protected = false;
  _hasKeyStore = false;
  _baseEncrypted = false;
  _sectorSize = 512;
  ResetDiskView();
  return S_OK;
}

static const Byte kProps[] = { kpidSize, kpidPackSize, kpidEncrypted };
static const Byte kArcProps[] = { kpidSectorSize, kpidMethod, kpidUnpackVer, kpidComment,
  kpidEncrypted, kpidNumVolumes, kpidTotalPhySize, kpidWarning };
IMP_IInArchive_Props
IMP_IInArchive_ArcProps

Z7_COM7F_IMF(CHandler::GetProperty(UInt32 index, PROPID propID, PROPVARIANT *value))
{
  COM_TRY_BEGIN
  NCOM::CPropVariant prop;
  switch (propID)
  {
    case kpidPath:
      if (_embeddedStream != (unsigned)-1)
        prop = index == 0 ? "base.img" : "overlay.img";
      break;
    case kpidSize: prop = _size; break;
    case kpidPackSize: prop = _totalPhysicalSize; break;
    case kpidEncrypted: prop = _protected || _encryption != 0 || _baseEncrypted; break;
    case kpidExtension: prop = _imgExt ? _imgExt : "img"; break;
  }
  prop.Detach(value);
  return S_OK;
  COM_TRY_END
}

Z7_COM7F_IMF(CHandler::GetArchiveProperty(PROPID propID, PROPVARIANT *value))
{
  COM_TRY_BEGIN
  NCOM::CPropVariant prop;
  switch (propID)
  {
    case kpidMainSubfile:
      if (_embeddedStream == (unsigned)-1)
        prop = (UInt32)0;
      break;
    case kpidPhySize: prop = _firstPhysicalSize; break;
    case kpidTotalPhySize: prop = _totalPhysicalSize; break;
    case kpidNumVolumes: prop = _numVolumes; break;
    case kpidSectorSize: prop = _sectorSize; break;
    case kpidUnpackVer: prop = _version; break;
    case kpidEncrypted: prop = _protected || _encryption != 0 || _baseEncrypted; break;
    case kpidWarning:
      if (_damaged)
        prop = "Damaged data in an incomplete image";
      else if (_maiRecovered)
        prop = "Recovered MAI synchronization snapshot";
      break;
    case kpidComment:
      prop = _overlay ? "Miray Overlay Image"
          : _smart ? "Miray SmartImage (omitted sectors read as zero)"
          : _isMai ? "Miray Archive Image" : "Miray File Image";
      break;
    case kpidMethod:
    {
      static const char * const names[] = { "Copy", "Deflate", "LZ4", "LZMA", "Mixed" };
      if (_method < Z7_ARRAY_SIZE(names))
        prop = names[_method];
      break;
    }
  }
  prop.Detach(value);
  return S_OK;
  COM_TRY_END
}

// Temporary local format ID; an upstream ID must be assigned by the maintainer.
REGISTER_ARC_I("Miray", "mfi mai mfd mfo mais", NULL, 0xBE,
  kSignatures, 0, NArcInfoFlags::kMultiSignature, NULL)

#undef MIRAY_CHECK

}}
