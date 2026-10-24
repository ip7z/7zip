# Directory timestamps during extraction

Set the persistent GUI default in **Tools > Options > Settings > Use current
timestamps for directories**, then click **Apply** or **OK**. It is initially off
and is saved per user as the DWORD `UseCurrentDirTimes` under
`HKEY_CURRENT_USER\Software\7-Zip\Extraction` (0 = off, 1 = on).

GUI extraction operations, including extraction without a dialog and File Manager
copy-out operations, read this default. The extraction dialog also includes the
same checkbox as an override for that operation; changing that checkbox does not
change the persistent configuration. Explicit `-sctd` and `-sctd-` switches override
the saved default in the GUI command line. Console applications keep their own
default of off and use the explicit switches.

Both controls share a localization ID and fall back to the English resource label
when the language file has no translation. Command-line usage:

```powershell
.\CPP\7zip\Bundles\Alone2\x64\7zz.exe x archive.7z -ooutput -sctd
```

`-sctd-` explicitly disables it. With no saved preference and no switch, the
original behavior is preserved.

With the option enabled, directories successfully created during extraction get
the system's current modification time after archive contents and delayed links
have been extracted. This includes nested and empty directories, implicit parent
directories absent from the archive, and newly created output path components.
Creation tracking spans all archives in a single extraction operation. Existing
directories retain the original extraction behavior: an explicit directory entry
can restore its archived timestamps. Files, their timestamps, permissions, and
attributes follow the original code paths. Archive directory access/creation times
also keep the original behavior; only modification time is overridden.

Filesystem timestamps use the existing UTC time API, which represents the current
instant correctly and displays in local system time without adding a timezone
offset. A tracked path replaced by a file or symbolic link is excluded from the
new timestamp pass.

## Implementation

- `CPP/7zip/UI/Common/ArchiveExtractCallback.h`: default-off option in
  `CExtractNtOptions`, plus directory creation tracking scoped to an operation.
- `CPP/7zip/UI/Common/ArchiveExtractCallback.cpp`: record successful directory
  creation; apply current modification time after the existing final timestamp
  pass, without changing archived creation/access times or file handling.
- `CPP/7zip/UI/Common/Extract.cpp`: track newly created output path components.
- `CPP/7zip/UI/Common/ArchiveCommandLine.cpp`: parse `-sctd[-]`.
- `CPP/7zip/UI/Console/Main.cpp`: document the switch in console help.
- `CPP/7zip/UI/GUI/ExtractDialog.h`, `ExtractDialog.cpp`, `ExtractDialog.rc`,
  `ExtractDialogRes.h`, and `ExtractGUI.cpp`: checkbox and option plumbing.
- `CPP/7zip/UI/Common/ZipRegistry.h` and `ZipRegistry.cpp`: persistent GUI
  configuration and explicit-option precedence.
- `CPP/7zip/UI/FileManager/SettingsPage.cpp`, `SettingsPage.h`,
  `SettingsPage2.rc`, and `SettingsPageRes.h`: configuration control.
- `CPP/7zip/UI/Agent/Agent.cpp`: apply the default to File Manager copy-out.
- `tests/test_current_dir_times.py`: standard-library integration tests.
- `tests/test_directory_time_config.cpp` and `test_directory_time_config.ps1`:
  isolated Windows registry persistence and precedence test.

## Exact build commands

Run from the repository root in PowerShell. These commands use the installed
Visual Studio 2022 Community x64 toolchain. `/A` forces recompilation, including
all consumers of the changed headers. Each build must exit with code 0.

```powershell
Push-Location CPP\7zip\Bundles\Alone2
cmd /c '"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" && nmake /nologo /A PLATFORM=x64 > build.log 2>&1'
Pop-Location

Push-Location CPP\7zip\UI\GUI
cmd /c '"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" && nmake /nologo /A PLATFORM=x64 > build.log 2>&1'
Pop-Location

Push-Location CPP\7zip\Bundles\Fm
cmd /c '"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" && nmake /nologo /A PLATFORM=x64 > build.log 2>&1'
Pop-Location
```

Outputs are `CPP/7zip/Bundles/Alone2/x64/7zz.exe`,
`CPP/7zip/UI/GUI/x64/7zG.exe`, and `CPP/7zip/Bundles/Fm/x64/7zFM.exe`.
The build logs remain in their respective build directories.

## Exact test command

```powershell
python tests/test_current_dir_times.py --seven-zip CPP/7zip/Bundles/Alone2/x64/7zz.exe -v
```

The suite creates isolated temporary fixtures and extracts real ZIP, TAR, and 7z
archives. It checks archived timestamps from 2001, nested and empty directories,
implicit parents, existing directories, new output parents, multiple archives
sharing directories, default behavior, explicit disable, file content and
modification time preservation, available file access/creation time preservation,
attribute parity (including Windows read-only attributes), flat extraction,
archive testing, stdout extraction, CRC failure finalization, output-path failure,
and skipping existing files without restamping their parent directories.

The 13 integration tests passed on Windows x64 using Python 3.12. Full forced
MSVC 19.44 x64 builds of the three executables above were also validated.
Interactive GUI operation, Windows CE, and non-Windows builds have not been
validated.

## Configuration test

After building the GUI, run from an x64 Visual Studio developer PowerShell:

```powershell
powershell -NoProfile -File tests/test_directory_time_config.ps1
```

The test links the actual registry implementation. It checks the missing-value
(default off) case, saved on/off values, persistence across separate processes,
explicit-option precedence, and isolation from extraction-history saves. It uses
`RegOverridePredefKey` with an isolated temporary HKCU key, cleans it up, and never
changes the user's live 7-Zip configuration. This test passed on Windows x64.
