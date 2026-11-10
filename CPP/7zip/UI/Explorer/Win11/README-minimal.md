# 7-Zip 26.06: Windows 11 modern context-menu extension

This is an intentionally small variant of SourceForge patch #474.
It keeps the Explorer COM code and sparse package manifest, but does not
change the 7-Zip File Manager settings or run PowerShell from 7-Zip.

## Build

1. Build 7-Zip x64 with the existing 7-Zip makefiles in an x64 MSVC shell.
2. Put the **patched** `7-zip.dll` and matching `7zFM.exe` in the
   externally installed 7-Zip directory (for example `C:\Program Files\7-Zip`).
3. Copy `AppxManifest.xml` and the whole `Assets` directory into a separate
   package-staging directory, preserving the relative paths.
4. Set the Publisher in the manifest to your signing certificate's Subject
   for a signed build. For unsigned Windows 11 development testing, the
   included special Publisher OID supports `Add-AppxPackage -AllowUnsigned`.
5. Create the sparse package (run from a Windows SDK tools prompt):

   `MakeAppx.exe pack /d C:\7zip-msix-stage /p C:\7-zip-shell.msix /o`

6. For a signed release, sign the MSIX using the matching trusted certificate
   and `SignTool.exe` (publisher and signing certificate MUST match).

## Register / unregister for CURRENT USER

The installed directory is the *external location*. This is not the folder
that contains the MSIX manifest and graphics.

For unsigned development on Windows 11:

```powershell
Add-AppxPackage -Path 'C:\7-zip-shell.msix' `
    -ExternalLocation 'C:\Program Files\7-Zip' -AllowUnsigned
```

For signed releases omit `-AllowUnsigned`; ensure signer trust instead.

```powershell
Get-AppxPackage -Name '7zip.ContextMenu' | Remove-AppxPackage
```

To integrate into an EXE/MSI installer, perform the same package registration
and removal at install and uninstall time. Package registration is per user;
all-user deployments need explicit user provisioning handling.

## Notes

* The modern COM CLSID is `{23170F69-40C1-278A-1000-000100030000}`.
* The classic context menu is **not** disabled automatically by this minimal
  patch. The modern entry may be repeated in "Show more options" alongside the
  old `IContextMenu` entry. The installer can manage classic context-menu
  registration (separately from drag-and-drop), or the user can disable the
  classic integration in 7-Zip options. Do not remove classic registration
  blindly if you need classic drag/drop or Windows 10 support.
* The package version is set to `26.6.0.0`; increment it on package updates.
* The original patch's PowerShell scripts and Win11Menu UI option are removed.
* Build/test on Windows 11 x64 before distribution; `git apply` success is not
  proof of COM activation or a successful production build.
