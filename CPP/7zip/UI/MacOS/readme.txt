7-Zip GUI for macOS
-------------------

This folder contains the source code of 7-Zip.app: the graphical
user interface of 7-Zip for macOS. It's similar to 7-Zip File Manager (7zFM.exe)
and 7-Zip GUI (7zG.exe) from Windows version, and it uses the same
7-Zip engine code (UI/Common, Archive, Compress, Crypto) as 7zz console version.


Features
--------

  - File manager window: folders and archives are shown in one list,
    like in 7-Zip File Manager. Toolbar: Add, Extract, Test, Delete, Info.
  - Archive browsing: archives (and archives inside archives) are opened as folders.
  - Add to Archive dialog (same options as Windows version):
      format, level, method, dictionary, word size, solid block size, threads,
      update mode, path mode, split to volumes, parameters,
      password, encryption method, encrypt file names.
  - Extract dialog: output folder, path mode, overwrite mode,
    eliminate duplication of root folder, password.
  - Progress window: elapsed / remaining time, speed, ratio, files,
    Pause / Cancel, list of errors.
  - Overwrite and password dialogs.
  - Operations inside archive: add files (also to subfolder), delete, rename,
    test, extract selected items, open files, drag files from archive to Finder.
  - Properties of archives and items.
  - Finder integration (Services menu / Quick Actions):
      Add to Archive..., Compress to .7z, Compress to .zip,
      Open Archive, Extract Files..., Extract Here, Extract to Folder, Test Archive.
  - Translations: the same Lang/*.txt files as in Windows version are used.


Build
-----

Requirements: macOS 11 or later, Xcode Command Line Tools (clang, make).
Xcode project is not required.

  cd CPP/7zip/Bundles/MacGUI

  make -j -f ../../cmpl_mac_arm64.mak     ->  b/m_arm64/7-Zip.app  (Apple silicon)
  make -j -f ../../cmpl_mac_x64.mak       ->  b/m_x64/7-Zip.app    (Intel)
  ./build_app.sh                          ->  b/m_universal/7-Zip.app (arm64 + x86_64)
  ./build_app.sh dmg                      ->  also b/7-Zip-<version>-mac.dmg

The version in Info.plist is taken from C/7zVersion.h.

Lang files are copied from the folder ../../../../Lang (or from LANG_DIR variable)
to 7-Zip.app/Contents/Resources/Lang, if that folder exists.
It can be "Lang" folder from 7-Zip for Windows package.

Code signing: build_app.sh signs the application with ad-hoc signature.
For distribution, set CODESIGN_IDENTITY ("Developer ID Application: ...")
and then notarize the dmg file (xcrun notarytool submit ... ; xcrun stapler staple ...).


Architecture
------------

The code has two layers:

1) MacEngine.cpp / MacEngine.h (C++)

   The connection between the GUI and UI/Common code.
   It's compiled with same strict warning options as other 7-Zip code (-Weverything).
   MacEngine.h doesn't include 7-Zip or Cocoa headers, because both
   define some conflicting types (BOOL). All strings in MacEngine.h are UTF-8.

   The engine works like 7zG.exe in Windows:
   the GUI creates a command line in usual 7-Zip syntax:

     a -t7z -mx=5 -m0=LZMA2 -p... -spd -- archive.7z file1 file2
     x -o/output/dir/ -aoa -spd -an -ai!archive.7z
     d -spd -- archive.7z dir/file.txt
     rn -spd -- archive.7z old/path new/path

   RunCommand() parses that command line with CArcCmdLineParser
   and calls Extract() or UpdateArchive() from UI/Common.
   So the GUI doesn't duplicate the logic of 7-Zip commands and switches,
   and new switches of 7-Zip can be used in GUI without changes in MacEngine.cpp.

   For archive browsing, OpenArchive() opens archive with CArchiveLink
   and IArchive::Extract() extracts selected items with CArchiveExtractCallback
   (like CAgentFolder::Extract() in UI/Agent).

   Callbacks:
     CExtractCallbackMac  : IFolderArchiveExtractCallback, IExtractCallbackUI
                            (like CExtractCallbackConsole)
     CUpdateCallbackMac   : IUpdateCallbackUI2 (like CUpdateCallbackGUI)
     COpenCallbackMac     : IOpenCallbackUI
   They call NMacEngine::IUserCallback, that is implemented by the GUI.

2) Cocoa GUI (Objective-C++ with ARC, *.mm files)

   main.mm                  application entry point
   AppDelegate.mm           menus, Finder services, About, Options
   SZBrowserController.mm   main window (file manager)
   SZCompressController.mm  "Add to Archive" dialog (similar to GUI/CompressDialog.cpp)
   SZExtractController.mm   "Extract" dialog (similar to GUI/ExtractDialog.cpp)
   SZProgressController.mm  progress window (similar to FileManager/ProgressDialog2.cpp)
   SZPrompts.mm             password, overwrite and other questions
   SZPropertiesController.mm properties window
   SZCommands.mm            commands that are used by browser and by Finder services
   SZEngine.mm              Objective-C wrappers: operation state, archive tree
   SZLang.mm, SZLangIDs.h   lang files support
   SZUtils.mm               small helpers

   The user interface is created in code (no .xib / .storyboard files),
   so only clang is required to build it.

   All operations are executed in a worker thread. The engine writes progress
   values to SZOperation object, and the progress window reads them with timer
   (like CProgressSync in Windows version). Questions to user (password, overwrite)
   are sent to main thread, and the worker thread waits for the answer.

Resources:
   Resources/Info.plist        bundle information, document types, Finder services
   Resources/AppIcon.icns      application icon
   Resources/ArchiveIcon.icns  icon for archive files
   Resources/make_icons.swift  the script that creates icns files


Lang strings
------------

SZLang(id, "English text") returns the string with same ID from lang file.
The IDs in SZLangIDs.h are same as the IDs in Windows resource files:
  FileManager/resource.h, GUI/*Res.h, FileManager/*Res.h, Explorer/resource.h.
So the existing translations of 7-Zip for Windows are used.
The strings that don't exist in Windows version are shown in English.


Notes for maintenance
---------------------

  - If new source files are added to UI/Common (or other engine folders),
    add them to Bundles/MacGUI/makefile.gcc (same lists as in Bundles/Alone2/makefile.gcc).
  - If the interfaces IFolderArchiveExtractCallback, IExtractCallbackUI,
    IUpdateCallbackUI2, IOpenCallbackUI are changed, update MacEngine.cpp.
    It's same work as for Console/*Callback*.cpp files.
  - New compression methods / formats for "Add to Archive" dialog:
    g_Formats[] table in SZCompressController.mm (same as in GUI/CompressDialog.cpp).
  - New strings: add ID to SZLangIDs.h, if the string exists in Windows resources.
  - Minimal macOS version: MACOS_MIN_VERSION in Bundles/MacGUI/makefile.gcc.
