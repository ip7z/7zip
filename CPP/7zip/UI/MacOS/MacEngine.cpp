// MacEngine.cpp

#include "StdAfx.h"

#include <string.h>

#include "../../../../C/7zVersion.h"

// GUIDs of interfaces are defined in this file
#include "../../../Common/MyInitGuid.h"

#include "../../../Common/IntToString.h"
#include "../../../Common/Lang.h"
#include "../../../Common/MyCom.h"
#include "../../../Common/MyException.h"
#include "../../../Common/StringConvert.h"
#include "../../../Common/UTFConvert.h"

#include "../../../Windows/ErrorMsg.h"
#include "../../../Windows/FileDir.h"
#include "../../../Windows/FileName.h"
#include "../../../Windows/PropVariant.h"
#include "../../../Windows/PropVariantConv.h"
#include "../../../Windows/TimeUtils.h"

#include "../../IPassword.h"

#include "../Common/ArchiveCommandLine.h"
#include "../Common/ArchiveExtractCallback.h"
#include "../Common/ArchiveOpenCallback.h"
#include "../Common/Extract.h"
#include "../Common/LoadCodecs.h"
#include "../Common/OpenArchive.h"
#include "../Common/PropIDUtils.h"
#include "../Common/Update.h"

#include "MacEngine.h"

using namespace NWindows;
using namespace NFile;
using namespace NMacEngine;

// these string IDs are same as in Windows version (resource.h files)
#define IDS_UPDATE_NOT_SUPPORTED                3004
#define IDS_CANT_OPEN_ARCHIVE                   3005
#define IDS_CANT_OPEN_ENCRYPTED_ARCHIVE         3006
#define IDS_CANT_OPEN_AS_TYPE                   3017
#define IDS_IS_OPEN_AS_TYPE                     3018
#define IDS_IS_OPEN_WITH_OFFSET                 3019
#define IDS_UNSUPPORTED_ARCHIVE_TYPE            3007
#define IDS_EXTRACT_MESSAGE_UNSUPPORTED_METHOD  3700
#define IDS_EXTRACT_MESSAGE_DATA_ERROR          3701
#define IDS_EXTRACT_MESSAGE_CRC_ERROR           3702
#define IDS_EXTRACT_MESSAGE_DATA_ERROR_ENCRYPTED 3703
#define IDS_EXTRACT_MESSAGE_CRC_ERROR_ENCRYPTED 3704
#define IDS_EXTRACT_MSG_WRONG_PSW_GUESS         3710
#define IDS_EXTRACT_MSG_UNSUPPORTED_METHOD      3721
#define IDS_EXTRACT_MSG_DATA_ERROR              3722
#define IDS_EXTRACT_MSG_CRC_ERROR               3723
#define IDS_EXTRACT_MSG_UNAVAILABLE_DATA        3724
#define IDS_EXTRACT_MSG_UEXPECTED_END           3725
#define IDS_EXTRACT_MSG_DATA_AFTER_END          3726
#define IDS_EXTRACT_MSG_IS_NOT_ARC              3727
#define IDS_EXTRACT_MSG_HEADERS_ERROR           3728
#define IDS_EXTRACT_MSG_WRONG_PSW_CLAIM         3729
#define IDS_OPEN_MSG_UNAVAILABLE_START          3763
#define IDS_OPEN_MSG_UNCONFIRMED_START          3764
#define IDS_OPEN_MSG_UNSUPPORTED_FEATURE        3768
#define IDS_PROP_ID_BASE                        1000


static CCodecs *g_Codecs;
static CMyComPtr<IUnknown> g_CodecsRef;

static CRecordVector<UInt32> g_LangIDs;
static CObjectVector<AString> g_LangStrings;

struct CFormatInfoA
{
  AString Name;
  AString Exts;
  bool CanUpdate;
  bool KeepName;
};

static CObjectVector<CFormatInfoA> g_Formats;


static AString ToUtf8(const UString &s)
{
  AString a;
  ConvertUnicodeToUTF8(s, a);
  return a;
}

static UString FromUtf8(const char *s)
{
  UString u;
  if (s)
    ConvertUTF8ToUnicode(AString(s), u);
  return u;
}

static Int64 FileTimeToUnix(const FILETIME &ft)
{
  return NTime::FileTime_To_UnixTime64(ft);
}


// ---------- Lang ----------

// Windows lang strings can contain '&' for keyboard accelerators: we remove them
static UString RemoveAccelerators(const wchar_t *s)
{
  UString res;
  for (;;)
  {
    wchar_t c = *s++;
    if (c == 0 || c == '\t')
      break;
    if (c == '&')
    {
      c = *s;
      if (c == 0)
        break;
      s++;
    }
    res += c;
  }
  return res;
}

static int FindLangIndex(UInt32 id)
{
  FOR_VECTOR (i, g_LangIDs)
    if (g_LangIDs[i] == id)
      return (int)i;
  return -1;
}

static UString LangStringW(UInt32 id, const char *defaultString)
{
  const int index = FindLangIndex(id);
  if (index >= 0)
  {
    UString u;
    ConvertUTF8ToUnicode(g_LangStrings[(unsigned)index], u);
    return u;
  }
  return UString(defaultString);
}

// replaces "{0}" by param
static UString MyFormat(UInt32 id, const char *defaultString, const UString &param)
{
  UString s = LangStringW(id, defaultString);
  s.Replace(L"{0}", param);
  return s;
}

const char *NMacEngine::LangString(uint32_t id, const char *defaultString)
{
  const int index = FindLangIndex(id);
  if (index >= 0)
    return g_LangStrings[(unsigned)index].Ptr();
  return defaultString;
}


static void LoadLang(const char *langFilePath)
{
  g_LangIDs.Clear();
  g_LangStrings.Clear();
  if (!langFilePath || langFilePath[0] == 0)
    return;
  CLang lang;
  if (!lang.Open(us2fs(FromUtf8(langFilePath)), "7-Zip"))
    return;
  FOR_VECTOR (i, lang._ids)
  {
    g_LangIDs.Add(lang._ids[i]);
    g_LangStrings.Add(ToUtf8(RemoveAccelerators(lang.Get_by_index(i))));
  }
}


// ---------- Init ----------

bool NMacEngine::Init(const char *langFilePath)
{
  LoadLang(langFilePath);
  if (g_Codecs)
    return true;

  CCodecs *codecs = new CCodecs;
  g_CodecsRef = codecs;
  if (codecs->Load() != S_OK)
    return false;
  Codecs_AddHashArcHandler(codecs);
  g_Codecs = codecs;

  FOR_VECTOR (i, codecs->Formats)
  {
    const CArcInfoEx &ai = codecs->Formats[i];
    CFormatInfoA &f = g_Formats.AddNew();
    f.Name = ToUtf8(ai.Name);
    UString exts;
    FOR_VECTOR (k, ai.Exts)
    {
      exts.Add_Space_if_NotEmpty();
      exts += ai.Exts[k].Ext;
    }
    f.Exts = ToUtf8(exts);
    f.CanUpdate = ai.UpdateEnabled;
    f.KeepName = ai.Flags_KeepName();
  }
  return true;
}

const char *NMacEngine::GetVersion() { return MY_VERSION; }
const char *NMacEngine::GetCopyright() { return MY_COPYRIGHT; }
const char *NMacEngine::GetDate() { return MY_DATE; }

unsigned NMacEngine::GetNumFormats()
{
  return g_Formats.Size();
}

void NMacEngine::GetFormatInfo(unsigned index, CFormatInfo &info)
{
  const CFormatInfoA &f = g_Formats[index];
  info.Name = f.Name.Ptr();
  info.Exts = f.Exts.Ptr();
  info.CanUpdate = f.CanUpdate;
  info.KeepName = f.KeepName;
}

int NMacEngine::FindFormatForExtension(const char *ext)
{
  if (!g_Codecs)
    return -1;
  return g_Codecs->FindFormatForExtension(FromUtf8(ext));
}

bool NMacEngine::IsArchiveExtension(const char *ext)
{
  return FindFormatForExtension(ext) >= 0;
}


void CResult::Clear()
{
  HResult = 0;
  NumErrors = 0;
  NumWarnings = 0;
  NumFiles = 0;
  NumFolders = 0;
  UnpackSize = 0;
  ArcSize = 0;
  PasswordWasDefined = false;
  memset(Password, 0, sizeof(Password));
}

static AString g_ErrorMessage;

const char *NMacEngine::GetErrorMessage(int32_t hres)
{
  g_ErrorMessage = ToUtf8(NError::MyFormatMessage((HRESULT)hres));
  return g_ErrorMessage.Ptr();
}


// ---------- Messages ----------

static void AddNewLineString(UString &s, const UString &m)
{
  s += m;
  s.Add_LF();
}

static const UInt32 k_ErrorFlagsIds[] =
{
  IDS_EXTRACT_MSG_IS_NOT_ARC,
  IDS_EXTRACT_MSG_HEADERS_ERROR,
  IDS_EXTRACT_MSG_HEADERS_ERROR,
  IDS_OPEN_MSG_UNAVAILABLE_START,
  IDS_OPEN_MSG_UNCONFIRMED_START,
  IDS_EXTRACT_MSG_UEXPECTED_END,
  IDS_EXTRACT_MSG_DATA_AFTER_END,
  IDS_EXTRACT_MSG_UNSUPPORTED_METHOD,
  IDS_OPEN_MSG_UNSUPPORTED_FEATURE,
  IDS_EXTRACT_MSG_DATA_ERROR,
  IDS_EXTRACT_MSG_CRC_ERROR
};

static const char * const k_ErrorFlagsMessages[] =
{
    "Is not archive"
  , "Headers Error"
  , "Headers Error"
  , "Unavailable start of archive"
  , "Unconfirmed start of archive"
  , "Unexpected end of data"
  , "There are some data after the end of the payload data"
  , "Unsupported compression method"
  , "Unsupported feature"
  , "Data error"
  , "CRC failed"
};

static void ErrorFlags_To_String(UString &s, UInt32 errorFlags)
{
  for (unsigned i = 0; i < Z7_ARRAY_SIZE(k_ErrorFlagsIds); i++)
  {
    const UInt32 f = (UInt32)1 << i;
    if ((errorFlags & f) == 0)
      continue;
    UString m = LangStringW(k_ErrorFlagsIds[i], k_ErrorFlagsMessages[i]);
    if (f == kpv_ErrorFlags_EncryptedHeadersError)
    {
      m += " : ";
      m += LangStringW(IDS_EXTRACT_MSG_WRONG_PSW_GUESS, "Wrong password?");
    }
    AddNewLineString(s, m);
    errorFlags &= ~f;
  }
  if (errorFlags != 0)
  {
    char sz[16];
    sz[0] = '0';
    sz[1] = 'x';
    ConvertUInt32ToHex(errorFlags, sz + 2);
    AddNewLineString(s, UString(sz));
  }
}

static void ErrorInfo_Print(UString &s, const CArcErrorInfo &er)
{
  const UInt32 errorFlags = er.GetErrorFlags();
  const UInt32 warningFlags = er.GetWarningFlags();
  if (errorFlags != 0)
    ErrorFlags_To_String(s, errorFlags);
  if (!er.ErrorMessage.IsEmpty())
    AddNewLineString(s, er.ErrorMessage);
  if (warningFlags != 0)
  {
    s += "Warnings:";
    s.Add_LF();
    ErrorFlags_To_String(s, warningFlags);
  }
  if (!er.WarningMessage.IsEmpty())
    AddNewLineString(s, er.WarningMessage);
}

static UString GetBracedType(const wchar_t *type)
{
  UString s ('[');
  s += type;
  s.Add_Char(']');
  return s;
}

// it's similar to OpenResult_GUI() from FileManager/ExtractCallback.cpp
static void OpenResult_Mac(UString &s, const CCodecs *codecs, const CArchiveLink &arcLink,
    const wchar_t *name, HRESULT result)
{
  FOR_VECTOR (level, arcLink.Arcs)
  {
    const CArc &arc = arcLink.Arcs[level];
    const CArcErrorInfo &er = arc.ErrorInfo;
    if (!er.IsThereErrorOrWarning() && er.ErrorFormatIndex < 0)
      continue;
    if (s.IsEmpty())
      AddNewLineString(s, name);
    if (level != 0)
      AddNewLineString(s, arc.Path);
    ErrorInfo_Print(s, er);
    if (er.ErrorFormatIndex >= 0)
    {
      if (arc.FormatIndex == er.ErrorFormatIndex)
        AddNewLineString(s, LangStringW(IDS_IS_OPEN_WITH_OFFSET, "The archive is open with offset"));
      else
      {
        AddNewLineString(s, MyFormat(IDS_CANT_OPEN_AS_TYPE, "Cannot open the file as {0} archive",
            GetBracedType(codecs->GetFormatNamePtr(er.ErrorFormatIndex))));
        AddNewLineString(s, MyFormat(IDS_IS_OPEN_AS_TYPE, "The file is open as {0} archive",
            GetBracedType(codecs->GetFormatNamePtr(arc.FormatIndex))));
      }
    }
  }

  if (arcLink.NonOpen_ErrorInfo.ErrorFormatIndex >= 0 || result != S_OK)
  {
    AddNewLineString(s, name);
    if (!arcLink.Arcs.IsEmpty())
      AddNewLineString(s, arcLink.NonOpen_ArcPath);
    if (arcLink.NonOpen_ErrorInfo.ErrorFormatIndex >= 0 || result == S_FALSE)
    {
      UString s2;
      if (arcLink.PasswordWasAsked)
        s2 = MyFormat(IDS_CANT_OPEN_ENCRYPTED_ARCHIVE, "Cannot open encrypted archive '{0}'. Wrong password?", UString());
      else if (arcLink.NonOpen_ErrorInfo.ErrorFormatIndex >= 0)
        s2 = MyFormat(IDS_CANT_OPEN_AS_TYPE, "Cannot open the file as {0} archive",
            GetBracedType(codecs->GetFormatNamePtr(arcLink.NonOpen_ErrorInfo.ErrorFormatIndex)));
      else
        s2 = MyFormat(IDS_CANT_OPEN_ARCHIVE, "Cannot open file '{0}' as archive", UString());
      s2.Replace(L" ''", L"");
      s2.Replace(L"''", L"");
      s += s2;
    }
    else
      s += NError::MyFormatMessage(result);
    s.Add_LF();
    ErrorInfo_Print(s, arcLink.NonOpen_ErrorInfo);
  }

  if (!s.IsEmpty() && s.Back() == '\n')
    s.DeleteBack();
}


// it's similar to SetExtractErrorMessage() from FileManager/ExtractCallback.cpp
static void GetExtractErrorMessage(Int32 opRes, Int32 encrypted, const wchar_t *fileName, UString &s)
{
  s.Empty();
  if (opRes == NArchive::NExtract::NOperationResult::kOK)
    return;

  const UString name (fileName ? fileName : L"");
  UInt32 id = 0;
  const char *msg = NULL;
  bool withName = false;

  switch (opRes)
  {
    case NArchive::NExtract::NOperationResult::kUnsupportedMethod:
      id = IDS_EXTRACT_MESSAGE_UNSUPPORTED_METHOD; msg = "Unsupported compression method for '{0}'."; withName = true;
      break;
    case NArchive::NExtract::NOperationResult::kDataError:
      withName = true;
      if (encrypted) { id = IDS_EXTRACT_MESSAGE_DATA_ERROR_ENCRYPTED; msg = "Data error in encrypted file '{0}'. Wrong password?"; }
      else           { id = IDS_EXTRACT_MESSAGE_DATA_ERROR; msg = "Data error in '{0}'. File is broken"; }
      break;
    case NArchive::NExtract::NOperationResult::kCRCError:
      withName = true;
      if (encrypted) { id = IDS_EXTRACT_MESSAGE_CRC_ERROR_ENCRYPTED; msg = "CRC failed in encrypted file '{0}'. Wrong password?"; }
      else           { id = IDS_EXTRACT_MESSAGE_CRC_ERROR; msg = "CRC failed in '{0}'. File is broken."; }
      break;
    case NArchive::NExtract::NOperationResult::kUnavailable:
      id = IDS_EXTRACT_MSG_UNAVAILABLE_DATA; msg = "Unavailable data"; break;
    case NArchive::NExtract::NOperationResult::kUnexpectedEnd:
      id = IDS_EXTRACT_MSG_UEXPECTED_END; msg = "Unexpected end of data"; break;
    case NArchive::NExtract::NOperationResult::kDataAfterEnd:
      id = IDS_EXTRACT_MSG_DATA_AFTER_END; msg = "There are some data after the end of the payload data"; break;
    case NArchive::NExtract::NOperationResult::kIsNotArc:
      id = IDS_EXTRACT_MSG_IS_NOT_ARC; msg = "Is not archive"; break;
    case NArchive::NExtract::NOperationResult::kHeadersError:
      id = IDS_EXTRACT_MSG_HEADERS_ERROR; msg = "Headers Error"; break;
    case NArchive::NExtract::NOperationResult::kWrongPassword:
      id = IDS_EXTRACT_MSG_WRONG_PSW_CLAIM; msg = "Wrong password"; break;
    default:
      break;
  }

  if (msg)
  {
    if (withName)
    {
      s = MyFormat(id, msg, name);
      return;
    }
    s = LangStringW(id, msg);
  }
  else
  {
    s = "Error #";
    s.Add_UInt32((UInt32)opRes);
  }
  if (encrypted && opRes != NArchive::NExtract::NOperationResult::kWrongPassword)
  {
    s += " : ";
    s += LangStringW(IDS_EXTRACT_MSG_WRONG_PSW_GUESS, "Wrong password?");
  }
  if (!name.IsEmpty())
  {
    s += " : ";
    s += name;
  }
}


// ---------- Callbacks ----------

class CCallbackBase
{
public:
  IUserCallback *UI;
  CResult *Res;
  bool PasswordIsDefined;
  bool PasswordWasAsked;
  bool AskPasswordAllowed;
  UString Password;

  CCallbackBase():
      UI(NULL),
      Res(NULL),
      PasswordIsDefined(false),
      PasswordWasAsked(false),
      AskPasswordAllowed(true)
      {}
  virtual ~CCallbackBase();

  void InitBase(IUserCallback *ui, CResult *res)
  {
    UI = ui;
    Res = res;
  }

  HRESULT CheckBreak2()
  {
    return UI->CheckBreak() ? E_ABORT : S_OK;
  }

  void SetCurrent(EOperation op, const wchar_t *name)
  {
    UI->SetCurrent(op, name ? ToUtf8(UString(name)).Ptr() : "");
  }

  void AddError(const UString &s)
  {
    Res->NumErrors++;
    UI->AddMessage(ToUtf8(s).Ptr(), true);
  }

  void AddWarning(const UString &s)
  {
    Res->NumWarnings++;
    UI->AddMessage(ToUtf8(s).Ptr(), false);
  }

  void AddError_Code_Name(HRESULT code, const UString &name)
  {
    UString s = name;
    s += " : ";
    s += NError::MyFormatMessage(code);
    AddError(s);
  }

  HRESULT AskPassword_IfRequired()
  {
    if (PasswordIsDefined)
      return S_OK;
    PasswordWasAsked = true;
    char buf[1024];
    buf[0] = 0;
    const bool ok = UI->AskPassword(buf, sizeof(buf));
    buf[sizeof(buf) - 1] = 0;
    if (!ok)
    {
      memset(buf, 0, sizeof(buf));
      return E_ABORT;
    }
    SetPassword_Utf8(buf);
    memset(buf, 0, sizeof(buf));
    return S_OK;
  }

  void SetPassword_Utf8(const char *s)
  {
    Password = FromUtf8(s);
    PasswordIsDefined = true;
    if (Res)
    {
      Res->PasswordWasDefined = true;
      const size_t len = strlen(s);
      if (len < sizeof(Res->Password))
        memcpy(Res->Password, s, len + 1);
    }
  }

  HRESULT GetPassword_Bstr(BSTR *password)
  {
    *password = NULL;
    RINOK(AskPassword_IfRequired())
    return StringToBstr(Password, password);
  }
};

CCallbackBase::~CCallbackBase() {}


class COpenCallbackMac:
  public IOpenCallbackUI,
  public CCallbackBase
{
public:
  Z7_IFACE_IMP(IOpenCallbackUI)
};

HRESULT COpenCallbackMac::Open_CheckBreak()
{
  return CheckBreak2();
}

HRESULT COpenCallbackMac::Open_SetTotal(const UInt64 * /* numFiles */, const UInt64 *numBytes)
{
  if (numBytes)
    UI->SetTotal(*numBytes);
  return CheckBreak2();
}

HRESULT COpenCallbackMac::Open_SetCompleted(const UInt64 * /* numFiles */, const UInt64 *numBytes)
{
  if (numBytes)
    UI->SetCompleted(*numBytes);
  return CheckBreak2();
}

HRESULT COpenCallbackMac::Open_Finished()
{
  return S_OK;
}

HRESULT COpenCallbackMac::Open_CryptoGetTextPassword(BSTR *password)
{
  return GetPassword_Bstr(password);
}



class CExtractCallbackMac Z7_final:
  public IFolderArchiveExtractCallback,
  public IExtractCallbackUI,
  public IFolderArchiveExtractCallback2,
  public ICryptoGetTextPassword,
  public COpenCallbackMac,
  public CMyUnknownImp
{
  Z7_COM_QI_BEGIN2(IFolderArchiveExtractCallback)
  Z7_COM_QI_ENTRY(IFolderArchiveExtractCallback2)
  Z7_COM_QI_ENTRY(ICryptoGetTextPassword)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE

  Z7_IFACE_COM7_IMP(IProgress)
  Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback)
  Z7_IFACE_IMP(IExtractCallbackUI)
  Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback2)
  Z7_IFACE_COM7_IMP(ICryptoGetTextPassword)

  UString _currentName;
  bool _testMode;
public:
  UInt64 NumFiles;

  CExtractCallbackMac(): _testMode(false), NumFiles(0) {}
  void Init(IUserCallback *ui, CResult *res, bool testMode)
  {
    InitBase(ui, res);
    _testMode = testMode;
    NumFiles = 0;
  }
};

Z7_COM7F_IMF(CExtractCallbackMac::SetTotal(UInt64 total))
{
  UI->SetTotal(total);
  return CheckBreak2();
}

Z7_COM7F_IMF(CExtractCallbackMac::SetCompleted(const UInt64 *completeValue))
{
  if (completeValue)
    UI->SetCompleted(*completeValue);
  return CheckBreak2();
}

static void FillFileInfo(CFileInfo &fi, const FILETIME *ft, const UInt64 *size)
{
  fi.SizeDefined = (size != NULL);
  fi.Size = size ? *size : 0;
  fi.TimeDefined = (ft != NULL);
  fi.UnixTime = ft ? FileTimeToUnix(*ft) : 0;
}

Z7_COM7F_IMF(CExtractCallbackMac::AskOverwrite(
    const wchar_t *existName, const FILETIME *existTime, const UInt64 *existSize,
    const wchar_t *newName, const FILETIME *newTime, const UInt64 *newSize,
    Int32 *answer))
{
  CFileInfo existInfo, newInfo;
  FillFileInfo(existInfo, existTime, existSize);
  FillFileInfo(newInfo, newTime, newSize);
  const EOverwriteAnswer a = UI->AskOverwrite(
      ToUtf8(UString(existName)).Ptr(), existInfo,
      ToUtf8(UString(newName)).Ptr(), newInfo);
  *answer = (Int32)a;
  if (a == kOverwrite_Cancel)
    return E_ABORT;
  return S_OK;
}

Z7_COM7F_IMF(CExtractCallbackMac::PrepareOperation(const wchar_t *name, Int32 /* isFolder */, Int32 askExtractMode, const UInt64 * /* position */))
{
  _currentName = name;
  EOperation op;
  switch (askExtractMode)
  {
    case NArchive::NExtract::NAskMode::kExtract: op = kOp_Extracting; break;
    case NArchive::NExtract::NAskMode::kTest:    op = kOp_Testing; break;
    case NArchive::NExtract::NAskMode::kSkip:    op = kOp_Skipping; break;
    default: op = kOp_None;
  }
  SetCurrent(op, name);
  return CheckBreak2();
}

Z7_COM7F_IMF(CExtractCallbackMac::MessageError(const wchar_t *message))
{
  AddError(UString(message));
  return CheckBreak2();
}

Z7_COM7F_IMF(CExtractCallbackMac::SetOperationResult(Int32 opRes, Int32 encrypted))
{
  if (opRes != NArchive::NExtract::NOperationResult::kOK)
  {
    UString s;
    GetExtractErrorMessage(opRes, encrypted, _currentName, s);
    AddError(s);
  }
  NumFiles++;
  UI->SetNumFilesCompleted(NumFiles);
  return CheckBreak2();
}

Z7_COM7F_IMF(CExtractCallbackMac::ReportExtractResult(Int32 opRes, Int32 encrypted, const wchar_t *name))
{
  if (opRes != NArchive::NExtract::NOperationResult::kOK)
  {
    UString s;
    GetExtractErrorMessage(opRes, encrypted, name, s);
    AddError(s);
  }
  return S_OK;
}

Z7_COM7F_IMF(CExtractCallbackMac::CryptoGetTextPassword(BSTR *password))
{
  return GetPassword_Bstr(password);
}

HRESULT CExtractCallbackMac::BeforeOpen(const wchar_t *name, bool /* testMode */)
{
  SetCurrent(kOp_Opening, name);
  return CheckBreak2();
}

HRESULT CExtractCallbackMac::OpenResult(const CCodecs *codecs, const CArchiveLink &arcLink, const wchar_t *name, HRESULT result)
{
  UString s;
  OpenResult_Mac(s, codecs, arcLink, name, result);
  if (!s.IsEmpty())
  {
    if (result == S_OK)
      AddWarning(s);
    else
      AddError(s);
  }
  return S_OK;
}

HRESULT CExtractCallbackMac::ThereAreNoFiles()
{
  return S_OK;
}

HRESULT CExtractCallbackMac::ExtractResult(HRESULT result)
{
  if (result == S_OK || result == E_ABORT)
    return result;
  AddError(NError::MyFormatMessage(result));
  return S_OK;
}

HRESULT CExtractCallbackMac::SetPassword(const UString &password)
{
  Password = password;
  PasswordIsDefined = true;
  return S_OK;
}



class CUpdateCallbackMac Z7_final:
  public IUpdateCallbackUI2,
  public COpenCallbackMac
{
  Z7_IFACE_IMP(IUpdateCallbackUI)
  Z7_IFACE_IMP(IDirItemsCallback)
  Z7_IFACE_IMP(IUpdateCallbackUI2)
public:
  UInt64 NumFiles;

  CUpdateCallbackMac(): NumFiles(0) {}
};

HRESULT CUpdateCallbackMac::OpenResult(
    const CCodecs *codecs, const CArchiveLink &arcLink, const wchar_t *name, HRESULT result)
{
  UString s;
  OpenResult_Mac(s, codecs, arcLink, name, result);
  if (!s.IsEmpty())
  {
    if (result == S_OK)
      AddWarning(s);
    else
      AddError(s);
  }
  return S_OK;
}

HRESULT CUpdateCallbackMac::StartScanning()
{
  SetCurrent(kOp_Scanning, NULL);
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::ScanError(const FString &path, DWORD systemError)
{
  AddError_Code_Name(HRESULT_FROM_WIN32(systemError), fs2us(path));
  return S_OK;
}

HRESULT CUpdateCallbackMac::ScanProgress(const CDirItemsStat &st, const FString &path, bool /* isDir */)
{
  UI->SetNumFiles(st.NumFiles + st.NumAltStreams);
  UI->SetTotal(st.GetTotalBytes());
  UI->SetCurrent(kOp_Scanning, ToUtf8(fs2us(path)).Ptr());
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::FinishScanning(const CDirItemsStat &st)
{
  UI->SetNumFiles(st.NumFiles + st.NumAltStreams);
  UI->SetTotal(st.GetTotalBytes());
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::StartOpenArchive(const wchar_t *name)
{
  SetCurrent(kOp_Opening, name);
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::StartArchive(const wchar_t * /* name */, bool /* updating */)
{
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::FinishArchive(const CFinishArchiveStat &st)
{
  Res->ArcSize = st.OutArcFileSize;
  return S_OK;
}

HRESULT CUpdateCallbackMac::DeletingAfterArchiving(const FString &path, bool /* isDir */)
{
  UI->SetCurrent(kOp_Removing, ToUtf8(fs2us(path)).Ptr());
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::FinishDeletingAfterArchiving()
{
  return S_OK;
}

HRESULT CUpdateCallbackMac::MoveArc_Start(const wchar_t * /* srcTempPath */, const wchar_t *destFinalPath, UInt64 size, Int32 /* updateMode */)
{
  SetCurrent(kOp_Moving, destFinalPath);
  UI->SetTotal(size);
  UI->SetCompleted(0);
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::MoveArc_Progress(UInt64 total, UInt64 current)
{
  UI->SetTotal(total);
  UI->SetCompleted(current);
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::MoveArc_Finish()
{
  return S_OK;
}

HRESULT CUpdateCallbackMac::WriteSfx(const wchar_t * /* name */, UInt64 /* size */)
{
  return S_OK;
}

HRESULT CUpdateCallbackMac::SetTotal(UInt64 size)
{
  UI->SetTotal(size);
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::SetCompleted(const UInt64 *completeValue)
{
  if (completeValue)
    UI->SetCompleted(*completeValue);
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::SetRatioInfo(const UInt64 *inSize, const UInt64 *outSize)
{
  if (inSize && outSize)
    UI->SetRatioInfo(*inSize, *outSize);
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::CheckBreak()
{
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::SetNumItems(const CArcToDoStat &stat)
{
  UI->SetNumFiles(stat.Get_NumDataItems_Total());
  return S_OK;
}

static EOperation UpdateOpToOperation(UInt32 op)
{
  if (op <= NUpdateNotifyOp::kHeader)
    return (EOperation)((unsigned)kOp_Add + op);
  return kOp_None;
}

HRESULT CUpdateCallbackMac::GetStream(const wchar_t *name, bool /* isDir */, bool /* isAnti */, UInt32 mode)
{
  SetCurrent(UpdateOpToOperation(mode), name);
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::OpenFileError(const FString &path, DWORD systemError)
{
  AddError_Code_Name(HRESULT_FROM_WIN32(systemError), fs2us(path));
  return S_FALSE;
}

HRESULT CUpdateCallbackMac::ReadingFileError(const FString &path, DWORD systemError)
{
  AddError_Code_Name(HRESULT_FROM_WIN32(systemError), fs2us(path));
  return S_OK;
}

HRESULT CUpdateCallbackMac::SetOperationResult(Int32 /* opRes */)
{
  NumFiles++;
  UI->SetNumFilesCompleted(NumFiles);
  return S_OK;
}

HRESULT CUpdateCallbackMac::ReportExtractResult(Int32 opRes, Int32 isEncrypted, const wchar_t *name)
{
  if (opRes != NArchive::NExtract::NOperationResult::kOK)
  {
    UString s;
    GetExtractErrorMessage(opRes, isEncrypted, name, s);
    AddError(s);
  }
  return S_OK;
}

HRESULT CUpdateCallbackMac::ReportUpdateOperation(UInt32 op, const wchar_t *name, bool /* isDir */)
{
  SetCurrent(UpdateOpToOperation(op), name);
  return CheckBreak2();
}

HRESULT CUpdateCallbackMac::CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *password)
{
  *password = NULL;
  if (!PasswordIsDefined && AskPasswordAllowed)
  {
    RINOK(AskPassword_IfRequired())
  }
  if (passwordIsDefined)
    *passwordIsDefined = BoolToInt(PasswordIsDefined);
  return StringToBstr(Password, password);
}

HRESULT CUpdateCallbackMac::CryptoGetTextPassword(BSTR *password)
{
  *password = NULL;
  RINOK(AskPassword_IfRequired())
  return StringToBstr(Password, password);
}

HRESULT CUpdateCallbackMac::ShowDeleteFile(const wchar_t *name, bool /* isDir */)
{
  SetCurrent(kOp_Delete, name);
  return CheckBreak2();
}



// ---------- RunCommand ----------

static void AddErrorInfo(CCallbackBase &cb, const CUpdateErrorInfo &ei)
{
  if (!ei.ThereIsError())
    return;
  UString s;
  if (!ei.Message.IsEmpty())
  {
    s += GetUnicodeString(ei.Message);
    s.Add_LF();
  }
  FOR_VECTOR (i, ei.FileNames)
  {
    s += fs2us(ei.FileNames[i]);
    s.Add_LF();
  }
  if (ei.SystemError != 0)
    s += NError::MyFormatMessage(ei.SystemError);
  if (!s.IsEmpty() && s.Back() == '\n')
    s.DeleteBack();
  cb.AddError(s);
}

static void RunCommand2(const UStringVector &commandStrings, IUserCallback *ui, CResult &result)
{
  CArcCmdLineOptions options;
  CArcCmdLineParser parser;

  parser.Parse1(commandStrings, options);
  parser.Parse2(options);

  CCallbackBase errorCallback;
  errorCallback.InitBase(ui, &result);

  CObjectVector<COpenType> types;
  if (!ParseOpenTypes(*g_Codecs, options.ArcType, types))
  {
    errorCallback.AddError(LangStringW(IDS_UNSUPPORTED_ARCHIVE_TYPE, "Unsupported archive type"));
    result.HResult = E_FAIL;
    return;
  }

  CIntVector excludedFormats;
  FOR_VECTOR (k, options.ExcludedArcTypes)
  {
    CIntVector tempIndices;
    if (!g_Codecs->FindFormatForArchiveType(options.ExcludedArcTypes[k], tempIndices)
        || tempIndices.Size() != 1)
    {
      errorCallback.AddError(LangStringW(IDS_UNSUPPORTED_ARCHIVE_TYPE, "Unsupported archive type"));
      result.HResult = E_FAIL;
      return;
    }
    excludedFormats.AddToUniqueSorted(tempIndices[0]);
  }

  if (options.Command.IsFromExtractGroup())
  {
    UStringVector arcPathsSorted;
    UStringVector arcPathsFullSorted;
    {
      CDirItemsStat st;
      const HRESULT res = EnumerateDirItemsAndSort(
          options.arcCensor,
          NWildcard::k_RelatPath,
          UString(), // addPathPrefix
          arcPathsSorted,
          arcPathsFullSorted,
          st,
          NULL);
      if (res != S_OK)
      {
        result.HResult = res;
        return;
      }
    }

    CExtractCallbackMac *ecs = new CExtractCallbackMac;
    CMyComPtr<IFolderArchiveExtractCallback> extractCallback = ecs;

    ecs->Init(ui, &result, options.Command.IsTestCommand());
    ecs->PasswordIsDefined = options.PasswordEnabled;
    ecs->Password = options.Password;

    CExtractOptions eo;
    (CExtractOptionsBase &)eo = options.ExtractOptions;
    eo.StdInMode = options.StdInMode;
    eo.StdOutMode = options.StdOutMode;
    eo.YesToAll = options.YesToAll;
    eo.TestMode = options.Command.IsTestCommand();
    eo.Properties = options.Properties;

    UString errorMessage;
    CDecompressStat stat;
    stat.Clear();

    HRESULT res = Extract(
        g_Codecs,
        types,
        excludedFormats,
        arcPathsSorted,
        arcPathsFullSorted,
        options.Censor.Pairs.Front().Head,
        eo,
        ecs, ecs, ecs,
        NULL, // hash
        errorMessage, stat);

    if (!errorMessage.IsEmpty())
    {
      ecs->AddError(errorMessage);
      if (res == S_OK)
        res = E_FAIL;
    }
    result.HResult = res;
    result.NumFiles = stat.NumFiles;
    result.NumFolders = stat.NumFolders;
    result.UnpackSize = stat.UnpackSize;
    return;
  }

  if (options.Command.IsFromUpdateGroup())
  {
    CUpdateOptions &uo = options.UpdateOptions;

    CUpdateCallbackMac callback;
    callback.InitBase(ui, &result);
    callback.PasswordIsDefined = (options.PasswordEnabled && !options.Password.IsEmpty());
    callback.AskPasswordAllowed = (options.PasswordEnabled && options.Password.IsEmpty());
    callback.Password = options.Password;

    if (!uo.InitFormatIndex(g_Codecs, types, options.ArchiveName) ||
        !uo.SetArcPath(g_Codecs, options.ArchiveName))
    {
      callback.AddError(LangStringW(IDS_UPDATE_NOT_SUPPORTED, "Update operations are not supported for this archive."));
      result.HResult = E_FAIL;
      return;
    }

    CUpdateErrorInfo errorInfo;
    HRESULT res = UpdateArchive(g_Codecs,
        types,
        options.ArchiveName,
        options.Censor,
        uo,
        errorInfo, &callback, &callback, true);
    AddErrorInfo(callback, errorInfo);
    if (res == S_OK && errorInfo.ThereIsError())
      res = errorInfo.Get_HRESULT_Error();
    result.HResult = res;
    result.NumFiles = callback.NumFiles;
    return;
  }

  errorCallback.AddError(UString("Unsupported command"));
  result.HResult = E_NOTIMPL;
}


void NMacEngine::RunCommand(const char * const *args, unsigned numArgs, IUserCallback *ui, CResult &result)
{
  result.Clear();
  CCallbackBase errorCallback;
  errorCallback.InitBase(ui, &result);

  if (!g_Codecs)
  {
    result.HResult = E_FAIL;
    return;
  }

  try
  {
    UStringVector commandStrings;
    for (unsigned i = 0; i < numArgs; i++)
      commandStrings.Add(FromUtf8(args[i]));
    RunCommand2(commandStrings, ui, result);
  }
  catch(const CArcCmdLineException &e)
  {
    errorCallback.AddError(e);
    result.HResult = E_INVALIDARG;
  }
  catch(const CSystemException &e)
  {
    result.HResult = e.ErrorCode;
    if (e.ErrorCode != E_ABORT)
      errorCallback.AddError(NError::MyFormatMessage(e.ErrorCode));
  }
  catch(const UString &s)
  {
    errorCallback.AddError(s);
    result.HResult = E_FAIL;
  }
  catch(const AString &s)
  {
    errorCallback.AddError(GetUnicodeString(s));
    result.HResult = E_FAIL;
  }
  catch(const char *s)
  {
    errorCallback.AddError(UString(s));
    result.HResult = E_FAIL;
  }
  catch(...)
  {
    errorCallback.AddError(UString("Unknown error"));
    result.HResult = E_FAIL;
  }
}



// ---------- Archive browsing ----------

static const char * const kPropIdToName[] =
{
    "0"
  , "1"
  , "2"
  , "Path"
  , "Name"
  , "Extension"
  , "Folder"
  , "Size"
  , "Packed Size"
  , "Attributes"
  , "Created"
  , "Accessed"
  , "Modified"
  , "Solid"
  , "Commented"
  , "Encrypted"
  , "Split Before"
  , "Split After"
  , "Dictionary Size"
  , "CRC"
  , "Type"
  , "Anti"
  , "Method"
  , "Host OS"
  , "File System"
  , "User"
  , "Group"
  , "Block"
  , "Comment"
  , "Position"
  , "Path Prefix"
  , "Folders"
  , "Files"
  , "Version"
  , "Volume"
  , "Multivolume"
  , "Offset"
  , "Links"
  , "Blocks"
  , "Volumes"
  , "Time Type"
  , "64-bit"
  , "Big-endian"
  , "CPU"
  , "Physical Size"
  , "Headers Size"
  , "Checksum"
  , "Characteristics"
  , "Virtual Address"
  , "ID"
  , "Short Name"
  , "Creator Application"
  , "Sector Size"
  , "Mode"
  , "Symbolic Link"
  , "Error"
  , "Total Size"
  , "Free Space"
  , "Cluster Size"
  , "Label"
  , "Local Name"
  , "Provider"
  , "NT Security"
  , "Alternate Stream"
  , "Aux"
  , "Deleted"
  , "Tree"
  , "SHA-1"
  , "SHA-256"
  , "Error Type"
  , "Errors"
  , "Errors"
  , "Warnings"
  , "Warning"
  , "Streams"
  , "Alternate Streams"
  , "Alternate Streams Size"
  , "Virtual Size"
  , "Unpack Size"
  , "Total Physical Size"
  , "Volume Index"
  , "SubType"
  , "Short Comment"
  , "Code Page"
  , "Is not archive type"
  , "Physical Size can't be detected"
  , "Zeros Tail Is Allowed"
  , "Tail Size"
  , "Embedded Stub Size"
  , "Link"
  , "Hard Link"
  , "iNode"
  , "Stream ID"
  , "Read-only"
  , "Out Name"
  , "Copy Link"
  , "Archive File Name"
  , "Is Hash"
  , "Metadata Changed"
  , "User ID"
  , "Group ID"
  , "Device Major"
  , "Device Minor"
  , "Dev Major"
  , "Dev Minor"
};

static UString GetPropName(PROPID propID, const wchar_t *name)
{
  if (propID < Z7_ARRAY_SIZE(kPropIdToName))
    return LangStringW(IDS_PROP_ID_BASE + propID, kPropIdToName[propID]);
  if (name)
    return name;
  UString s ("?");
  s.Add_UInt32(propID);
  return s;
}

static void AddPropPair(CObjectVector<AString> &names, CObjectVector<AString> &values,
    const UString &name, const UString &value)
{
  names.Add(ToUtf8(name));
  values.Add(ToUtf8(value));
}

static void AddPropPair_Prop(CObjectVector<AString> &names, CObjectVector<AString> &values,
    PROPID propID, const wchar_t *name, const PROPVARIANT &prop)
{
  if (prop.vt == VT_EMPTY)
    return;
  UString s;
  ConvertPropertyToString2(s, prop, propID);
  if (s.IsEmpty())
    return;
  AddPropPair(names, values, GetPropName(propID, name), s);
}


class CArchiveMac Z7_final: public NMacEngine::IArchive
{
public:
  CArchiveLink ArcLink;
  CRecordVector<UInt32> ArcIndices; // index in archive for each item
  CObjectVector<AString> Paths;
  CObjectVector<AString> Methods;
  CRecordVector<CItemInfo> Items;

  CObjectVector<AString> PropNames;
  CObjectVector<AString> PropValues;

  CObjectVector<AString> ItemPropNames;
  CObjectVector<AString> ItemPropValues;
  CRecordVector<CPropPair> ItemProps;

  AString FormatName;
  bool _canUpdate;
  bool _isEncrypted;
  bool PasswordIsDefined;
  UString Password;
  AString PasswordA;

  CArchiveMac(): _canUpdate(false), _isEncrypted(false), PasswordIsDefined(false) {}

  HRESULT ReadItems();
  void ReadArcProps();

  unsigned GetNumItems() const Z7_override { return Items.Size(); }
  const CItemInfo &GetItem(unsigned index) const Z7_override { return Items[index]; }
  const char *GetFormatName() const Z7_override { return FormatName.Ptr(); }
  bool CanUpdate() const Z7_override { return _canUpdate; }
  bool IsEncrypted() const Z7_override { return _isEncrypted; }
  unsigned GetNumProps() const Z7_override { return PropNames.Size(); }
  CPropPair GetProp(unsigned index) const Z7_override
  {
    CPropPair p;
    p.Name = PropNames[index].Ptr();
    p.Value = PropValues[index].Ptr();
    return p;
  }
  unsigned GetItemProps(unsigned itemIndex, const CPropPair **props) Z7_override;
  void Extract(const uint32_t *indices, unsigned numIndices,
      const char *outDir, const char *prefix,
      EPathMode pathMode, EOverwriteMode overwriteMode,
      bool testMode,
      IUserCallback *callback, CResult &result) Z7_override;
  const char *GetPassword() const Z7_override { return PasswordA.Ptr(); }
  void SetPassword(const char *password) Z7_override
  {
    Password = FromUtf8(password);
    PasswordA = password;
    PasswordIsDefined = true;
  }
};


HRESULT CArchiveMac::ReadItems()
{
  const CArc &arc = ArcLink.Arcs.Back();
  IInArchive *archive = arc.Archive;
  UInt32 numItems = 0;
  RINOK(archive->GetNumberOfItems(&numItems))

  UString path;
  for (UInt32 i = 0; i < numItems; i++)
  {
    if (arc.Ask_Aux)
    {
      bool isAux;
      RINOK(Archive_IsItem_Aux(archive, i, isAux))
      if (isAux)
        continue;
    }
    if (arc.Ask_AltStream)
    {
      bool isAltStream;
      RINOK(Archive_IsItem_AltStream(archive, i, isAltStream))
      if (isAltStream)
        continue;
    }

    RINOK(arc.GetItem_Path2(i, path))

    CItemInfo item;
    memset(&item, 0, sizeof(item));
    {
      bool isDir;
      RINOK(Archive_IsItem_Dir(archive, i, isDir))
      item.IsDir = isDir;
    }
    {
      NCOM::CPropVariant prop;
      RINOK(archive->GetProperty(i, kpidSize, &prop))
      UInt64 v;
      if (ConvertPropVariantToUInt64(prop, v))
      {
        item.Size = v;
        item.SizeDefined = true;
      }
    }
    {
      NCOM::CPropVariant prop;
      RINOK(archive->GetProperty(i, kpidPackSize, &prop))
      UInt64 v;
      if (ConvertPropVariantToUInt64(prop, v))
      {
        item.PackSize = v;
        item.PackSizeDefined = true;
      }
    }
    {
      NCOM::CPropVariant prop;
      RINOK(archive->GetProperty(i, kpidMTime, &prop))
      if (prop.vt == VT_FILETIME)
      {
        item.MTime = FileTimeToUnix(prop.filetime);
        item.MTimeDefined = true;
      }
    }
    {
      NCOM::CPropVariant prop;
      RINOK(archive->GetProperty(i, kpidCRC, &prop))
      if (prop.vt == VT_UI4)
      {
        item.Crc = prop.ulVal;
        item.CrcDefined = true;
      }
    }
    {
      NCOM::CPropVariant prop;
      RINOK(archive->GetProperty(i, kpidAttrib, &prop))
      if (prop.vt == VT_UI4)
      {
        item.Attrib = prop.ulVal;
        item.AttribDefined = true;
      }
      else
      {
        NCOM::CPropVariant prop2;
        RINOK(archive->GetProperty(i, kpidPosixAttrib, &prop2))
        if (prop2.vt == VT_UI4)
        {
          item.Attrib = (prop2.ulVal << 16) | FILE_ATTRIBUTE_UNIX_EXTENSION;
          item.AttribDefined = true;
        }
      }
    }
    {
      NCOM::CPropVariant prop;
      RINOK(archive->GetProperty(i, kpidEncrypted, &prop))
      if (prop.vt == VT_BOOL && VARIANT_BOOLToBool(prop.boolVal))
      {
        item.Encrypted = true;
        _isEncrypted = true;
      }
    }
    {
      NCOM::CPropVariant prop;
      RINOK(archive->GetProperty(i, kpidMethod, &prop))
      if (prop.vt == VT_BSTR)
        Methods.Add(ToUtf8(UString(prop.bstrVal)));
      else
        Methods.Add(AString());
    }

    Paths.Add(ToUtf8(path));
    ArcIndices.Add(i);
    Items.Add(item);
  }

  // pointers are set after all items were added, because CObjectVector can't move the strings
  FOR_VECTOR (k, Items)
  {
    Items[k].Path = Paths[k].Ptr();
    Items[k].Method = Methods[k].Ptr();
  }
  return S_OK;
}


void CArchiveMac::ReadArcProps()
{
  const CCodecs *codecs = g_Codecs;
  FOR_VECTOR (r, ArcLink.Arcs)
  {
    const CArc &arc = ArcLink.Arcs[r];
    AddPropPair(PropNames, PropValues, GetPropName(kpidPath, NULL), arc.Path);
    AddPropPair(PropNames, PropValues, GetPropName(kpidType, NULL), codecs->GetFormatNamePtr(arc.FormatIndex));

    IInArchive *archive = arc.Archive;
    {
      NCOM::CPropVariant prop;
      if (archive->GetArchiveProperty(kpidPhySize, &prop) == S_OK)
        AddPropPair_Prop(PropNames, PropValues, kpidPhySize, NULL, prop);
    }
    const Int64 offset = arc.GetGlobalOffset();
    if (offset != 0)
    {
      UString s;
      s.Add_UInt64((UInt64)offset);
      AddPropPair(PropNames, PropValues, GetPropName(kpidOffset, NULL), s);
    }
    UInt32 numProps;
    if (archive->GetNumberOfArchiveProperties(&numProps) == S_OK)
    {
      for (UInt32 j = 0; j < numProps; j++)
      {
        CMyComBSTR name;
        PROPID propID;
        VARTYPE vt;
        if (archive->GetArchivePropertyInfo(j, &name, &propID, &vt) != S_OK)
          continue;
        if (propID == kpidPhySize)
          continue;
        NCOM::CPropVariant prop;
        if (archive->GetArchiveProperty(propID, &prop) != S_OK)
          continue;
        AddPropPair_Prop(PropNames, PropValues, propID, name, prop);
      }
    }
  }
  FormatName = ToUtf8(UString(codecs->GetFormatNamePtr(ArcLink.Arcs.Back().FormatIndex)));
}


unsigned CArchiveMac::GetItemProps(unsigned itemIndex, const CPropPair **props)
{
  ItemPropNames.Clear();
  ItemPropValues.Clear();
  ItemProps.Clear();

  const UInt32 arcIndex = ArcIndices[itemIndex];
  IInArchive *archive = ArcLink.GetArchive();
  AddPropPair(ItemPropNames, ItemPropValues, GetPropName(kpidPath, NULL), FromUtf8(Paths[itemIndex]));
  UInt32 numProps;
  if (archive->GetNumberOfProperties(&numProps) == S_OK)
  {
    for (UInt32 j = 0; j < numProps; j++)
    {
      CMyComBSTR name;
      PROPID propID;
      VARTYPE vt;
      if (archive->GetPropertyInfo(j, &name, &propID, &vt) != S_OK)
        continue;
      if (propID == kpidPath)
        continue;
      NCOM::CPropVariant prop;
      if (archive->GetProperty(arcIndex, propID, &prop) != S_OK)
        continue;
      AddPropPair_Prop(ItemPropNames, ItemPropValues, propID, name, prop);
    }
  }
  FOR_VECTOR (i, ItemPropNames)
  {
    CPropPair p;
    p.Name = ItemPropNames[i].Ptr();
    p.Value = ItemPropValues[i].Ptr();
    ItemProps.Add(p);
  }
  *props = ItemProps.ConstData();
  return ItemProps.Size();
}


static int CompareUInt32(const UInt32 *a, const UInt32 *b, void * /* param */)
{
  return MyCompare(*a, *b);
}

void CArchiveMac::Extract(const uint32_t *indices, unsigned numIndices,
    const char *outDir, const char *prefix,
    EPathMode pathMode, EOverwriteMode overwriteMode,
    bool testMode,
    IUserCallback *callback, CResult &result)
{
  result.Clear();

  CExtractCallbackMac *ecs = new CExtractCallbackMac;
  CMyComPtr<IFolderArchiveExtractCallback> extractCallback2 = ecs;
  ecs->Init(callback, &result, testMode);
  if (PasswordIsDefined)
  {
    ecs->PasswordIsDefined = true;
    ecs->Password = Password;
  }

  HRESULT res = S_OK;
  try
  {
    CArchiveExtractCallback *spec = new CArchiveExtractCallback;
    CMyComPtr<IArchiveExtractCallback> extractCallback = spec;

    spec->InitForMulti(
        false, // multiArchives
        (NExtract::NPathMode::EEnum)pathMode,
        (NExtract::NOverwriteMode::EEnum)overwriteMode,
        NExtract::NZoneIdMode::kNone,
        false); // keepAndReplaceEmptyDirPrefixes

    const CArc &arc = ArcLink.Arcs.Back();
    callback->SetTotal(arc.GetEstmatedPhySize());

    FString outDirF;
    if (!testMode)
    {
      outDirF = us2fs(FromUtf8(outDir));
      if (!outDirF.IsEmpty())
      {
        NName::NormalizeDirPathPrefix(outDirF);
        NDir::CreateComplexDir(outDirF);
      }
    }

    UStringVector removePathParts;
    {
      UString prefixU = FromUtf8(prefix);
      UStringVector parts;
      SplitPathToParts(prefixU, parts);
      FOR_VECTOR (i, parts)
        if (!parts[i].IsEmpty())
          removePathParts.Add(parts[i]);
    }

    CExtractNtOptions ntOptions;
    ntOptions.AltStreams.Val = false;
    ntOptions.AltStreams.Def = true;

    spec->InitBeforeNewArchive();
    spec->Init(
        ntOptions,
        NULL, &arc,
        extractCallback2,
        false, // stdOutMode
        testMode,
        outDirF,
        removePathParts, false,
        (UInt64)(Int64)-1);

    CRecordVector<UInt32> realIndices;
    for (unsigned i = 0; i < numIndices; i++)
      realIndices.Add(ArcIndices[indices[i]]);
    realIndices.Sort(CompareUInt32, NULL);

    #ifdef SUPPORT_LINKS
    if (!testMode)
      res = spec->PrepareHardLinks(&realIndices);
    #endif

    if (res == S_OK)
    {
      CArchiveExtractCallback_Closer ecsCloser(spec);
      res = arc.Archive->Extract(realIndices.ConstData(), realIndices.Size(),
          BoolToInt(testMode), extractCallback);
      const HRESULT res2 = ecsCloser.Close();
      if (res == S_OK)
        res = res2;
    }
  }
  catch(const CSystemException &e) { res = e.ErrorCode; }
  catch(...) { res = E_FAIL; }

  if (ecs->PasswordIsDefined && !PasswordIsDefined)
  {
    PasswordIsDefined = true;
    Password = ecs->Password;
    PasswordA = ToUtf8(Password);
  }

  if (res != S_OK && res != E_ABORT)
    ecs->AddError(NError::MyFormatMessage(res));
  result.HResult = res;
  result.NumFiles = ecs->NumFiles;
}


NMacEngine::IArchive *NMacEngine::OpenArchive(const char *path, const char *password,
    IUserCallback *callback, CResult &result)
{
  result.Clear();
  if (!g_Codecs)
  {
    result.HResult = E_FAIL;
    return NULL;
  }

  CArchiveMac *arc = new CArchiveMac;
  COpenCallbackMac openCallback;
  openCallback.InitBase(callback, &result);
  if (password)
    openCallback.SetPassword_Utf8(password);

  HRESULT res = S_OK;
  const UString pathU = FromUtf8(path);
  try
  {
    CObjectVector<COpenType> types;
    CIntVector excludedFormats;
    CObjectVector<CProperty> props;

    COpenOptions options;
    options.props = &props;
    options.codecs = g_Codecs;
    options.types = &types;
    options.excludedFormats = &excludedFormats;
    options.stdInMode = false;
    options.stream = NULL;
    options.filePath = pathU;

    callback->SetCurrent(kOp_Opening, path);
    res = arc->ArcLink.Open3(options, &openCallback);

    UString s;
    if (res != E_ABORT)
      OpenResult_Mac(s, g_Codecs, arc->ArcLink, pathU, res);
    if (!s.IsEmpty())
    {
      if (res == S_OK)
        openCallback.AddWarning(s);
      else
        openCallback.AddError(s);
    }

    if (res == S_OK)
    {
      res = arc->ReadItems();
      if (res == S_OK)
        arc->ReadArcProps();
    }
  }
  catch(const CSystemException &e) { res = e.ErrorCode; }
  catch(...) { res = E_FAIL; }

  result.HResult = res;
  if (res != S_OK)
  {
    delete arc;
    return NULL;
  }

  if (openCallback.PasswordIsDefined)
  {
    arc->PasswordIsDefined = true;
    arc->Password = openCallback.Password;
    arc->PasswordA = ToUtf8(openCallback.Password);
  }
  if (arc->ArcLink.PasswordWasAsked)
    arc->_isEncrypted = true;

  {
    const CArc &a = arc->ArcLink.Arcs.Back();
    bool canUpdate = false;
    if (arc->ArcLink.Arcs.Size() == 1 && a.FormatIndex >= 0 && !a.IsReadOnly)
    {
      const CArcInfoEx &ai = g_Codecs->Formats[(unsigned)a.FormatIndex];
      canUpdate = ai.UpdateEnabled && !ai.Flags_KeepName() && a.ErrorInfo.GetErrorFlags() == 0;
    }
    arc->_canUpdate = canUpdate;
  }
  return arc;
}

NMacEngine::IUserCallback::~IUserCallback() {}
NMacEngine::IArchive::~IArchive() {}
