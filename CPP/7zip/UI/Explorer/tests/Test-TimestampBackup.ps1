param(
    [Parameter(Mandatory = $true)][string]$TestExe,
    [string]$Dll = (Join-Path $PSScriptRoot '..\_o\7-zip.dll'),
    [string]$SevenZip = 'C:\Program Files\7-Zip'
)
$ErrorActionPreference = 'Stop'
$TestExe = (Resolve-Path -LiteralPath $TestExe).Path
$Dll = (Resolve-Path -LiteralPath $Dll).Path
$work = Join-Path $env:TEMP ('7zip-backup-test-' + [Guid]::NewGuid().ToString('N'))
$bin = New-Item -ItemType Directory -Path (Join-Path $work 'bin')
$folder = New-Item -ItemType Directory -Path (Join-Path $work ('Sample & caf' + [char]0xE9))
$file = Join-Path $folder.FullName 'hello.txt'
Set-Content -LiteralPath $file -Value 'Timestamp backup test'
Copy-Item -LiteralPath $Dll -Destination (Join-Path $bin.FullName '7-zip.dll')
foreach ($name in @('7zG.exe', '7z.dll')) {
    Copy-Item -LiteralPath (Join-Path $SevenZip $name) -Destination $bin.FullName
}
$testDll = Join-Path $bin.FullName '7-zip.dll'
$cli = Join-Path $SevenZip '7z.exe'
$options = 'HKCU:\Software\7-Zip\Options'
$hadOptions = Test-Path -LiteralPath $options
$oldCascade = if ($hadOptions) { (Get-Item -LiteralPath $options).GetValue('CascadedMenu') } else { $null }

function Test-Menu([string]$Path, [string]$Mode) {
    & $TestExe $testDll $Path $Mode
    if ($LASTEXITCODE -ne 0) { throw "Menu test failed: $Mode" }
}
function Test-Archive([string]$Path) {
    & $cli t $Path | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Invalid archive: $Path" }
}
try {
    if (!$hadOptions) { New-Item -Path $options -Force | Out-Null }
    New-ItemProperty -LiteralPath $options -Name CascadedMenu -Value 1 -PropertyType DWord -Force | Out-Null
    Test-Menu $folder.FullName present
    Test-Menu $file absent
    Test-Menu $folder.FullName multiple
    Test-Menu $folder.FullName drag
    New-ItemProperty -LiteralPath $options -Name CascadedMenu -Value 0 -PropertyType DWord -Force | Out-Null
    Test-Menu $folder.FullName flat
    New-ItemProperty -LiteralPath $options -Name CascadedMenu -Value 1 -PropertyType DWord -Force | Out-Null
    Test-Menu $folder.FullName invoke
    $archive = $null
    for ($i = 0; $i -lt 100; ++$i) {
        $archive = Get-ChildItem -LiteralPath $work -Filter ($folder.Name + '-*.7z') | Select-Object -First 1
        if ($archive) {
            & $cli t $archive.FullName *> $null
            if ($LASTEXITCODE -eq 0) { break }
        }
        Start-Sleep -Milliseconds 100
    }
    if (!$archive -or $LASTEXITCODE -ne 0) { throw 'Timestamped archive was not created successfully.' }
    if ($archive.Name -notmatch ('^' + [regex]::Escape($folder.Name) + '-\d{4}-\d{2}-\d{2}-\d{2}-\d{2}\.7z$')) { throw 'Incorrect backup filename.' }
    Test-Menu $folder.FullName stock
    $stock = Join-Path $work ($folder.Name + '.7z')
    for ($i = 0; $i -lt 100; ++$i) {
        if (Test-Path -LiteralPath $stock) {
            & $cli t $stock *> $null
            if ($LASTEXITCODE -eq 0) { break }
        }
        Start-Sleep -Milliseconds 100
    }
    Test-Archive $stock

    $modernFolder = New-Item -ItemType Directory -Path (Join-Path $work 'Modern folder')
    Copy-Item -LiteralPath $file -Destination $modernFolder.FullName
    Test-Menu $modernFolder.FullName moderninvoke
    $modernArchive = $null
    for ($i = 0; $i -lt 100; ++$i) {
        $modernArchive = Get-ChildItem -LiteralPath $work -Filter 'Modern folder-*.7z' | Select-Object -First 1
        if ($modernArchive) {
            & $cli t $modernArchive.FullName *> $null
            if ($LASTEXITCODE -eq 0) { break }
        }
        Start-Sleep -Milliseconds 100
    }
    if (!$modernArchive -or $LASTEXITCODE -ne 0) { throw 'Modern command did not create a valid archive.' }

    # Same CREATE_NEW path as the GUI, without opening error dialogs.
    $hash = (Get-FileHash -LiteralPath $archive.FullName).Hash
    & $cli a -t7z -an -u- "-u!$($archive.FullName)" -- $file *> $null
    if ($LASTEXITCODE -eq 0) { throw 'Existing backup was accepted.' }
    if ((Get-FileHash -LiteralPath $archive.FullName).Hash -ne $hash) { throw 'Existing backup was modified.' }
    $race = Join-Path $work 'concurrent.7z'
    $arguments = 'a -t7z -an -u- -u!"' + $race + '" -- "' + $file + '"'
    $first = Start-Process -FilePath $cli -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $second = Start-Process -FilePath $cli -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $first.WaitForExit(); $second.WaitForExit()
    if (($first.ExitCode -eq 0) -eq ($second.ExitCode -eq 0)) { throw 'Concurrent writers did not produce exactly one success.' }
    Test-Archive $race
    Write-Output "PASS: classic and modern menus, visibility, stock compression, archive integrity, and collision protection. Test files: $work"
} finally {
    if ($null -ne $oldCascade) {
        New-ItemProperty -LiteralPath $options -Name CascadedMenu -Value $oldCascade -PropertyType DWord -Force | Out-Null
    } else {
        Remove-ItemProperty -LiteralPath $options -Name CascadedMenu -ErrorAction SilentlyContinue
    }
    if (!$hadOptions -and (Get-Item -LiteralPath $options).ValueCount -eq 0 -and (Get-Item -LiteralPath $options).SubKeyCount -eq 0) {
        Remove-Item -LiteralPath $options
    }
}
