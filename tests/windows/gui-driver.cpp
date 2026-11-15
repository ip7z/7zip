#define WinMain ProductGuiWinMain
#include "../../CPP/7zip/UI/GUI/GUI.cpp"
#undef WinMain

#include <atomic>
#include <thread>
#include "../../CPP/7zip/UI/GUI/CompressDialogRes.h"
#include "../../CPP/7zip/UI/FileManager/RegistryUtils.h"
#include "../../DarkMode/lib/include/Darkmodelib.h"

int WINAPI WinMain(HINSTANCE instance, HINSTANCE, LPSTR, int)
{
  wchar_t root[512], desktopName[256], eventName[256];
  if (!GetEnvironmentVariableW(L"SEVENZIP_TEST_REGROOT", root, 512)
      || !GetEnvironmentVariableW(L"SEVENZIP_TEST_DESKTOP", desktopName, 256)
      || !GetEnvironmentVariableW(L"SEVENZIP_TEST_GUI_EVENT", eventName, 256)) return 2;
  HKEY key;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, root, 0, KEY_ALL_ACCESS, &key) != ERROR_SUCCESS) return 3;
  if (RegOverridePredefKey(HKEY_CURRENT_USER, key) != ERROR_SUCCESS) return 4;
  HDESK desktop = OpenDesktopW(desktopName, 0, FALSE, GENERIC_ALL);
  if (!desktop || !SetThreadDesktop(desktop)) return 5;
  HANDLE proof = OpenEventW(EVENT_MODIFY_STATE, FALSE, eventName);
  if (!proof) return 6;
  const DWORD mainThread = GetCurrentThreadId();
  std::atomic<bool> finished{false};
  std::thread observer([&] {
    SetThreadDesktop(desktop);
    const ULONGLONG deadline = GetTickCount64() + 10000;
    while (!finished && GetTickCount64() < deadline)
    {
      EnumThreadWindows(mainThread, [](HWND window, LPARAM data) -> BOOL {
        if (GetDlgItem(window, IDC_COMPRESS_ARCHIVE) && GetDlgItem(window, IDC_COMPRESS_FORMAT)
            && GetDlgItem(window, IDC_COMPRESS_LEVEL))
        {
          const UInt32 mode = Read_ClrMode();
          const bool expectedDark = mode == 1 || (mode == 2 && dmlib::isDarkModeReg());
          if (dmlib::isEnabled() == expectedDark)
            SetEvent(reinterpret_cast<HANDLE>(data));
          PostMessageW(window, WM_COMMAND, IDCANCEL, 0);
        }
        return TRUE;
      }, reinterpret_cast<LPARAM>(proof));
      Sleep(10);
    }
  });
  const int result = ProductGuiWinMain(instance, nullptr, nullptr, SW_SHOW);
  finished = true;
  observer.join();
  CloseHandle(proof);
  RegOverridePredefKey(HKEY_CURRENT_USER, nullptr);
  RegCloseKey(key);
  return result;
}
