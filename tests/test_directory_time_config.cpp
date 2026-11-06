// Test the actual configuration storage in an isolated per-process HKCU root.
#define Z7_WIN32_WINNT_MIN 0x0600
#include "../CPP/7zip/UI/GUI/StdAfx.h"
#include <windows.h>
#include <process.h>
#include <stdio.h>
#include <wchar.h>
#include "../CPP/7zip/UI/Common/ZipRegistry.h"

int __cdecl wmain(int argc, wchar_t **argv)
{
  if (argc == 4 && wcscmp(argv[1], L"--read") == 0)
  {
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, argv[2], 0, KEY_ALL_ACCESS, &key) != ERROR_SUCCESS)
      return 10;
    if (RegOverridePredefKey(HKEY_CURRENT_USER, key) != ERROR_SUCCESS)
      return 11;
    const bool value = NExtract::Read_UseCurrentDirTimes();
    RegOverridePredefKey(HKEY_CURRENT_USER, NULL);
    RegCloseKey(key);
    return value == (argv[3][0] == L'1') ? 0 : 12;
  }

  wchar_t path[160];
  swprintf_s(path, L"Software\\7ZipDirectoryTimeTest-%lu-%lu", GetCurrentProcessId(), GetTickCount());
  HKEY key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, NULL, 0, KEY_ALL_ACCESS, NULL, &key, NULL) != ERROR_SUCCESS)
    return 1;
  int result = 0;
  if (RegOverridePredefKey(HKEY_CURRENT_USER, key) != ERROR_SUCCESS)
    result = 2;
  else
  {
    if (NExtract::Read_UseCurrentDirTimes())
      result = 3;
    NExtract::Save_UseCurrentDirTimes(true);
    if (!NExtract::Read_UseCurrentDirTimes())
      result = 4;
    CBoolPair option;
    NExtract::Load_UseCurrentDirTimes(option);
    if (!option.Val || option.Def)
      result = 13;
    option.Def = true;
    option.Val = false;
    NExtract::Load_UseCurrentDirTimes(option);
    if (option.Val)
      result = 14;
    NExtract::CInfo info;
    info.Load();
    info.Save();
    if (!NExtract::Read_UseCurrentDirTimes())
      result = 5;
    RegOverridePredefKey(HKEY_CURRENT_USER, NULL);
    if (_wspawnl(_P_WAIT, argv[0], argv[0], L"--read", path, L"1", NULL) != 0)
      result = 6;
    RegOverridePredefKey(HKEY_CURRENT_USER, key);
    NExtract::Save_UseCurrentDirTimes(false);
    if (NExtract::Read_UseCurrentDirTimes())
      result = 7;
    option.Val = true;
    NExtract::Load_UseCurrentDirTimes(option);
    if (!option.Val)
      result = 15;
    RegOverridePredefKey(HKEY_CURRENT_USER, NULL);
    if (_wspawnl(_P_WAIT, argv[0], argv[0], L"--read", path, L"0", NULL) != 0)
      result = 8;
  }
  RegCloseKey(key);
  if (RegDeleteTreeW(HKEY_CURRENT_USER, path) != ERROR_SUCCESS)
    result = 9;
  if (result == 0)
    puts("PASS: default off, saved on/off, history-save isolation, explicit override precedence, cross-process persistence");
  else
    printf("FAIL: configuration test code %d\n", result);
  return result;
}
