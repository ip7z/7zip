#include <windows.h>
#include <shlobj.h>
#include <cstdio>
#include <string>

static bool dumpMenu = false;
static const char *targetVerb = "SevenZipCompressTo7zBackup";

static bool isBackupTitle(const wchar_t *title) {
  const size_t n = wcslen(title);
  if (n < 21) return false;
  const wchar_t *s = title + n - 21;
  for (unsigned i = 0; i < 17; ++i) {
    if (i == 0 || i == 5 || i == 8 || i == 11 || i == 14) {
      if (s[i] != L'-') return false;
    } else if (s[i] < L'0' || s[i] > L'9') return false;
  }
  return wcscmp(s + 17, L".7z\"") == 0;
}

static void check(HRESULT hr, const char *what) {
  if (FAILED(hr)) { printf("FAIL %s: %08lx\n", what, (unsigned long)hr); ExitProcess(1); }
}
static UINT findBackup(HMENU menu, IContextMenu *cm, bool in7zip = false) {
  for (int i = 0; i < GetMenuItemCount(menu); ++i) {
    wchar_t label[1024] = {};
    GetMenuStringW(menu, i, label, 1024, MF_BYPOSITION);
    HMENU sub = GetSubMenu(menu, i);
    if (dumpMenu) wprintf(L"%ls%ls\n", label, sub ? L" >" : L"");
    if (sub) {
      UINT id = findBackup(sub, cm, in7zip || std::wstring(label) == L"7-Zip");
      if (id) return id;
    } else {
      UINT id = GetMenuItemID(menu, i);
      if (id == UINT(-1) || !id) continue;
      char verb[256] = {};
      if (SUCCEEDED(cm->GetCommandString(id - 1, GCS_VERBA, nullptr, verb, 256)) &&
          std::string(verb) == targetVerb) {
        if (!in7zip) { puts("FAIL backup is outside 7-Zip submenu"); ExitProcess(1); }
        wprintf(L"Menu item: %ls\n", label);
        return id;
      }
    }
  }
  return 0;
}
int wmain(int argc, wchar_t **argv) {
  if (argc != 4) return 2;
  const std::wstring mode(argv[3]);
  dumpMenu = mode == L"dump";
  if (mode == L"stock") targetVerb = "SevenZipCompressTo7z";
  check(CoInitialize(nullptr), "CoInitialize");
  HMODULE dll = LoadLibraryW(argv[1]);
  if (!dll) { printf("FAIL LoadLibrary: %lu\n", GetLastError()); return 1; }
  auto getClass = (HRESULT (WINAPI *)(REFCLSID, REFIID, void **))GetProcAddress(dll, "DllGetClassObject");
  if (!getClass) return 1;
  CLSID clsid;
  CLSIDFromString(L"{23170F69-40C1-278A-1000-000100020000}", &clsid);
  IClassFactory *factory = nullptr;
  check(getClass(clsid, IID_IClassFactory, (void **)&factory), "class factory");
  IShellExtInit *init = nullptr;
  check(factory->CreateInstance(nullptr, IID_IShellExtInit, (void **)&init), "create extension");
  PIDLIST_ABSOLUTE full = nullptr;
  check(SHParseDisplayName(argv[2], nullptr, &full, 0, nullptr), "parse test folder");
  PIDLIST_ABSOLUTE parent = ILCloneFull(full);
  ILRemoveLastID(parent);
  PCUITEMID_CHILD children[] = { ILFindLastID(full), ILFindLastID(full) };
  const UINT count = mode == L"multiple" ? 2 : 1;
  IDataObject *data = nullptr;
  check(SHCreateDataObject(parent, count, children, nullptr, IID_IDataObject, (void **)&data), "data object");
  check(init->Initialize(mode == L"drag" ? parent : nullptr, data, nullptr), "initialize extension");
  IContextMenu *cm = nullptr;
  check(init->QueryInterface(IID_IContextMenu, (void **)&cm), "context menu");
  HMENU menu = CreatePopupMenu();
  check(cm->QueryContextMenu(menu, 0, 1, 32767, CMF_NORMAL), "query menu");
  UINT id = findBackup(menu, cm);
  bool expect = mode != L"absent" && mode != L"multiple" && mode != L"drag" && mode != L"flat";
  if (!dumpMenu && (id != 0) != expect) { puts("FAIL unexpected backup command visibility"); return 1; }
  if (mode == L"invoke" || mode == L"stock") {
    CMINVOKECOMMANDINFO info = {};
    info.cbSize = sizeof(info);
    info.lpVerb = MAKEINTRESOURCEA(id - 1);
    info.nShow = SW_SHOWNORMAL;
    check(cm->InvokeCommand(&info), "invoke backup");
    puts("Invoked backup command");
  }
  if (!dumpMenu && mode != L"drag") {
    PCIDLIST_ABSOLUTE items[] = { full, full };
    IShellItemArray *array = nullptr;
    check(SHCreateShellItemArrayFromIDLists(count, items, &array), "shell item array");
    IExplorerCommand *root = nullptr;
    check(factory->CreateInstance(nullptr, IID_IExplorerCommand, (void **)&root), "modern command");
    LPWSTR title = nullptr;
    check(root->GetTitle(array, &title), "modern root title");
    if (wcscmp(title, L"7-Zip")) return 1;
    CoTaskMemFree(title);
    IEnumExplorerCommand *commands = nullptr;
    check(root->EnumSubCommands(&commands), "modern submenu");
    unsigned backups = 0;
    IExplorerCommand *command = nullptr;
    while (commands->Next(1, &command, nullptr) == S_OK) {
      title = nullptr;
      check(command->GetTitle(array, &title), "modern child title");
      if (title && isBackupTitle(title)) {
        ++backups;
        if (mode == L"moderninvoke") check(command->Invoke(array, nullptr), "modern backup invocation");
      }
      CoTaskMemFree(title);
      command->Release();
    }
    if (backups != unsigned(expect || mode == L"flat")) {
      puts("FAIL modern backup visibility"); return 1;
    }
    commands->Release(); root->Release(); array->Release();
    puts("Modern submenu PASS");
  }
  DestroyMenu(menu);
  cm->Release(); init->Release(); factory->Release(); data->Release();
  CoTaskMemFree(parent); CoTaskMemFree(full);
  CoUninitialize();
  puts("PASS");
  return 0;
}
