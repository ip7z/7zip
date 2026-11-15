#define WinMain ProductWinMain
#include "../../CPP/7zip/UI/FileManager/FM.cpp"
#undef WinMain

#include <atomic>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <shellapi.h>
#include "../../CPP/7zip/UI/FileManager/SettingsPageRes.h"
#include "../../CPP/7zip/UI/FileManager/RegistryUtils.h"
#include "../../DarkMode/lib/include/Darkmodelib.h"

static HWND testController;
static DWORD uiThread;
static HDESK testDesktop;
static std::wstring fixtureDir;
static std::vector<std::wstring> droppedPaths;
static std::atomic<bool> actionDone{false};
static bool openedArchive;
static bool editableArchive;
static DWORD returnedEffect;
static DWORD dragKeys;
static HRESULT dropResult;
static int failures;
static unsigned checks;

static void Require(bool condition, const char *message)
{
  if (!condition) throw std::runtime_error(message);
  ++checks;
  std::printf("PASS %s\n", message);
  std::fflush(stdout);
}

template<class Predicate> static bool Wait(Predicate predicate, DWORD timeout = 10000)
{
  const ULONGLONG deadline = GetTickCount64() + timeout;
  do { if (predicate()) return true; Sleep(10); } while (GetTickCount64() < deadline);
  return false;
}

class FilesData final : public IDataObject
{
  ULONG references = 1;
public:
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override
  {
    *out = nullptr;
    if (iid != IID_IUnknown && iid != IID_IDataObject) return E_NOINTERFACE;
    *out = static_cast<IDataObject *>(this); AddRef(); return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
  ULONG STDMETHODCALLTYPE Release() override
  {
    const ULONG count = --references;
    if (!count) delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE GetData(FORMATETC *format, STGMEDIUM *medium) override
  {
    if (format->cfFormat != CF_HDROP || !(format->tymed & TYMED_HGLOBAL)) return DV_E_FORMATETC;
    size_t characters = 1;
    for (const auto &path : droppedPaths) characters += path.size() + 1;
    HGLOBAL allocation = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(DROPFILES) + characters * sizeof(wchar_t));
    if (!allocation) return E_OUTOFMEMORY;
    auto *drop = static_cast<DROPFILES *>(GlobalLock(allocation));
    drop->pFiles = sizeof(DROPFILES); drop->fWide = TRUE;
    auto *cursor = reinterpret_cast<wchar_t *>(reinterpret_cast<BYTE *>(drop) + sizeof(DROPFILES));
    for (const auto &path : droppedPaths)
    {
      memcpy(cursor, path.c_str(), (path.size() + 1) * sizeof(wchar_t));
      cursor += path.size() + 1;
    }
    GlobalUnlock(allocation);
    medium->tymed = TYMED_HGLOBAL; medium->hGlobal = allocation; medium->pUnkForRelease = nullptr;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC *, STGMEDIUM *) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC *format) override
  { return format->cfFormat == CF_HDROP && (format->tymed & TYMED_HGLOBAL) ? S_OK : DV_E_FORMATETC; }
  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC *, FORMATETC *out) override
  { out->ptd = nullptr; return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE SetData(FORMATETC *, STGMEDIUM *, BOOL) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD, IEnumFORMATETC **) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC *, DWORD, IAdviseSink *, DWORD *) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA **) override { return OLE_E_ADVISENOTSUPPORTED; }
};

static LRESULT CALLBACK Controller(HWND window, UINT message, WPARAM wParam, LPARAM lParam)
{
  if (message == WM_APP + 1)
  {
    dropResult = g_App.GetFocusedPanel().BindToPathAndRefresh(fixtureDir.c_str());
    actionDone = true;
    return 0;
  }
  if (message == WM_APP + 2)
  {
    RECT rect;
    GetWindowRect(g_App.GetFocusedPanel()._listView, &rect);
    POINTL point{rect.right - 20, rect.bottom - 30};
    auto *data = new FilesData;
    DWORD effect = DROPEFFECT_COPY | DROPEFFECT_MOVE;
    dropResult = g_App._dropTarget->DragEnter(data, dragKeys, point, &effect);
    if (SUCCEEDED(dropResult))
      dropResult = g_App._dropTarget->Drop(data, dragKeys & ~MK_LBUTTON, point, &effect);
    data->Release();
    returnedEffect = effect;
    openedArchive = g_App.GetFocusedPanel().IsArcFolder();
    editableArchive = g_App.GetFocusedPanel().DoesItSupportOperations();
    actionDone = true;
    return 0;
  }
  return DefWindowProcW(window, message, wParam, lParam);
}

static HWND FindOptions()
{
  HWND result = nullptr;
  EnumThreadWindows(uiThread, [](HWND window, LPARAM parameter) -> BOOL {
    if (FindWindowExW(window, nullptr, WC_TABCONTROLW, nullptr))
    { *reinterpret_cast<HWND *>(parameter) = window; return FALSE; }
    return TRUE;
  }, reinterpret_cast<LPARAM>(&result));
  return result;
}

static HWND FindControl(HWND parent, int id)
{
  struct Search { int id; HWND result; } search{id, nullptr};
  EnumChildWindows(parent, [](HWND window, LPARAM parameter) -> BOOL {
    auto &state = *reinterpret_cast<Search *>(parameter);
    if (GetDlgCtrlID(window) == state.id) { state.result = window; return FALSE; }
    return TRUE;
  }, reinterpret_cast<LPARAM>(&search));
  return search.result;
}

static void Settings(bool expectedDrop, int expectedColor, bool newDrop, int newColor)
{
  PostMessageW(g_App._window, WM_COMMAND, IDM_OPTIONS, 0);
  HWND dialog = nullptr;
  Require(Wait([&] { dialog = FindOptions(); return dialog != nullptr; }), "options dialog opens");
  SendMessageW(dialog, PSM_SETCURSEL, 4, 0);
  HWND checkbox = nullptr;
  Require(Wait([&] { checkbox = FindControl(dialog, IDX_SETTINGS_OPEN_7Z_ON_DROP); return checkbox != nullptr; }), "drop option is on Settings page");
  HWND combo = FindControl(dialog, IDC_COLOR_MODE);
  Require(combo && IsWindowEnabled(combo), "color mode is configurable even with palette INI");
  wchar_t caption[256];
  GetWindowTextW(checkbox, caption, 256);
  Require(wcscmp(caption, L"7zアーカイブをドロップすると編集用に開く(&D)") == 0, "drop option is displayed in Japanese");
  GetWindowTextW(FindControl(dialog, IDT_COLOR_MODE), caption, 256);
  Require(wcscmp(caption, L"配色(&C):") == 0, "color label is displayed in Japanese");
  SendMessageW(combo, CB_GETLBTEXT, 0, reinterpret_cast<LPARAM>(caption));
  Require(wcscmp(caption, L"標準（本家と同じ）") == 0, "standard choice is displayed in Japanese");
  SendMessageW(combo, CB_GETLBTEXT, 1, reinterpret_cast<LPARAM>(caption));
  Require(wcscmp(caption, L"ダーク") == 0, "dark choice is displayed in Japanese");
  SendMessageW(combo, CB_GETLBTEXT, 2, reinterpret_cast<LPARAM>(caption));
  Require(wcscmp(caption, L"Windowsの設定に従う") == 0, "system choice is displayed in Japanese");
  Require((SendMessageW(checkbox, BM_GETCHECK, 0, 0) == BST_CHECKED) == expectedDrop, "saved drop setting is displayed");
  Require(SendMessageW(combo, CB_GETCURSEL, 0, 0) == expectedColor, "saved color setting is displayed");
  if (newDrop != expectedDrop) SendMessageW(checkbox, BM_CLICK, 0, 0);
  if (newColor != expectedColor)
  {
    SendMessageW(combo, CB_SETCURSEL, newColor, 0);
    SendMessageW(GetParent(combo), WM_COMMAND, MAKEWPARAM(IDC_COLOR_MODE, CBN_SELCHANGE), reinterpret_cast<LPARAM>(combo));
  }
  Require(SendMessageW(dialog, PSM_APPLY, 0, 0) != FALSE, "Apply accepts both settings");
  CFmSettings settings; settings.Load();
  Require(settings.Open7zOnDrop == newDrop && Read_ClrMode() == static_cast<UInt32>(newColor), "Apply persists both settings");
  Require(dmlib::isEnabled() == (newColor == 1), "chosen standard or dark theme is active");
  SendMessageW(dialog, WM_COMMAND, IDCANCEL, 0);
  Require(Wait([] { return FindOptions() == nullptr; }), "options dialog closes");
}

static void Drop(const std::vector<std::wstring> &paths, DWORD keys, bool expectedOpen, bool expectedDialog)
{
  actionDone = false;
  PostMessageW(testController, WM_APP + 1, 0, 0);
  Require(Wait([] { return actionDone.load(); }) && SUCCEEDED(dropResult), "test panel resets to filesystem");
  droppedPaths = paths; dragKeys = keys;
  const std::wstring eventName = L"Local\\7zip-gui-proof-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(checks);
  HANDLE proof = CreateEventW(nullptr, TRUE, FALSE, eventName.c_str());
  if (!proof) throw std::runtime_error("Cannot create GUI proof event");
  SetEnvironmentVariableW(L"SEVENZIP_TEST_GUI_EVENT", eventName.c_str());
  actionDone = false;
  PostMessageW(testController, WM_APP + 2, 0, 0);
  bool sawDialog = false;
  bool unexpectedDialog = false;
  bool sawMenu = false;
  const bool finished = Wait([&] {
    EnumThreadWindows(uiThread, [](HWND window, LPARAM parameter) -> BOOL {
      wchar_t name[64]; GetClassNameW(window, name, 64);
      if (wcscmp(name, L"#32770") == 0)
      { *reinterpret_cast<bool *>(parameter) = true; PostMessageW(window, WM_COMMAND, IDOK, 0); }
      return TRUE;
    }, reinterpret_cast<LPARAM>(&unexpectedDialog));
    GUITHREADINFO info{sizeof(info)};
    if (GetGUIThreadInfo(uiThread, &info) && (info.flags & GUI_POPUPMENUMODE))
    { sawMenu = true; PostMessageW(g_App._window, WM_CANCELMODE, 0, 0); }
    sawDialog = WaitForSingleObject(proof, 0) == WAIT_OBJECT_0;
    return actionDone.load() && (!expectedDialog || sawDialog);
  });
  CloseHandle(proof);
  Require(finished, "OLE drag-and-drop finishes");
  Require(!unexpectedDialog, "drop does not show an error dialog");
  Require(openedArchive == expectedOpen, expectedOpen ? "single .7z opens internally" : "native drop behavior is preserved");
  if (expectedOpen)
  {
    Require(SUCCEEDED(dropResult) && editableArchive, "opened archive supports editing");
    Require(returnedEffect == DROPEFFECT_COPY, "opening never reports MOVE to source");
  }
  if (expectedDialog) Require(sawDialog, "native compression dialog is preserved");
  if (keys & MK_RBUTTON) Require(sawMenu, "right-drag context menu is preserved");
}

int main(int argc, char **)
{
  wchar_t root[512], directory[2048], stageText[16];
  if (argc != 2 || !GetEnvironmentVariableW(L"SEVENZIP_TEST_REGROOT", root, 512)
      || !GetEnvironmentVariableW(L"SEVENZIP_TEST_FIXTURES", directory, 2048)
      || !GetEnvironmentVariableW(L"SEVENZIP_TEST_STAGE", stageText, 16)) return 2;
  fixtureDir = directory;
  HKEY key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, root, 0, nullptr, 0, KEY_ALL_ACCESS, nullptr, &key, nullptr) != ERROR_SUCCESS) return 3;
  if (RegOverridePredefKey(HKEY_CURRENT_USER, key) != ERROR_SUCCESS) return 4;
  SaveRegLang(L"ja");
  const std::wstring desktopName = L"7zip-settings-test-" + std::to_wstring(GetCurrentProcessId());
  SetEnvironmentVariableW(L"SEVENZIP_TEST_DESKTOP", desktopName.c_str());
  testDesktop = CreateDesktopW(desktopName.c_str(), nullptr, nullptr, 0, GENERIC_ALL, nullptr);
  if (!testDesktop || !SetThreadDesktop(testDesktop)) return 5;
  uiThread = GetCurrentThreadId();
  WNDCLASSW windowClass{};
  windowClass.lpfnWndProc = Controller; windowClass.hInstance = GetModuleHandleW(nullptr); windowClass.lpszClassName = L"7zipSettingsTestController";
  RegisterClassW(&windowClass);
  testController = CreateWindowW(windowClass.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, windowClass.hInstance, nullptr);
  const int stage = _wtoi(stageText);
  std::thread worker([stage] {
    SetThreadDesktop(testDesktop);
    try
    {
      Require(Wait([] { return g_App._window && g_App._dropTarget && g_App.GetFocusedPanel().PanelCreated; }), "file manager starts on isolated desktop");
      if (stage == 1)
      {
        Settings(false, 0, true, 1);
        Drop({fixtureDir + L"\\sample.7z"}, MK_LBUTTON, true, false);
        Drop({fixtureDir + L"\\sample.7Z"}, MK_LBUTTON | MK_SHIFT, true, false);
        Drop({fixtureDir + L"\\sample.7z", fixtureDir + L"\\sample.7Z"}, MK_LBUTTON, false, true);
        Drop({fixtureDir + L"\\plain.txt"}, MK_LBUTTON, false, true);
        Drop({fixtureDir + L"\\folder.7z"}, MK_LBUTTON, false, true);
        Drop({fixtureDir + L"\\sample.7z"}, MK_RBUTTON, false, false);
      }
      else if (stage == 2)
      {
        Settings(true, 1, false, 0);
        Drop({fixtureDir + L"\\sample.7z"}, MK_LBUTTON, false, true);
      }
      else Settings(false, 0, false, 0);
    }
    catch (const std::exception &error)
    { std::fprintf(stderr, "FAIL %s\n", error.what()); failures = 1; }
    PostMessageW(g_App._window, WM_CLOSE, 0, 0);
  });
  const int applicationResult = ProductWinMain(GetModuleHandleW(nullptr), nullptr, nullptr, SW_SHOW);
  worker.join();
  DestroyWindow(testController);
  RegOverridePredefKey(HKEY_CURRENT_USER, nullptr);
  RegCloseKey(key);
  std::printf("RESULT stage=%d checks=%u failures=%d app=%d\n", stage, checks, failures, applicationResult);
  return failures || applicationResult;
}
