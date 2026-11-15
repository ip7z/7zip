Build the File Manager and GUI with MSVC 2022 17.9 or newer and a Windows SDK, using an x64 developer shell. Initialize the DarkMode/lib submodule first when using a submodule-based checkout.

```powershell
.\build-custom.ps1 -RuntimeDirectory C:\path\to\official-26.06 -OutputDirectory C:\path\to\new-output
.\tests\windows\run.ps1 -RuntimeDirectory C:\path\to\new-output
```

The test executables reuse the production File Manager and GUI objects and entry points, with test controllers linked in. They invoke the actual Options dialog and OLE IDropTarget methods. The compression helper must expose its archive, format and compression-level controls with the expected theme before signaling success; a generic error dialog cannot satisfy that check. Both processes use a separate desktop that is never switched onto the screen and redirect HKEY_CURRENT_USER to a temporary test key. Existing 7-Zip settings and open windows are not used. The launcher deletes the temporary registry key afterward.

Coverage includes clean defaults, Apply and persistence across three processes, standard and dark themes, the color selector with an INI file present, single .7z opening with editing operations available, an uppercase extension, Shift-drop returning COPY, native behavior for multiple files and other extensions, directories named .7z, right-drag menus, disabling the option, and the source archive remaining byte-for-byte unchanged. All archive fixtures stay under tests/windows/out.

The language additions in DarkMode/Lang are supplements merged into the corresponding official language files in ascending numeric ID order by build-custom.ps1. The tests explicitly select Japanese and check the actual checkbox, color label and all three color choices. Other languages use the English resource strings until translated.
