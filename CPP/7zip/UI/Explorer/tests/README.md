# Timestamped folder backups

The new single-folder command creates `Folder-YYYY-MM-DD-HH-mm.7z` beside
the selected folder, using local time when the menu is built. It reuses
7-Zip's GUI compression settings and update engine. Existing archives are
never used as input: `-an -u- -u!<output>` selects the engine's exclusive
new-file creation path, so repeat or concurrent requests cannot update a
previous backup. Choose a new minute to create another backup.

The command is in the existing 7-Zip submenu. It is hidden for files,
multiple selections, drag-and-drop menus, and classic menus with cascading
disabled. The modern `IExplorerCommand` submenu remains supported.

Build with MinGW-w64 in WSL, from `CPP/7zip/UI/Explorer`:

```sh
make -f makefile.gcc -j4
x86_64-w64-mingw32-g++ -O2 -Wall -Wextra -Wno-cast-function-type \
  -municode -static tests/ContextMenuTest.cpp -o _o/ContextMenuTest.exe \
  -lole32 -lshell32 -luuid
```

Run on Windows, from the same directory, with a matching 64-bit 7-Zip installed:

```powershell
.\tests\Test-TimestampBackup.ps1 -TestExe .\_o\ContextMenuTest.exe
```

The test uses a temporary copy of the DLL and GUI, checks both shell APIs,
and validates the created archives, existing-file protection, and concurrent
creation. It temporarily changes `CascadedMenu`, restores it in `finally`,
and leaves sample files in its reported temporary directory for inspection.
