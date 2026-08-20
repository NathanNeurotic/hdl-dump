<#
.SYNOPSIS
    Windows Host Regression Test Suite for hdl-dump modify_header and dump_header extraction & roundtrip.
.DESCRIPTION
    Runs integration tests against virtual raw disk fixtures to verify:
    - 128 MiB partition full header asset injection (system.cnf, icon.sys, list.ico, del.ico)
    - 128 MiB partition file extraction via dump_header with SHA-256 validation
    - 8 MiB partition full header asset injection and dump_header extraction with SHA-256 validation
    - Sparse header asset injection (missing/skipped entries) and clean extraction
#>
param(
    [string]$HdlDump = "",
    [string]$Pfsshell = ""
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Resolve hdl_dump binary
if ([string]::IsNullOrWhiteSpace($HdlDump)) {
    if (Test-Path (Join-Path $ScriptDir "hdl_dump.exe")) {
        $HdlDumpExe = (Resolve-Path (Join-Path $ScriptDir "hdl_dump.exe")).Path
    } elseif (Test-Path (Join-Path $ScriptDir "ci_artifact_final\rel\hdl_dump.exe")) {
        $HdlDumpExe = (Resolve-Path (Join-Path $ScriptDir "ci_artifact_final\rel\hdl_dump.exe")).Path
    } elseif (Test-Path (Join-Path $ScriptDir "ci_artifact\rel\hdl_dump.exe")) {
        $HdlDumpExe = (Resolve-Path (Join-Path $ScriptDir "ci_artifact\rel\hdl_dump.exe")).Path
    } else {
        $HdlDumpCmd = Get-Command "hdl_dump.exe" -ErrorAction SilentlyContinue
        if ($HdlDumpCmd) { $HdlDumpExe = $HdlDumpCmd.Source } else { $HdlDumpExe = Join-Path $ScriptDir "hdl_dump.exe" }
    }
} else {
    $HdlDumpExe = (Resolve-Path $HdlDump).Path
}

# Resolve pfsshell binary
if ([string]::IsNullOrWhiteSpace($Pfsshell)) {
    $candidatePfsshell = @(
        (Join-Path $ScriptDir "..\pfsshell\build-win32\pfsshell.exe"),
        (Join-Path $ScriptDir "..\PFS-BatchKit-Manager\PFS-BatchKit-Manager\BAT\pfsshell.exe")
    )
    foreach ($cand in $candidatePfsshell) {
        if (Test-Path $cand) {
            $PfsshellExe = (Resolve-Path $cand).Path
            break
        }
    }
    if (-not $PfsshellExe) {
        $PfsCmd = Get-Command "pfsshell.exe" -ErrorAction SilentlyContinue
        if ($PfsCmd) { $PfsshellExe = $PfsCmd.Source } else { $PfsshellExe = "pfsshell.exe" }
    }
} else {
    $PfsshellExe = (Resolve-Path $Pfsshell).Path
}

$WorkDir = Join-Path $ScriptDir "test_header_scratch"

if (Test-Path $WorkDir) {
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $WorkDir | Out-Null

function Log([string]$msg) {
    Write-Host "[TEST-HEADER] $msg" -ForegroundColor Cyan
}

function Assert-True([bool]$condition, [string]$msg) {
    if (-not $condition) {
        Write-Host "[FAIL] $msg" -ForegroundColor Red
        throw "Assertion failed: $msg"
    } else {
        Write-Host "[PASS] $msg" -ForegroundColor Green
    }
}

try {
    Log "Starting hdl-dump header roundtrip regression suite..."
    Log "Using hdl_dump: $HdlDumpExe"
    Log "Using pfsshell: $PfsshellExe"
    Assert-True (Test-Path $HdlDumpExe) "hdl_dump.exe binary exists"
    Assert-True (Test-Path $PfsshellExe) "pfsshell.exe binary exists"

    # Setup disk fixture
    $DiskImg = Join-Path $WorkDir "disk_header.img"
    $fs = [System.IO.File]::Create($DiskImg)
    $fs.SetLength(4GB)
    $fs.Close()

    # Format APA and create partitions
    $pfsCmds = @"
device "$DiskImg"
initialize yes
mkpart +test128 128M PFS
mkpart +test8 8M PFS
mkpart +testsparse 8M PFS
exit
"@
    ($pfsCmds | & $PfsshellExe 2>&1) | Out-Null

    # Create test header assets
    $AssetDir = Join-Path $WorkDir "assets_in"
    New-Item -ItemType Directory -Path $AssetDir | Out-Null

    $sysCnfPath = Join-Path $AssetDir "system.cnf"
    $sysCnfContent = "BOOT2 = cdrom0:\SLUS_123.45;1`r`nVER = 1.00`r`nVMODE = NTSC`r`nHDDUNITPOWER = NICHDD`r`n"
    [System.IO.File]::WriteAllText($sysCnfPath, $sysCnfContent)

    # Valid PS2X icon.sys format
    $iconSysPath = Join-Path $AssetDir "icon.sys"
    $iconSysContent = "PS2X`ntitle0 = Test Title 0`ntitle1 = Test Title 1`nbgcol0 = 0,0,0`nbgcol1 = 0,0,0`nbgcol2 = 0,0,0`nbgcol3 = 0,0,0`n"
    [System.IO.File]::WriteAllText($iconSysPath, $iconSysContent)

    # Dummy list.ico (1024 bytes)
    $listIcoPath = Join-Path $AssetDir "list.ico"
    $icoBytes = New-Object byte[] 1024
    for ($i = 0; $i -lt 1024; $i++) { $icoBytes[$i] = [byte]($i % 256) }
    [System.IO.File]::WriteAllBytes($listIcoPath, $icoBytes)

    # Dummy del.ico (512 bytes)
    $delIcoPath = Join-Path $AssetDir "del.ico"
    $delBytes = New-Object byte[] 512
    for ($i = 0; $i -lt 512; $i++) { $delBytes[$i] = [byte](255 - ($i % 256)) }
    [System.IO.File]::WriteAllBytes($delIcoPath, $delBytes)

    # Compute expected hashes
    $hashSysCnf = (Get-FileHash $sysCnfPath -Algorithm SHA256).Hash
    $hashIconSys = (Get-FileHash $iconSysPath -Algorithm SHA256).Hash
    $hashListIco = (Get-FileHash $listIcoPath -Algorithm SHA256).Hash
    $hashDelIco = (Get-FileHash $delIcoPath -Algorithm SHA256).Hash

    # =========================================================================
    # Test Case 1: 128M Partition modify_header -> dump_header roundtrip
    # =========================================================================
    Log "=== Test Case 1: 128M Partition header injection and extraction ==="
    # Inject from AssetDir
    Push-Location $AssetDir
    $modOut1 = & $HdlDumpExe modify_header $DiskImg "+test128" 2>&1
    Pop-Location
    Assert-True ($LASTEXITCODE -eq 0) "modify_header on 128M partition succeeded"

    # Dump into clean OutDir1
    $OutDir1 = Join-Path $WorkDir "dump_128m"
    New-Item -ItemType Directory -Path $OutDir1 | Out-Null
    Push-Location $OutDir1
    $dumpOut1 = & $HdlDumpExe dump_header $DiskImg "+test128" 2>&1
    Pop-Location
    Assert-True ($LASTEXITCODE -eq 0) "dump_header on 128M partition succeeded"

    # Verify extracted files byte-for-byte
    $outSysCnf1 = Join-Path $OutDir1 "system.cnf"
    $outIconSys1 = Join-Path $OutDir1 "icon.sys"
    $outListIco1 = Join-Path $OutDir1 "list.ico"
    $outDelIco1 = Join-Path $OutDir1 "del.ico"

    Assert-True (Test-Path $outSysCnf1) "system.cnf extracted"
    Assert-True ((Get-FileHash $outSysCnf1 -Algorithm SHA256).Hash -eq $hashSysCnf) "system.cnf matches original byte-for-byte"

    Assert-True (Test-Path $outIconSys1) "icon.sys extracted"
    Assert-True ((Get-FileHash $outIconSys1 -Algorithm SHA256).Hash -eq $hashIconSys) "icon.sys matches original byte-for-byte"

    Assert-True (Test-Path $outListIco1) "list.ico extracted"
    Assert-True ((Get-FileHash $outListIco1 -Algorithm SHA256).Hash -eq $hashListIco) "list.ico matches original byte-for-byte"

    Assert-True (Test-Path $outDelIco1) "del.ico extracted"
    Assert-True ((Get-FileHash $outDelIco1 -Algorithm SHA256).Hash -eq $hashDelIco) "del.ico matches original byte-for-byte"

    # =========================================================================
    # Test Case 2: 8M Partition modify_header -> dump_header roundtrip
    # =========================================================================
    Log "=== Test Case 2: 8M Partition header injection and extraction ==="
    Push-Location $AssetDir
    $modOut2 = & $HdlDumpExe modify_header $DiskImg "+test8" 2>&1
    Pop-Location
    Assert-True ($LASTEXITCODE -eq 0) "modify_header on 8M partition succeeded"

    $OutDir2 = Join-Path $WorkDir "dump_8m"
    New-Item -ItemType Directory -Path $OutDir2 | Out-Null
    Push-Location $OutDir2
    $dumpOut2 = & $HdlDumpExe dump_header $DiskImg "+test8" 2>&1
    Pop-Location
    Assert-True ($LASTEXITCODE -eq 0) "dump_header on 8M partition succeeded"

    $outSysCnf2 = Join-Path $OutDir2 "system.cnf"
    $outListIco2 = Join-Path $OutDir2 "list.ico"
    Assert-True (Test-Path $outSysCnf2) "system.cnf extracted from 8M partition"
    Assert-True ((Get-FileHash $outSysCnf2 -Algorithm SHA256).Hash -eq $hashSysCnf) "system.cnf on 8M matches byte-for-byte"
    Assert-True ((Get-FileHash $outListIco2 -Algorithm SHA256).Hash -eq $hashListIco) "list.ico on 8M matches byte-for-byte"

    # =========================================================================
    # Test Case 3: Sparse assets (skipped system.cnf, only icon.sys & list.ico)
    # =========================================================================
    Log "=== Test Case 3: Sparse assets (skipped system.cnf) extraction ==="
    $SparseAssetDir = Join-Path $WorkDir "assets_sparse"
    New-Item -ItemType Directory -Path $SparseAssetDir | Out-Null
    Copy-Item $iconSysPath $SparseAssetDir
    Copy-Item $listIcoPath $SparseAssetDir

    Push-Location $SparseAssetDir
    $modOut3 = & $HdlDumpExe modify_header $DiskImg "+testsparse" 2>&1
    Pop-Location
    Assert-True ($LASTEXITCODE -eq 0) "modify_header on sparse partition succeeded"

    $OutDir3 = Join-Path $WorkDir "dump_sparse"
    New-Item -ItemType Directory -Path $OutDir3 | Out-Null
    Push-Location $OutDir3
    $dumpOut3 = & $HdlDumpExe dump_header $DiskImg "+testsparse" 2>&1
    Pop-Location
    Assert-True ($LASTEXITCODE -eq 0) "dump_header on sparse partition succeeded"

    $outIconSys3 = Join-Path $OutDir3 "icon.sys"
    $outListIco3 = Join-Path $OutDir3 "list.ico"
    $outSysCnf3 = Join-Path $OutDir3 "system.cnf"

    Assert-True (-not (Test-Path $outSysCnf3)) "system.cnf was skipped and not extracted"
    Assert-True (Test-Path $outIconSys3) "icon.sys extracted when system.cnf was skipped"
    Assert-True ((Get-FileHash $outIconSys3 -Algorithm SHA256).Hash -eq $hashIconSys) "icon.sys matches original byte-for-byte"
    Assert-True (Test-Path $outListIco3) "list.ico extracted when system.cnf was skipped"
    Assert-True ((Get-FileHash $outListIco3 -Algorithm SHA256).Hash -eq $hashListIco) "list.ico matches original byte-for-byte"

    Log "ALL HEADER ROUNDTRIP REGRESSION TESTS PASSED!"
} finally {
    if (Test-Path $WorkDir) {
        Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
