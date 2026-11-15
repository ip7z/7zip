param([Parameter(Mandatory)][string]$RuntimeDirectory)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$runtime = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$fm = Join-Path $source 'CPP/7zip/UI/FileManager'
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Path $out -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $runtime '7z.dll') -Destination $out -Force
Copy-Item -LiteralPath (Join-Path $runtime 'Lang') -Destination $out -Recurse -Force
[IO.File]::WriteAllText((Join-Path $out '7zDark.ini'), "[main]`r`nmode=1`r`n")
$object = Join-Path $out 'settings-test.obj'
& cl.exe /nologo /c /O2 /EHsc /std:c++20 /utf-8 /MT /DUNICODE /D_UNICODE /DZ7_LANG /DZ7_DEVICE_FILE /DZ7_EXTERNAL_CODECS "/I$fm" "/Fo$object" (Join-Path $PSScriptRoot 'settings-and-drop.cpp')
if ($LASTEXITCODE) { throw 'Integration test compilation failed' }
$arguments = @('/nologo', '/SUBSYSTEM:CONSOLE', '/LTCG', '/INCREMENTAL:NO', '/DELAYLOAD:mpr.dll', ('/OUT:' + (Join-Path $out 'settings-test.exe')), $object)
$arguments += @(Get-ChildItem -LiteralPath (Join-Path $fm 'x64') -Filter '*.obj' | Where-Object Name -ne 'FM.obj' | ForEach-Object FullName)
$arguments += (Join-Path $fm 'x64/resource.res')
$arguments += @('comctl32.lib', 'htmlhelp.lib', 'comdlg32.lib', 'Mpr.lib', 'Gdi32.lib', 'delayimp.lib', 'oleaut32.lib', 'ole32.lib', 'user32.lib', 'advapi32.lib', 'shell32.lib')
$response = Join-Path $out 'link.rsp'
[IO.File]::WriteAllLines($response, @($arguments | ForEach-Object { '"' + $_ + '"' }), [Text.UTF8Encoding]::new($false))
& link.exe ('@' + $response)
if ($LASTEXITCODE) { throw 'Integration test linking failed' }
$gui = Join-Path $source 'CPP/7zip/UI/GUI'
$guiObject = Join-Path $out 'gui-test.obj'
& cl.exe /nologo /c /O2 /EHsc /std:c++20 /utf-8 /MT /DUNICODE /D_UNICODE /DZ7_LANG /DZ7_DEVICE_FILE /DZ7_EXTERNAL_CODECS "/I$gui" "/Fo$guiObject" (Join-Path $PSScriptRoot 'gui-driver.cpp')
if ($LASTEXITCODE) { throw 'GUI test compilation failed' }
$guiArguments = @('/nologo', '/SUBSYSTEM:WINDOWS', '/LTCG', '/INCREMENTAL:NO', ('/OUT:' + (Join-Path $out '7zG.exe')), $guiObject)
$guiArguments += @(Get-ChildItem -LiteralPath (Join-Path $gui 'x64') -Filter '*.obj' | Where-Object Name -ne 'GUI.obj' | ForEach-Object FullName)
$guiArguments += (Join-Path $gui 'x64/resource.res')
$guiArguments += @('comctl32.lib','htmlhelp.lib','comdlg32.lib','gdi32.lib','oleaut32.lib','ole32.lib','user32.lib','advapi32.lib','shell32.lib')
$guiResponse = Join-Path $out 'link-gui.rsp'
[IO.File]::WriteAllLines($guiResponse, @($guiArguments | ForEach-Object { '"' + $_ + '"' }), [Text.UTF8Encoding]::new($false))
& link.exe ('@' + $guiResponse)
if ($LASTEXITCODE) { throw 'GUI test linking failed' }
$fixtures = Join-Path $out 'fixtures'
New-Item -ItemType Directory -Path $fixtures,(Join-Path $fixtures 'folder.7z') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $fixtures 'inside.txt'), 'Archive editing verification fixture')
[IO.File]::WriteAllText((Join-Path $fixtures 'plain.txt'), 'Native drop verification fixture')
Push-Location $fixtures
try {
  & (Join-Path $runtime '7z.exe') a -t7z -mx1 -y 'sample.7z' 'inside.txt' | Out-Null
  if ($LASTEXITCODE) { throw 'Fixture archive creation failed' }
} finally { Pop-Location }
$archiveHash = (Get-FileHash -LiteralPath (Join-Path $fixtures 'sample.7z') -Algorithm SHA256).Hash
$env:SEVENZIP_TEST_REGROOT = 'Software\7zipSettingsTests\' + [Guid]::NewGuid().ToString('N')
$env:SEVENZIP_TEST_FIXTURES = $fixtures
try {
  foreach ($stage in 1..4) {
    $env:SEVENZIP_TEST_STAGE = [string]$stage
    & (Join-Path $out 'settings-test.exe') $fixtures
    if ($LASTEXITCODE) { throw "Integration test stage $stage failed ($LASTEXITCODE)" }
  }
  if ((Get-FileHash -LiteralPath (Join-Path $fixtures 'sample.7z') -Algorithm SHA256).Hash -ne $archiveHash) { throw 'Source archive was changed' }
  Write-Output 'PASS original source archive remains byte-for-byte unchanged'
} finally {
  if ($env:SEVENZIP_TEST_REGROOT -match '^Software\\7zipSettingsTests\\[0-9a-f]{32}$') {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\7zipSettingsTests', $true)
    if ($key) {
      try { $key.DeleteSubKeyTree(($env:SEVENZIP_TEST_REGROOT -split '\\')[-1], $false) } finally { $key.Dispose() }
    }
  }
  Remove-Item Env:SEVENZIP_TEST_REGROOT,Env:SEVENZIP_TEST_FIXTURES,Env:SEVENZIP_TEST_STAGE -ErrorAction SilentlyContinue
}
