param(
  [Parameter(Mandatory)][string]$RuntimeDirectory,
  [string]$OutputDirectory = (Join-Path $PSScriptRoot 'x64-settings-bin')
)
$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
$runtime = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
$versionHeader = [IO.File]::ReadAllText((Join-Path $source 'C/7zVersion.h'))
$version = [regex]::Match($versionHeader, '#define MY_VERSION_NUMBERS "([^"]+)"').Groups[1].Value
if ((Get-Item -LiteralPath (Join-Path $runtime '7z.dll')).VersionInfo.FileVersion -ne $version) { throw "The runtime must be official 7-Zip $version" }
if (Test-Path -LiteralPath $output) { throw "Choose a new output directory: $output" }
if ($output.StartsWith($runtime.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Output must be outside the input runtime directory' }
Get-Command cl.exe,nmake.exe,rc.exe,link.exe -ErrorAction Stop | Out-Null
$logs = Join-Path $source 'tests/windows/out'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$libraryHeader = Join-Path $source 'DarkMode/lib/src/StdAfx.h'
if (!(Test-Path -LiteralPath $libraryHeader)) { throw 'Initialize the DarkMode/lib submodule first' }
$savedHeader = [IO.File]::ReadAllBytes($libraryHeader)
$savedPlatform = $env:PLATFORM
try {
  $env:PLATFORM = 'x64'
  Copy-Item -LiteralPath (Join-Path $source 'DarkMode/7zRes/StdAfx.h') -Destination $libraryHeader -Force
  foreach ($module in 'FileManager','GUI') {
    Push-Location (Join-Path $source "CPP/7zip/UI/$module")
    try {
      $log = Join-Path $logs "build-$module.log"
      & nmake.exe *> $log
      if ($LASTEXITCODE) { throw "$module build failed; see $log" }
    } finally { Pop-Location }
  }
} finally {
  [IO.File]::WriteAllBytes($libraryHeader, $savedHeader)
  $env:PLATFORM = $savedPlatform
}
New-Item -ItemType Directory -Path $output | Out-Null
Get-ChildItem -LiteralPath $runtime | Copy-Item -Destination $output -Recurse
Copy-Item -LiteralPath (Join-Path $source 'CPP/7zip/UI/FileManager/x64/7zFM.exe') -Destination $output -Force
Copy-Item -LiteralPath (Join-Path $source 'CPP/7zip/UI/GUI/x64/7zG.exe') -Destination $output -Force
foreach ($translation in Get-ChildItem -LiteralPath (Join-Path $source 'DarkMode/Lang') -Filter '*.txt') {
  $destination = Join-Path $output ('Lang/' + $translation.Name)
  if (Test-Path -LiteralPath $destination) {
    $text = [IO.File]::ReadAllText($destination)
    $text = $text.Insert($text.IndexOf("`n") + 1, "; Modified 2026-11-15: additional appearance and archive drop settings.`r`n")
    $addition = [IO.File]::ReadAllText($translation.FullName).TrimEnd() + "`r`n"
    $firstId = [uint32][regex]::Match($addition, '(?m)^\d+\r?$').Value.Trim()
    $next = [regex]::Matches($text, '(?m)^\d+\r?$') | Where-Object { [uint32]$_.Value.Trim() -gt $firstId } | Select-Object -First 1
    if ($next) { $text = $text.Insert($next.Index, $addition) } else { $text += "`r`n" + $addition }
    [IO.File]::WriteAllText($destination, $text, [Text.UTF8Encoding]::new($false))
  }
}
Copy-Item -LiteralPath (Join-Path $source 'DarkMode/lib/LICENSE.md') -Destination (Join-Path $output 'Darkmodelib-LICENSE.md')
Copy-Item -LiteralPath (Join-Path $source 'DarkMode/lib/LICENSE-MIT.md') -Destination (Join-Path $output 'Darkmodelib-LICENSE-MIT.md')
Write-Output "Built 7-Zip $version x64: $output"

Copy-Item -LiteralPath (Join-Path $source 'LICENSING.md') -Destination $output
Copy-Item -LiteralPath (Join-Path $source 'Licenses') -Destination $output -Recurse
foreach ($name in 'LICENSE-PolyHook_2_0.md','LICENSE-UAHMenuBar.md','LICENSE-win32-darkmode.md') {
  Copy-Item -LiteralPath (Join-Path $source ('DarkMode/lib/docs/' + $name)) -Destination (Join-Path $output 'Licenses')
}
New-Item -ItemType Directory -Path (Join-Path $output 'Source') | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open((Join-Path $output 'Source/7zip-26.06-settings-source.zip'), [IO.Compression.ZipArchiveMode]::Create)
try {
  foreach ($file in [IO.Directory]::EnumerateFiles($source, '*', [IO.SearchOption]::AllDirectories)) {
    if ($file.StartsWith($output.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
    $relative = $file.Substring($source.Length + 1).Replace('\','/')
    if ($relative -match '(^|/)\.git(/|$)|^tests/windows/out/|^DarkMode/7zRes/Icons/') { continue }
    if ([IO.Path]::GetExtension($file).ToLowerInvariant() -in '.obj','.o','.pch','.pdb','.exe','.dll','.lib','.exp','.res','.rsp','.log') { continue }
    if ($relative -notmatch '^(Asm|C|CPP|DOC|DarkMode|Licenses|tests)/' -and $relative -notin 'README.md','LICENSE.md','LICENSING.md','build-custom.ps1','.gitattributes','.gitignore') { continue }
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file, ('7zip-26.06-settings/' + $relative), [IO.Compression.CompressionLevel]::Optimal) | Out-Null
  }
} finally { $archive.Dispose() }
