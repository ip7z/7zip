# Run from an x64 Visual Studio developer shell after building 7zG.exe.
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskOutput = Join-Path $taskRoot '.validation'
New-Item -ItemType Directory -Force -Path $taskOutput | Out-Null
$taskObjectDir = Join-Path $taskRoot 'CPP/7zip/UI/GUI/x64'
$taskObjects = @('ZipRegistry', 'MyString', 'MyVector', 'StringToInt', 'IntToString',
    'Registry', 'Synchronization', 'StdAfx', 'Threads') | ForEach-Object {
    Join-Path $taskObjectDir ($_ + '.obj')
}
$taskSource = Join-Path $PSScriptRoot 'test_directory_time_config.cpp'
$taskExe = Join-Path $taskOutput 'test_directory_time_config.exe'
$taskObj = Join-Path $taskOutput 'test_directory_time_config.obj'
& cl /nologo /MT /EHsc /Gy /GR- /Gr /Zc:wchar_t "/Fo$taskObj" $taskSource "/Fe$taskExe" @taskObjects /link /OPT:REF oleaut32.lib ole32.lib user32.lib advapi32.lib shell32.lib
if ($LASTEXITCODE -ne 0) { throw 'Configuration test build failed' }
& $taskExe
if ($LASTEXITCODE -ne 0) { throw 'Configuration test failed' }
