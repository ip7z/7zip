// RegistryContextMenu.cpp

#include "StdAfx.h"

#include "../../../Common/StringConvert.h"

#include "../../../Windows/Registry.h"

#include "RegistryContextMenu.h"

using namespace NWindows;
using namespace NRegistry;

#ifndef UNDER_CE

// does extension can work, if Approved is removed ?
// CLISID (and Approved ?) items are separated for 32-bit and 64-bit code.
// shellex items shared by 32-bit and 64-bit code?

#define k_Clsid_A "{23170F69-40C1-278A-1000-000100020000}"

static LPCTSTR const k_Clsid = TEXT(k_Clsid_A);
static LPCTSTR const k_ShellExtName = TEXT("7-Zip Shell Extension");

static LPCTSTR const k_Approved = TEXT("Software\\Microsoft\\Windows\\CurrentVersion\\Shell Extensions\\Approved");
static LPCTSTR const k_Inproc = TEXT("InprocServer32");

static LPCSTR const k_KeyPostfix_ContextMenu = "\\shellex\\ContextMenuHandlers\\7-Zip";
static LPCSTR const k_KeyPostfix_DragDrop    = "\\shellex\\DragDropHandlers\\7-Zip";

static LPCSTR const k_KeyName_File      = "*";
static LPCSTR const k_KeyName_Folder    = "Folder";
static LPCSTR const k_KeyName_Directory = "Directory";
static LPCSTR const k_KeyName_Drive     = "Drive";

static LPCSTR const k_shellex_Prefixes[] =
{
  k_KeyName_File,
  k_KeyName_Folder,
  k_KeyName_Directory,
  k_KeyName_Drive
};

static const bool k_shellex_Statuses[2][4] =
{
  { true, true, true, false },
  { false, false, true, true }
};


// RegDeleteKeyExW is supported starting from win2003sp1/xp-pro-x64
// Z7_WIN32_WINNT_MIN < 0x0600  // Vista
#if !defined(Z7_WIN32_WINNT_MIN) \
    || Z7_WIN32_WINNT_MIN  < 0x0502  /* < win2003 */ \
    || Z7_WIN32_WINNT_MIN == 0x0502 && !defined(_M_AMD64)
#define Z7_USE_DYN_RegDeleteKeyExW
#endif

#ifdef Z7_USE_DYN_RegDeleteKeyExW
Z7_DIAGNOSTIC_IGNORE_CAST_FUNCTION
typedef
// WINADVAPI
LONG (APIENTRY *Func_RegDeleteKeyExW)(HKEY hKey, LPCWSTR lpSubKey, REGSAM samDesired, DWORD Reserved);
static Func_RegDeleteKeyExW func_RegDeleteKeyExW;

static void Init_RegDeleteKeyExW()
{
  if (!func_RegDeleteKeyExW)
    func_RegDeleteKeyExW = Z7_GET_PROC_ADDRESS(
    Func_RegDeleteKeyExW, GetModuleHandleW(L"advapi32.dll"),
        "RegDeleteKeyExW");
}
#define INIT_REG_WOW if (wow != 0) Init_RegDeleteKeyExW();
#else
#define INIT_REG_WOW
#endif


static LONG MyRegistry_DeleteKey(HKEY parentKey, LPCTSTR name, UInt32 wow)
{
  if (wow == 0)
    return RegDeleteKey(parentKey, name);

#ifdef Z7_USE_DYN_RegDeleteKeyExW
  if (!func_RegDeleteKeyExW)
    return E_NOTIMPL;
  return func_RegDeleteKeyExW
#else
  return RegDeleteKeyExW
#endif
      (parentKey, GetUnicodeString(name), wow, 0);
}

static LONG MyRegistry_DeleteKey_HKCR(LPCTSTR name, UInt32 wow)
{
  return MyRegistry_DeleteKey(HKEY_CLASSES_ROOT, name, wow);
}

// static NSynchronization::CCriticalSection g_CS;

static AString Get_ContextMenuHandler_KeyName(LPCSTR keyName)
  { return (AString)keyName + k_KeyPostfix_ContextMenu; }

/*
static CSysString Get_DragDropHandler_KeyName(LPCTSTR keyName)
  { return (AString)keyName + k_KeyPostfix_DragDrop); }
*/

// The MSI records this marker only in the installation's own registry hive.
// Legacy machine installers also wrote Software\7-Zip\Path to HKCU, so that
// older value cannot be used to determine the installation scope.
static bool IsPerUserInstallation(const UString &path)
{
  CKey key;
  if (key.Open(HKEY_CURRENT_USER, TEXT("Software\\7-Zip\\Installer"), KEY_READ) != ERROR_SUCCESS)
    return false;
  UString installPath;
  if (key.QueryValue(
      #ifdef _WIN64
        L"Path64",
      #else
        L"Path32",
      #endif
      installPath) != ERROR_SUCCESS)
    return false;
  while (!installPath.IsEmpty() && (installPath.Back() == L'\\' || installPath.Back() == L'/'))
    installPath.DeleteBack();
  const int pos = path.ReverseFind_PathSepar();
  return pos >= 0 && !installPath.IsEmpty()
      && installPath.IsEqualTo_NoCase(path.Left(pos));
}

static bool CheckHandlerCommon(HKEY classesKey, const AString &keyName, UInt32 wow)
{
  CKey key;
  if (key.Open(classesKey, (CSysString)keyName, KEY_READ | wow) != ERROR_SUCCESS)
    return false;
  CSysString value;
  if (key.QueryValue(NULL, value) != ERROR_SUCCESS)
    return false;
  return StringsAreEqualNoCase_Ascii(value, k_Clsid_A);
}

bool CheckContextMenuHandler(const UString &path, UInt32 wow)
{
  // NSynchronization::CCriticalSectionLock lock(g_CS);

  CKey userClasses;
  HKEY classesKey = HKEY_CLASSES_ROOT;
  if (IsPerUserInstallation(path))
  {
    if (userClasses.Open(HKEY_CURRENT_USER, TEXT("Software\\Classes"), KEY_READ | wow) != ERROR_SUCCESS)
      return false;
    classesKey = userClasses;
  }

  CSysString s ("CLSID\\");
  s += k_Clsid_A;
  s += "\\InprocServer32";
  
  {
    NRegistry::CKey key;
    if (key.Open(classesKey, s, KEY_READ | wow) != ERROR_SUCCESS)
      return false;
    UString regPath;
    if (key.QueryValue(NULL, regPath) != ERROR_SUCCESS)
      return false;
    if (!path.IsEqualTo_NoCase(regPath))
      return false;
  }
  
  return
       CheckHandlerCommon(classesKey, Get_ContextMenuHandler_KeyName(k_KeyName_File), wow);
  /*
    && CheckHandlerCommon(Get_ContextMenuHandler_KeyName(k_KeyName_Directory), wow)
    // && CheckHandlerCommon(Get_ContextMenuHandler_KeyName(k_KeyName_Folder))

    && CheckHandlerCommon(Get_DragDropHandler_KeyName(k_KeyName_Directory), wow)
    && CheckHandlerCommon(Get_DragDropHandler_KeyName(k_KeyName_Drive), wow);
  */
}


static LONG MyCreateKey(CKey &key, HKEY parentKey, LPCTSTR keyName, UInt32 wow)
{
  return key.Create(parentKey, keyName, REG_NONE,
      REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS | wow);
}

static LONG SetContextMenuHandlerForUser(bool setMode, const UString &path, UInt32 wow)
{
  CKey classesKey;
  LONG res;
  if (setMode)
    res = MyCreateKey(classesKey, HKEY_CURRENT_USER, TEXT("Software\\Classes"), wow);
  else
    res = classesKey.Open(HKEY_CURRENT_USER, TEXT("Software\\Classes"), KEY_READ | KEY_WRITE | wow);
  if (res != ERROR_SUCCESS)
    return !setMode && (res == ERROR_FILE_NOT_FOUND || res == ERROR_PATH_NOT_FOUND)
        ? ERROR_SUCCESS : res;

  CSysString clsidKey ("CLSID\\");
  clsidKey += k_Clsid_A;
  CSysString inprocKey (clsidKey);
  inprocKey += "\\InprocServer32";

  if (!setMode)
  {
    // Do not remove another copy's registration, even in the same user hive.
    {
      CKey key;
      res = key.Open(classesKey, inprocKey, KEY_READ | wow);
      if (res == ERROR_FILE_NOT_FOUND || res == ERROR_PATH_NOT_FOUND)
        return ERROR_SUCCESS;
      if (res != ERROR_SUCCESS)
        return res;
      UString registeredPath;
      res = key.QueryValue(NULL, registeredPath);
      if (res != ERROR_SUCCESS)
        return res;
      if (!path.IsEqualTo_NoCase(registeredPath))
        return ERROR_SUCCESS;
    }
    res = MyRegistry_DeleteKey(classesKey, inprocKey, wow);
    if (res != ERROR_SUCCESS)
      return res;
    // Keep the shared handler keys: the other DLL architecture can still use them.
    return MyRegistry_DeleteKey(classesKey, clsidKey, wow);
  }

  {
    CKey key;
    res = MyCreateKey(key, classesKey, clsidKey, wow);
    if (res != ERROR_SUCCESS)
      return res;
    res = key.SetValue(NULL, k_ShellExtName);
    if (res != ERROR_SUCCESS)
      return res;
    CKey inproc;
    res = MyCreateKey(inproc, key, k_Inproc, wow);
    if (res != ERROR_SUCCESS)
      return res;
    res = inproc.SetValue(NULL, path);
    if (res != ERROR_SUCCESS)
      return res;
    res = inproc.SetValue(TEXT("ThreadingModel"), TEXT("Apartment"));
    if (res != ERROR_SUCCESS)
      return res;
  }

  {
    CKey approved;
    res = MyCreateKey(approved, HKEY_CURRENT_USER, k_Approved, wow);
    if (res != ERROR_SUCCESS)
      return res;
    res = approved.SetValue(k_Clsid, k_ShellExtName);
    if (res != ERROR_SUCCESS)
      return res;
  }

  for (unsigned i = 0; i < 2; i++)
    for (unsigned k = 0; k < Z7_ARRAY_SIZE(k_shellex_Prefixes); k++)
      if (k_shellex_Statuses[i][k])
      {
        CSysString s (k_shellex_Prefixes[k]);
        s += (i == 0 ? k_KeyPostfix_ContextMenu : k_KeyPostfix_DragDrop);
        CKey key;
        res = MyCreateKey(key, classesKey, s, wow);
        if (res != ERROR_SUCCESS)
          return res;
        res = key.SetValue(NULL, k_Clsid);
        if (res != ERROR_SUCCESS)
          return res;
      }

  return ERROR_SUCCESS;
}

LONG SetContextMenuHandler(bool setMode, const UString &path, UInt32 wow)
{
  // NSynchronization::CCriticalSectionLock lock(g_CS);

  INIT_REG_WOW

  if (IsPerUserInstallation(path))
    return SetContextMenuHandlerForUser(setMode, path, wow);

  LONG res;

  {
  CSysString s ("CLSID\\");
  s += k_Clsid_A;

  if (setMode)
  {
    {
      CKey key;
      res = MyCreateKey(key, HKEY_CLASSES_ROOT, s, wow);
      if (res == ERROR_SUCCESS)
      {
        key.SetValue(NULL, k_ShellExtName);
        CKey keyInproc;
        res = MyCreateKey(keyInproc, key, k_Inproc, wow);
        if (res == ERROR_SUCCESS)
        {
          res = keyInproc.SetValue(NULL, path);
          keyInproc.SetValue(TEXT("ThreadingModel"), TEXT("Apartment"));
        }
      }
    }
    
    {
      CKey key;
      if (MyCreateKey(key, HKEY_LOCAL_MACHINE, k_Approved, wow) == ERROR_SUCCESS)
        key.SetValue(k_Clsid, k_ShellExtName);
    }
  }
  else
  {
    CSysString s2 (s);
    s2 += "\\InprocServer32";

    MyRegistry_DeleteKey_HKCR(s2, wow);
    res = MyRegistry_DeleteKey_HKCR(s, wow);
  }
  }

  // shellex items probably are shared beween 32-bit and 64-bit apps. So we don't delete items for delete operation.
  if (setMode)
  for (unsigned i = 0; i < 2; i++)
  {
    for (unsigned k = 0; k < Z7_ARRAY_SIZE(k_shellex_Prefixes); k++)
    {
      CSysString s (k_shellex_Prefixes[k]);
      s += (i == 0 ? k_KeyPostfix_ContextMenu : k_KeyPostfix_DragDrop);
      if (k_shellex_Statuses[i][k])
      {
        CKey key;
        MyCreateKey(key, HKEY_CLASSES_ROOT, s, wow);
        key.SetValue(NULL, k_Clsid);
      }
      else
        MyRegistry_DeleteKey_HKCR(s, wow);
    }
  }

  return res;
}

#endif
