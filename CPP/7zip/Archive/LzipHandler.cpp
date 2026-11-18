// LzipHandler.cpp

#include "StdAfx.h"

#include "../../Common/ComTry.h"

#include "../../Windows/PropVariant.h"

#include "../Common/ProgressUtils.h"
#include "../Common/RegisterArc.h"
#include "../Common/StreamUtils.h"

#include "../Compress/CopyCoder.h"
#include "../Compress/LzmaDecoder.h"

#include "Common/DummyOutStream.h"

#include "../../../C/CpuArch.h"

using namespace NWindows;

namespace NArchive {
namespace NLzip {

// Lzip member structure:
// Header (6 bytes): "LZIP" + version (1 byte) + dictionary_size (1 byte)
// LZMA stream
// Trailer (20 bytes): CRC32 (4 bytes) + data_size (8 bytes) + member_size (8 bytes)

static const UInt32 kHeaderSize = 6;
static const UInt32 kTrailerSize = 20;

// Lzip always uses these LZMA parameters: lc=3, lp=0, pb=2
// Encoded as: lc + lp*9 + pb*9*5 = 3 + 0 + 90 = 93 = 0x5D
static const Byte kLzmaLiteralProps = 0x5D;

static const Byte kSignature[] = { 'L', 'Z', 'I', 'P' };
static const Byte kSignatureSize = 4;

static inline UInt32 GetDictSize(Byte ds)
{
  // Dictionary size formula from lzip specification:
  // bits 4-0 (0x1F) contain the exponent (dictionary size = 2^exponent)
  // bits 7-5 contain the numerator of the fraction to subtract
  // dictionary_size = base_size - fraction * (base_size >> 4)
  const unsigned exp = ds & 0x1F;
  const UInt32 base = (UInt32)1 << exp;
  const unsigned frac = ds >> 5;
  return base - (frac * (base >> 4));
}

API_FUNC_static_IsArc IsArc_Lzip(const Byte *p, size_t size)
{
  if (size < kHeaderSize)
    return k_IsArc_Res_NEED_MORE;
  if (memcmp(p, kSignature, kSignatureSize) != 0)
    return k_IsArc_Res_NO;

  const Byte version = p[4];
  if (version != 1)
    return k_IsArc_Res_NO; // Only version 1 is supported

  const Byte ds = p[5];
  // Valid dictionary size: 4 KiB to 512 MiB
  // ds byte value encodes: exponent in bits 4-0, fraction in bits 7-5
  // Minimum valid exponent is 12 (2^12 = 4 KiB)
  // Maximum valid exponent is 29 (2^29 = 512 MiB)
  const unsigned exp = ds & 0x1F;
  if (exp < 12 || exp > 29)
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

  bool _packSize_Defined;
  bool _unpackSize_Defined;
  bool _numMembers_Defined;

  UInt64 _packSize;
  UInt64 _unpackSize;
  UInt64 _numMembers;

  Byte _version;
  UInt32 _dictSize;
};

static const Byte kProps[] =
{
  kpidSize,
  kpidPackSize
};

static const Byte kArcProps[] =
{
  kpidNumStreams
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
    case kpidNumStreams: if (_numMembers_Defined) prop = _numMembers; break;
    case kpidErrorFlags:
    {
      UInt32 v = 0;
      if (!_isArc) v |= kpv_ErrorFlags_IsNotArc;
      if (_needMoreInput) v |= kpv_ErrorFlags_UnexpectedEnd;
      if (_dataAfterEnd) v |= kpv_ErrorFlags_DataAfterEnd;
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
    Byte buf[kHeaderSize];
    RINOK(ReadStream_FALSE(stream, buf, kHeaderSize))
    if (IsArc_Lzip(buf, kHeaderSize) == k_IsArc_Res_NO)
      return S_FALSE;

    _version = buf[4];
    _dictSize = GetDictSize(buf[5]);

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

  _packSize_Defined = false;
  _unpackSize_Defined = false;
  _numMembers_Defined = false;

  _packSize = 0;
  _version = 0;
  _dictSize = 0;

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

  // Read header
  Byte header[kHeaderSize];
  RINOK(ReadStream_FALSE(_seqStream, header, kHeaderSize))

  if (IsArc_Lzip(header, kHeaderSize) == k_IsArc_Res_NO)
  {
    _isArc = false;
    opRes = NExtract::NOperationResult::kIsNotArc;
  }
  else
  {
    _version = header[4];
    _dictSize = GetDictSize(header[5]);

    // Construct LZMA properties (5 bytes): props_byte + dictionary_size (4 bytes LE)
    Byte lzmaProps[5];
    lzmaProps[0] = kLzmaLiteralProps; // lc=3, lp=0, pb=2
    SetUi32(lzmaProps + 1, _dictSize);

    CMyComPtr2_Create<ICompressCoder, NCompress::NLzma::CDecoder> decoder;

    RINOK(decoder->SetDecoderProperties2(lzmaProps, 5))

    decoder->FinishStream = true;

    CMyComPtr2_Create<ISequentialOutStream, CDummyOutStream> outStream;
    outStream->SetStream(realOutStream);
    outStream->Init();

    CMyComPtr2_Create<ICompressProgressInfo, CLocalProgress> lps;
    lps->Init(extractCallback, true);

    _dataAfterEnd = false;
    _needMoreInput = false;

    HRESULT result = decoder.Interface()->Code(_seqStream, outStream, NULL, NULL, lps);

    if (result != S_FALSE && result != S_OK)
      return result;

    const UInt64 inProcessedSize = decoder->GetInputProcessedSize();
    const UInt64 outProcessedSize = decoder->GetOutputProcessedSize();

    _packSize = kHeaderSize + inProcessedSize + kTrailerSize;
    _unpackSize = outProcessedSize;
    _numMembers = 1;

    _packSize_Defined = true;
    _unpackSize_Defined = true;
    _numMembers_Defined = true;

    lps.Interface()->SetRatioInfo(&_packSize, &_unpackSize);

    if (decoder->NeedsMoreInput())
    {
      _needMoreInput = true;
      opRes = NExtract::NOperationResult::kUnexpectedEnd;
    }
    else if (result == S_FALSE)
    {
      opRes = NExtract::NOperationResult::kDataError;
    }
    else if (!decoder->CheckFinishStatus(true)) // Expect end marker
    {
      opRes = NExtract::NOperationResult::kDataError;
    }
    else
    {
      opRes = NExtract::NOperationResult::kOK;
    }
  }
 }
  return extractCallback->SetOperationResult(opRes);

  COM_TRY_END
}


static const Byte k_Signature[] = { 'L', 'Z', 'I', 'P', 1 };

REGISTER_ARC_I(
  "lzip", "lz tlz", "* .tar", 0x10,
  k_Signature,
  0,
  NArcInfoFlags::kKeepName
  , IsArc_Lzip)

}}
