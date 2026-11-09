// ChainedExtract.cpp

#include "StdAfx.h"

#include "../../Common/StreamBinder.h"
#include "../../Common/VirtThread.h"

#include "ChainedExtract.h"


static void SetExtractOpResMessage(Int32 opRes, UString &message)
{
  message.Empty();

  switch (opRes)
  {
    case NArchive::NExtract::NOperationResult::kUnsupportedMethod:
      message = "Unsupported Method";
      break;
    case NArchive::NExtract::NOperationResult::kDataError:
      message = "Data Error";
      break;
    case NArchive::NExtract::NOperationResult::kCRCError:
      message = "CRC Failed";
      break;
    case NArchive::NExtract::NOperationResult::kUnavailable:
      message = "Unavailable data";
      break;
    case NArchive::NExtract::NOperationResult::kUnexpectedEnd:
      message = "Unexpected end of data";
      break;
    case NArchive::NExtract::NOperationResult::kDataAfterEnd:
      message = "There are some data after the end of the payload data";
      break;
    case NArchive::NExtract::NOperationResult::kIsNotArc:
      message = "Is not archive";
      break;
    case NArchive::NExtract::NOperationResult::kHeadersError:
      message = "Headers Error";
      break;
    case NArchive::NExtract::NOperationResult::kWrongPassword:
      message = "Wrong password";
      break;
  }
}


static HRESULT CheckOuterStreamResult(Int32 opRes, UString &errorMessage)
{
  if (opRes == NArchive::NExtract::NOperationResult::kOK)
    return S_OK;

  SetExtractOpResMessage(opRes, errorMessage);
  if (errorMessage.IsEmpty())
    errorMessage = "Error";
  errorMessage = UString("Outer stream: ") + errorMessage;
  return E_FAIL;
}


static HRESULT DrainChainedStream(ISequentialInStream *stream)
{
  Byte buf[1 << 15];

  for (;;)
  {
    UInt32 processed = 0;
    RINOK(stream->Read(buf, (UInt32)sizeof(buf), &processed))
    if (processed == 0)
      return S_OK;
  }
}


Z7_CLASS_IMP_COM_1(
  CChainedStreamExtractCallback
  , IArchiveExtractCallback
)
  Z7_IFACE_COM7_IMP(IProgress)
public:
  CMyComPtr<IFolderArchiveExtractCallback> Progress;
  CMyComPtr<ISequentialOutStream> Stream;
  Int32 OperationResult;
  bool MultiMode;
  UInt64 CompletedBeforeArc;

  void Init(IFolderArchiveExtractCallback *progress, ISequentialOutStream *stream,
      bool multiMode, UInt64 completedBeforeArc)
  {
    Progress = progress;
    Stream = stream;
    OperationResult = NArchive::NExtract::NOperationResult::kOK;
    MultiMode = multiMode;
    CompletedBeforeArc = completedBeforeArc;
  }
};


Z7_COM7F_IMF(CChainedStreamExtractCallback::SetTotal(UInt64 size))
{
  if (MultiMode)
    return S_OK;
  return Progress ? Progress->SetTotal(size) : S_OK;
}


Z7_COM7F_IMF(CChainedStreamExtractCallback::SetCompleted(const UInt64 *completeValue))
{
  if (MultiMode)
  {
    if (!Progress || !completeValue)
      return S_OK;
    const UInt64 completed = CompletedBeforeArc + *completeValue;
    return Progress->SetCompleted(&completed);
  }
  return Progress ? Progress->SetCompleted(completeValue) : S_OK;
}


Z7_COM7F_IMF(CChainedStreamExtractCallback::GetStream(
    UInt32 index, ISequentialOutStream **outStream, Int32 /* askExtractMode */))
{
  *outStream = NULL;
  if (index != 0 || !Stream)
    return E_FAIL;
  *outStream = Stream.Detach();
  return S_OK;
}


Z7_COM7F_IMF(CChainedStreamExtractCallback::PrepareOperation(Int32 /* askExtractMode */))
{
  return S_OK;
}


Z7_COM7F_IMF(CChainedStreamExtractCallback::SetOperationResult(Int32 opRes))
{
  OperationResult = opRes;
  return S_OK;
}


struct CChainedStreamExtractThread Z7_final:
  public CVirtThread
{
  const CArc *Arc;
  CMyComPtr<IArchiveExtractCallback> Callback;
  HRESULT Result;

  CChainedStreamExtractThread():
      Arc(NULL),
      Result(S_OK)
      {}

  void Execute() Z7_override
  {
    Result = Arc->Archive->Extract(NULL, (UInt32)(Int32)-1, 0, Callback);
  }
};


static int FindChainedFormatIndex(
    const CCodecs *codecs,
    const CArc &arc,
    const CExtractOptions &options)
{
  if (!options.EnableChainedExtract)
    return -1;
  if (options.StdInMode || options.StdOutMode)
    return -1;
  if (arc.FormatIndex < 0)
    return -1;
  const CArcInfoEx &ai = codecs->Formats[(unsigned)arc.FormatIndex];
  const UString wrappedExt = ai.GetWrappedExt();
  if (wrappedExt.IsEmpty())
    return -1;
  UInt32 numItems = 0;
  if (arc.Archive->GetNumberOfItems(&numItems) != S_OK || numItems != 1)
    return -1;
  UString ext(wrappedExt);
  if (ext.IsPrefixedBy(L"."))
    ext.DeleteFrontal(1);

  const int dotPos = arc.DefaultName.ReverseFind_Dot();
  if (dotPos < 0)
    return -1;
  if (!ext.IsEqualTo_NoCase(arc.DefaultName.Ptr((unsigned)(dotPos + 1))))
    return -1;
  FOR_VECTOR (i, codecs->Formats)
    if (codecs->Formats[i].FindExtension(ext) >= 0)
    return (int)i;
  return -1;
}


HRESULT TryChainedExtract(
    CCodecs *codecs,
    const CArchiveLink &arcLink,
    UInt64 packSize,
    UInt64 completedBeforeArc,
    bool multi,
    const NWildcard::CCensorNode &wildcardCensor,
    const CExtractOptions &options,
    bool calcCrc,
    IExtractCallbackUI *callback,
    IFolderArchiveExtractCallback *callbackFAE,
    CArchiveExtractCallback *ecs,
    UString &errorMessage)
{
  const CArc &arc = arcLink.Arcs.Back();
  const int innerFormatIndex = FindChainedFormatIndex(codecs, arc, options);
  if (innerFormatIndex < 0)
    return S_FALSE;

  CStreamBinder binder;
  RINOK(binder.Create_ReInit())

  CMyComPtr<ISequentialInStream> binderInStream;
  CMyComPtr<ISequentialOutStream> binderOutStream;
  binder.CreateStreams2(binderInStream, binderOutStream);

  CMyComPtr2_Create<IArchiveExtractCallback, CChainedStreamExtractCallback> outerExtractCallback;
  outerExtractCallback->Init(callbackFAE, binderOutStream, multi, completedBeforeArc);
  binderOutStream.Release();

  CChainedStreamExtractThread outerExtractThread;
  outerExtractThread.Arc = &arc;
  outerExtractThread.Callback = outerExtractCallback;
  RINOK(HRESULT_FROM_WIN32(outerExtractThread.Create()))
  RINOK(HRESULT_FROM_WIN32(outerExtractThread.Start()))

  HRESULT result = S_OK;

  {
    CArchiveLink innerArcLink;
    CObjectVector<COpenType> innerTypes;
    COpenType innerType;
    innerType.FormatIndex = innerFormatIndex;
    innerTypes.Add(innerType);
    CIntVector excludedFormats;

    COpenOptions op;
    #ifndef Z7_SFX
    op.props = &options.Properties;
    #endif
    op.codecs = codecs;
    op.types = &innerTypes;
    op.excludedFormats = &excludedFormats;
    op.seqStream = binderInStream;
    op.filePath = arc.DefaultName;

    result = innerArcLink.Open(op);
    if (result == S_OK)
    {
      UInt64 innerProcessed = 0;
      ecs->DisableProgress();
      result = DecompressArchive(
          codecs,
          innerArcLink,
          packSize,
          wildcardCensor,
          options,
          calcCrc,
          callback,
          callbackFAE,
          ecs,
          errorMessage,
          innerProcessed,
          true);
    }
    innerArcLink.Release();
  }

  if (result == S_OK)
  {
    const HRESULT drainResult = DrainChainedStream(binderInStream);
    if (drainResult != S_OK)
      result = drainResult;
  }

  binderInStream.Release();

  RINOK(HRESULT_FROM_WIN32(outerExtractThread.WaitExecuteFinish()))

  const HRESULT outerResult = outerExtractThread.Result;

  if (outerResult != S_OK && outerResult != k_My_HRESULT_WritingWasCut)
    return outerResult;
  if (result != S_OK)
    return result;

  return CheckOuterStreamResult(outerExtractCallback->OperationResult, errorMessage);
}
