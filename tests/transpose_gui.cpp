// Run beside 7zG.exe under Windows or Wine. Exercises the actual dialog.
#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "../CPP/7zip/UI/GUI/CompressDialogRes.h"
static HWND dialog;
static DWORD processId;
static BOOL CALLBACK Find(HWND w, LPARAM) {
  DWORD pid = 0; GetWindowThreadProcessId(w, &pid);
  if (pid == processId && GetDlgItem(w, IDC_COMPRESS_METHOD) && GetDlgItem(w, IDC_COMPRESS_PREPROCESS)) dialog = w;
  return TRUE;
}
static void Check(bool b, const char *what) {
  if (!b) { std::fprintf(stderr, "FAIL: %s\n", what); std::exit(1); }
}
static int FindItem(int id, const char *needle) {
  HWND box = GetDlgItem(dialog, id);
  int count = (int)SendMessageA(box, CB_GETCOUNT, 0, 0);
  for (int i = 0; i < count; ++i) {
    wchar_t wide[512] = {};
    char text[1024] = {};
    SendMessageW(box, CB_GETLBTEXT, i, (LPARAM)wide);
    WideCharToMultiByte(CP_UTF8, 0, wide, -1, text, sizeof(text), NULL, NULL);
    if (id == IDC_COMPRESS_FORMAT ? std::strcmp(text, needle) == 0 : std::strstr(text, needle) != NULL) return i;
  }
  return -1;
}
static void Select(int id, int index) {
  Check(index >= 0, "combo item exists");
  HWND box = GetDlgItem(dialog, id);
  SendMessageA(box, CB_SETCURSEL, index, 0);
  SendMessageA(dialog, WM_COMMAND, MAKEWPARAM(id, CBN_SELCHANGE), (LPARAM)box);
}
static bool Enabled() { return IsWindowEnabled(GetDlgItem(dialog, IDC_COMPRESS_PREPROCESS)) != 0; }
int main() {
  STARTUPINFOA si = {}; si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {};
  char command[] = "7zG.exe a -ad gui-test.7z gui-input.bin";
  Check(CreateProcessA(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi), "launch 7zG");
  processId = pi.dwProcessId;
  for (int i = 0; i < 300 && !dialog; ++i) { EnumWindows(Find, 0); Sleep(100); }
  Check(dialog != NULL, "compression dialog found");
  Sleep(1500);
  Check(FindItem(IDC_COMPRESS_METHOD, "anyz2") == -1, "anyz2 absent from compressors");
  Check(FindItem(IDC_COMPRESS_PREPROCESS, "anyz2") >= 0, "anyz2 in preprocessing");
  Select(IDC_COMPRESS_FORMAT, FindItem(IDC_COMPRESS_FORMAT, "zip"));
  Check(!Enabled(), "ZIP disables preprocessing");
  Select(IDC_COMPRESS_FORMAT, FindItem(IDC_COMPRESS_FORMAT, "7z"));
  Select(IDC_COMPRESS_LEVEL, 0);
  Check(!Enabled(), "Store disables preprocessing");
  Select(IDC_COMPRESS_LEVEL, 3);
  Check(Enabled(), "compressed 7z enables preprocessing");
  HWND sfx = GetDlgItem(dialog, IDX_COMPRESS_SFX);
  SendMessageA(sfx, BM_CLICK, 0, 0);
  Check(!Enabled(), "SFX disables preprocessing");
  SendMessageA(sfx, BM_CLICK, 0, 0);
  Check(Enabled(), "return from SFX restores preprocessing");
  Select(IDC_COMPRESS_METHOD, FindItem(IDC_COMPRESS_METHOD, "BZip2"));
  Check(!Enabled(), "unsupported probe coder disables preprocessing");
  Select(IDC_COMPRESS_METHOD, FindItem(IDC_COMPRESS_METHOD, "PPMd"));
  Check(Enabled(), "PPMd supports preprocessing");
  Select(IDC_COMPRESS_DICTIONARY, FindItem(IDC_COMPRESS_DICTIONARY, "16 MB"));
  Select(IDC_COMPRESS_ORDER, FindItem(IDC_COMPRESS_ORDER, "16"));
  Select(IDC_COMPRESS_PREPROCESS, FindItem(IDC_COMPRESS_PREPROCESS, "anyz2"));
  SetWindowTextA(GetDlgItem(dialog, IDC_COMPRESS_ARCHIVE), "gui-test.7z");
  FILE *f = std::fopen("gui-ready", "w"); if (f) std::fclose(f);
  Sleep(2500);
  SendMessageA(GetDlgItem(dialog, IDOK), BM_CLICK, 0, 0);
  Check(WaitForSingleObject(pi.hProcess, 90000) == WAIT_OBJECT_0, "GUI compression completed");
  DWORD result = 1; GetExitCodeProcess(pi.hProcess, &result);
  Check(result == 0, "GUI compression successful");
  CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
  std::puts("GUI categories, ZIP, Store, SFX, BZip2, PPMd and compression passed");
}
