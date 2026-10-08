// Lz4Handler.cpp

#include "StdAfx.h"

#include "../../Common/ComTry.h"

#include "../../Windows/PropVariant.h"

#include "../Common/ProgressUtils.h"
#include "../Common/RegisterArc.h"
#include "../Common/StreamUtils.h"

#include "../Compress/CopyCoder.h"

#include "Common/DummyOutStream.h"

#include "../../../C/CpuArch.h"
#include "../../../C/Alloc.h"
#include "../../../C/Lz4Dec.h"

using namespace NWindows;

namespace NArchive {
namespace NLz4 {

/*
LZ4 Frame format:
  Magic: 4 bytes (0x184D2204 little-endian)
  Frame Descriptor:
    FLG byte:
      bits 7-6: Version (must be 01)
      bit 5: Block Independence
      bit 4: Block Checksum flag
      bit 3: Content Size flag
      bit 2: Content Checksum flag
      bit 1: Reserved (0)
      bit 0: DictID flag
    BD byte:
      bit 7: Reserved (0)
      bits 6-4: Block Max Size (4=64KB, 5=256KB, 6=1MB, 7=4MB)
      bits 3-0: Reserved (0)
    [Content Size: 8 bytes if Content Size flag set]
    [DictID: 4 bytes if DictID flag set]
    Header Checksum: 1 byte (XXH32 >> 8)
  Data Blocks:
    Block Size: 4 bytes (bit 31: 1=uncompressed, bits 30-0: size)
    Block Data: size bytes
    [Block Checksum: 4 bytes if Block Checksum flag set]
    ... repeat until Block Size == 0
  End Mark: 4 bytes (0x00000000)
  [Content Checksum: 4 bytes if Content Checksum flag set]
*/

static const UInt32 kMagic = 0x184D2204;
static const unsigned kMagicSize = 4;
static const unsigned kMinHeaderSize = 7;  // magic + FLG + BD + HC
static const unsigned kMaxHeaderSize = 19; // magic + FLG + BD + content_size(8) + dictid(4) + HC

static const unsigned kBlockSizes[] = {
  0,         // 0: reserved
  0,         // 1: reserved
  0,         // 2: reserved
  0,         // 3: reserved
  64 << 10,  // 4: 64 KB
  256 << 10, // 5: 256 KB
  1 << 20,   // 6: 1 MB
  4 << 20    // 7: 4 MB
};

struct CFrameInfo
{
  bool BlockIndependence;
  bool BlockChecksum;
  bool ContentSizePresent;
  bool ContentChecksum;
  bool DictIdPresent;
  UInt32 BlockMaxSize;
  UInt64 ContentSize;
  UInt32 DictId;

  unsigned GetHeaderSize() const
  {
    return kMagicSize + 2 + (ContentSizePresent ? 8 : 0) + (DictIdPresent ? 4 : 0) + 1;
  }

  bool Parse(const Byte *p, size_t size)
  {
    if (size < kMinHeaderSize)
      return false;

    // Check magic
    if (GetUi32(p) != kMagic)
      return false;
    p += 4;

    Byte flg = p[0];
    Byte bd = p[1];
    p += 2;

    // Version must be 01
    if ((flg >> 6) != 1)
      return false;

    // Reserved bit in FLG must be 0
    if (flg & 2)
      return false;

    // Reserved bits in BD must be 0
    if (bd & 0x8F)
      return false;

    BlockIndependence = (flg & 0x20) != 0;
    BlockChecksum = (flg & 0x10) != 0;
    ContentSizePresent = (flg & 0x08) != 0;
    ContentChecksum = (flg & 0x04) != 0;
    DictIdPresent = (flg & 0x01) != 0;

    unsigned blockMaxSizeCode = (bd >> 4) & 7;
    if (blockMaxSizeCode < 4)
      return false; // Reserved values
    BlockMaxSize = kBlockSizes[blockMaxSizeCode];

    ContentSize = 0;
    DictId = 0;

    unsigned headerSize = kMagicSize + 2;

    if (ContentSizePresent)
    {
      headerSize += 8;
      if (size < headerSize + 1)
        return false;
      ContentSize = GetUi64(p);
      p += 8;
    }

    if (DictIdPresent)
    {
      headerSize += 4;
      if (size < headerSize + 1)
        return false;
      DictId = GetUi32(p);
      p += 4;
    }

    // Header checksum (we don't verify it, just skip)
    headerSize += 1;

    return true;
  }
};

API_FUNC_static_IsArc IsArc_Lz4(const Byte *p, size_t size)
{
  if (size < kMinHeaderSize)
    return k_IsArc_Res_NEED_MORE;

  // Check magic
  if (GetUi32(p) != kMagic)
    return k_IsArc_Res_NO;

  Byte flg = p[4];
  Byte bd = p[5];

  // Version must be 01
  if ((flg >> 6) != 1)
    return k_IsArc_Res_NO;

  // Reserved bit in FLG must be 0
  if (flg & 2)
    return k_IsArc_Res_NO;

  // Reserved bits in BD must be 0
  if (bd & 0x8F)
    return k_IsArc_Res_NO;

  // Block max size must be valid
  unsigned blockMaxSizeCode = (bd >> 4) & 7;
  if (blockMaxSizeCode < 4)
    return k_IsArc_Res_NO;

  return k_IsArc_Res_YES;
}
}

Z7_CLASS_IMP_CHandler_IInArchive_1(
  IArchiveOpenSeq
)
  CMyComPtr<IInStream> _stream;
  CMyComPtr<ISequentialInStream> _seqStream;

  bool _isArc;
  bool _needSeekToStart;
  bool _dataAfterEnd;
  bool _needMoreInput;
  bool _dataError;

  bool _packSize_Defined;
  bool _unpackSize_Defined;

  UInt64 _packSize;
  UInt64 _unpackSize;

  CFrameInfo _frameInfo;
};

static const Byte kProps[] =
{
  kpidSize,
  kpidPackSize
};

static const Byte kArcProps[] =
{
  kpidPhySize
};

IMP_IInArchive_Props
IMP_IInArchive_ArcProps

Z7_COM7F_IMF(CHandler::GetArchiveProperty(PROPID propID, PROPVARIANT *value))
{
  NCOM::CPropVariant prop;
  switch (propID)
  {
    case kpidPhySize: if (_packSize_Defined) prop = _packSize; break;
    case kpidUnpackSize: if (_unpackSize_Defined) prop = _unpackSize; break;
    case kpidErrorFlags:
    {
      UInt32 v = 0;
      if (!_isArc) v |= kpv_ErrorFlags_IsNotArc;
      if (_needMoreInput) v |= kpv_ErrorFlags_UnexpectedEnd;
      if (_dataAfterEnd) v |= kpv_ErrorFlags_DataAfterEnd;
      if (_dataError) v |= kpv_ErrorFlags_DataError;
      prop = v;
      break;
    }
    default: break;
  }
  prop.Detach(value);
  return S_OK;
}

Z7_COM7F_IMF(CHandler::GetNumberOfItems(UInt32 *numItems))
{
  *numItems = 1;
  return S_OK;
}

Z7_COM7F_IMF(CHandler::GetProperty(UInt32 /* index */, PROPID propID, PROPVARIANT *value))
{
  NCOM::CPropVariant prop;
  switch (propID)
  {
    case kpidPackSize: if (_packSize_Defined) prop = _packSize; break;
    case kpidSize: if (_unpackSize_Defined) prop = _unpackSize; break;
    default: break;
  }
  prop.Detach(value);
  return S_OK;
}

Z7_COM7F_IMF(CHandler::Open(IInStream *stream, const UInt64 *, IArchiveOpenCallback *))
{
  COM_TRY_BEGIN
  Close();
  {
    Byte buf[kMaxHeaderSize];
    RINOK(ReadStream_FALSE(stream, buf, kMinHeaderSize))

    if (IsArc_Lz4(buf, kMinHeaderSize) == k_IsArc_Res_NO)
      return S_FALSE;

    if (!_frameInfo.Parse(buf, kMinHeaderSize))
      return S_FALSE;

    // Read additional header bytes if needed
    unsigned headerSize = _frameInfo.GetHeaderSize();
    if (headerSize > kMinHeaderSize)
    {
      RINOK(ReadStream_FALSE(stream, buf + kMinHeaderSize, headerSize - kMinHeaderSize))
      if (!_frameInfo.Parse(buf, headerSize))
        return S_FALSE;
    }

    if (_frameInfo.ContentSizePresent)
    {
      _unpackSize = _frameInfo.ContentSize;
      _unpackSize_Defined = true;
    }

    _isArc = true;
    _stream = stream;
    _seqStream = stream;
    _needSeekToStart = true;
  }
  return S_OK;
  COM_TRY_END
}


Z7_COM7F_IMF(CHandler::OpenSeq(ISequentialInStream *stream))
{
  Close();
  _isArc = true;
  _seqStream = stream;
  return S_OK;
}

Z7_COM7F_IMF(CHandler::Close())
{
  _isArc = false;
  _needSeekToStart = false;
  _dataAfterEnd = false;
  _needMoreInput = false;
  _dataError = false;

  _packSize_Defined = false;
  _unpackSize_Defined = false;

  _packSize = 0;
  _unpackSize = 0;

  _seqStream.Release();
  _stream.Release();
  return S_OK;
}


Z7_COM7F_IMF(CHandler::Extract(const UInt32 *indices, UInt32 numItems,
    Int32 testMode, IArchiveExtractCallback *extractCallback))
{
  COM_TRY_BEGIN
  if (numItems == 0)
    return S_OK;
  if (numItems != (UInt32)(Int32)-1 && (numItems != 1 || indices[0] != 0))
    return E_INVALIDARG;

  if (_packSize_Defined)
  {
    RINOK(extractCallback->SetTotal(_packSize))
  }

  Int32 opRes;
 {
  CMyComPtr<ISequentialOutStream> realOutStream;
  const Int32 askMode = testMode ?
      NExtract::NAskMode::kTest :
      NExtract::NAskMode::kExtract;
  RINOK(extractCallback->GetStream(0, &realOutStream, askMode))
  if (!testMode && !realOutStream)
    return S_OK;

  RINOK(extractCallback->PrepareOperation(askMode))

  if (_needSeekToStart)
  {
    if (!_stream)
      return E_FAIL;
    RINOK(InStream_SeekToBegin(_stream))
  }
  else
    _needSeekToStart = true;

  // Read and parse header
  Byte header[kMaxHeaderSize];
  RINOK(ReadStream_FALSE(_seqStream, header, kMinHeaderSize))

  CFrameInfo frameInfo;
  if (!frameInfo.Parse(header, kMinHeaderSize))
  {
    _isArc = false;
    opRes = NExtract::NOperationResult::kIsNotArc;
  }
  else
  {
    unsigned headerSize = frameInfo.GetHeaderSize();
    if (headerSize > kMinHeaderSize)
    {
      RINOK(ReadStream_FALSE(_seqStream, header + kMinHeaderSize, headerSize - kMinHeaderSize))
    }

    CMyComPtr2_Create<ISequentialOutStream, CDummyOutStream> outStream;
    outStream->SetStream(realOutStream);
    outStream->Init();

    CMyComPtr2_Create<ICompressProgressInfo, CLocalProgress> lps;
    lps->Init(extractCallback, true);

    _dataAfterEnd = false;
    _needMoreInput = false;
    _dataError = false;

    UInt64 inProcessed = headerSize;
    UInt64 outProcessed = 0;
    bool finished = false;

    // Allocate buffers
    Byte *compBuf = NULL;
    Byte *decompBuf = NULL;
    UInt32 blockMaxSize = frameInfo.BlockMaxSize;

    compBuf = (Byte *)MyAlloc(blockMaxSize);
    decompBuf = (Byte *)MyAlloc(blockMaxSize);

    if (!compBuf || !decompBuf)
    {
      MyFree(compBuf);
      MyFree(decompBuf);
      return E_OUTOFMEMORY;
    }

    opRes = NExtract::NOperationResult::kOK;

    // Process blocks
    while (!finished)
    {
      // Read block size
      Byte blockHeader[4];
      HRESULT res = ReadStream_FALSE(_seqStream, blockHeader, 4);
      if (res != S_OK)
      {
        _needMoreInput = true;
        opRes = NExtract::NOperationResult::kUnexpectedEnd;
        break;
      }
      inProcessed += 4;

      UInt32 blockSize = GetUi32(blockHeader);

      // End mark
      if (blockSize == 0)
      {
        finished = true;
        // Skip content checksum if present
        if (frameInfo.ContentChecksum)
        {
          Byte checksum[4];
          res = ReadStream_FALSE(_seqStream, checksum, 4);
          if (res == S_OK)
            inProcessed += 4;
        }
        break;
      }

      bool uncompressed = (blockSize & 0x80000000) != 0;
      blockSize &= 0x7FFFFFFF;

      if (blockSize > blockMaxSize)
      {
        _dataError = true;
        opRes = NExtract::NOperationResult::kDataError;
        break;
      }

      // Read block data
      res = ReadStream_FALSE(_seqStream, compBuf, blockSize);
      if (res != S_OK)
      {
        _needMoreInput = true;
        opRes = NExtract::NOperationResult::kUnexpectedEnd;
        break;
      }
      inProcessed += blockSize;

      // Skip block checksum if present
      if (frameInfo.BlockChecksum)
      {
        Byte checksum[4];
        res = ReadStream_FALSE(_seqStream, checksum, 4);
        if (res != S_OK)
        {
          _needMoreInput = true;
          opRes = NExtract::NOperationResult::kUnexpectedEnd;
          break;
        }
        inProcessed += 4;
      }

      // Decompress or copy
      const Byte *outData;
      SizeT outLen;

      if (uncompressed)
      {
        // Uncompressed block - write directly from compBuf
        outData = compBuf;
        outLen = blockSize;
      }
      else
      {
        // Decompress
        outLen = blockMaxSize;
        SizeT srcConsumed;
        SRes sres = Lz4Dec_DecodeBlock(compBuf, blockSize, decompBuf, &outLen, &srcConsumed);
        if (sres != SZ_OK)
        {
          _dataError = true;
          opRes = NExtract::NOperationResult::kDataError;
          break;
        }
        outData = decompBuf;
      }

      // Write output
      if (outLen > 0)
      {
        const HRESULT writeRes = WriteStream(outStream, outData, outLen);
        if (writeRes != S_OK)
        {
          MyFree(compBuf);
          MyFree(decompBuf);
          return writeRes;
        }
        outProcessed += outLen;
      }

      // Progress
      lps.Interface()->SetRatioInfo(&inProcessed, &outProcessed);
    }

    MyFree(compBuf);
    MyFree(decompBuf);

    _packSize = inProcessed;
    _unpackSize = outProcessed;
    _packSize_Defined = true;
    _unpackSize_Defined = true;
  }
 }
  return extractCallback->SetOperationResult(opRes);

  COM_TRY_END
}


static const Byte k_Signature[] = { 0x04, 0x22, 0x4D, 0x18 };

REGISTER_ARC_I(
  "lz4", "lz4 tlz4", "* .tar", 0x11,
  k_Signature,
  0,
  NArcInfoFlags::kKeepName
  , IsArc_Lz4)

}}
