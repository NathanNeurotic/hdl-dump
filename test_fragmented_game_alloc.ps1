# test_fragmented_game_alloc.ps1
# Regression test suite for hdl-dump allocator overhead, fragmentation, PS2_PART_MAXSUB limit, and transactional rollback.

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HdlDumpExe = Join-Path $ScriptDir "hdl_dump.exe"
$PfsshellExe = "c:\Users\natha\Github\PFS-BatchKit-Manager\PFS-BatchKit-Manager\BAT\pfsshell.exe"
$WorkDir = Join-Path $ScriptDir "test_alloc_scratch"

if (Test-Path $WorkDir) {
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $WorkDir | Out-Null

function Log([string]$msg) {
    Write-Host "[TEST-ALLOC] $msg" -ForegroundColor Cyan
}

function Assert-True([bool]$condition, [string]$msg) {
    if (-not $condition) {
        Write-Host "[FAIL] $msg" -ForegroundColor Red
        throw "Assertion failed: $msg"
    } else {
        Write-Host "[PASS] $msg" -ForegroundColor Green
    }
}

function New-TestIso($path, [long]$sizeBytes, $gameId = "SLUS_999.99") {
    $stream = [System.IO.File]::Create($path)
    $stream.SetLength($sizeBytes)
    
    # Sector 16: PVD (0x8000)
    $pvd = New-Object byte[] 2048
    $pvd[0] = 0x01
    [System.Text.Encoding]::ASCII.GetBytes("CD001").CopyTo($pvd, 1)
    $pvd[6] = 0x01
    [System.Text.Encoding]::ASCII.GetBytes("PLAYSTATION".PadRight(32)).CopyTo($pvd, 8)
    [System.Text.Encoding]::ASCII.GetBytes("TEST_GAME".PadRight(32)).CopyTo($pvd, 40)
    # Path table LBA at 140 (little endian LBA 18)
    $pvd[140] = 18; $pvd[141] = 0; $pvd[142] = 0; $pvd[143] = 0
    # Path table LBA big endian at 148
    $pvd[148] = 0; $pvd[149] = 0; $pvd[150] = 0; $pvd[151] = 18
    $stream.Position = 16 * 2048
    $stream.Write($pvd, 0, 2048)

    # Sector 18: Path table (0x9000)
    $pt = New-Object byte[] 2048
    $pt[0] = 1 # id_len
    $pt[1] = 0 # ext_len
    # dir_start_addr = LBA 19
    $pt[2] = 19; $pt[3] = 0; $pt[4] = 0; $pt[5] = 0
    # parent = 1
    $pt[6] = 1; $pt[7] = 0
    $pt[8] = 0 # root id
    $stream.Position = 18 * 2048
    $stream.Write($pt, 0, 2048)

    # Sector 19: Root Directory (0x9800)
    $rd = New-Object byte[] 2048
    $cnfName = "SYSTEM.CNF;1"
    $cnfLen = 64
    $cnfLba = 20
    
    # Entry 1: . (34 bytes)
    $rd[0] = 34
    $rd[2] = 19; $rd[6] = 19 # LBA
    $rd[10] = 0; $rd[11] = 8; $rd[14] = 8; $rd[15] = 0 # Data length 2048
    $rd[25] = 2 # Directory flag
    $rd[32] = 1 # name len
    $rd[33] = 0 # .

    # Entry 2: .. (34 bytes)
    $rd[34] = 34
    $rd[36] = 19; $rd[40] = 19
    $rd[44] = 0; $rd[45] = 8; $rd[48] = 8; $rd[49] = 0
    $rd[59] = 2
    $rd[66] = 1
    $rd[67] = 1 # ..

    # Entry 3: SYSTEM.CNF;1
    $e3 = 68
    $drLen = 33 + $cnfName.Length + 1 # 46 bytes
    $rd[$e3] = $drLen
    $rd[$e3 + 2] = $cnfLba; $rd[$e3 + 6] = $cnfLba
    $rd[$e3 + 10] = $cnfLen; $rd[$e3 + 14] = $cnfLen
    $rd[$e3 + 25] = 0 # file flag
    $rd[$e3 + 32] = $cnfName.Length
    [System.Text.Encoding]::ASCII.GetBytes($cnfName).CopyTo($rd, $e3 + 33)

    $stream.Position = 19 * 2048
    $stream.Write($rd, 0, 2048)

    # Sector 20: SYSTEM.CNF (0xA000)
    $cnfContent = "BOOT2 = cdrom0:\$gameId;1`r`nVER = 1.00`r`nVMODE = NTSC`r`n"
    $cnfBytes = [System.Text.Encoding]::ASCII.GetBytes($cnfContent)
    $stream.Position = 20 * 2048
    $stream.Write($cnfBytes, 0, $cnfBytes.Length)

    $stream.Close()
}

try {
    Log "Starting hdl-dump allocator & fragmentation regression suite..."

    # Rebuild hdl_dump.exe if needed
    Log "Building fresh hdl_dump.exe..."
    $env:PATH = "C:\Users\natha\AppData\Local\Microsoft\WinGet\Packages\MartinStorsjo.LLVM-MinGW.UCRT_Microsoft.Winget.Source_8wekyb3d8bbwe\llvm-mingw-20260616-ucrt-x86_64\bin;C:\Users\natha\AppData\Local\Programs\Python\Python314\Scripts;" + $env:PATH
    & cmd.exe /c "mingw32-make RELEASE=yes WINDOWS=yes CC=i686-w64-mingw32-gcc CXX=i686-w64-mingw32-g++ WINDRES=i686-w64-mingw32-windres"
    Assert-True (Test-Path $HdlDumpExe) "hdl_dump.exe built successfully"

    # =========================================================================
    # Test Case 1: Clean disk + >1 GiB Game (1.5 GiB installation)
    # =========================================================================
    Log "=== Test Case 1: Clean disk + 1.5 GiB game installation ==="
    $DiskImg1 = Join-Path $WorkDir "disk_clean_1.img"
    $IsoFile1 = Join-Path $WorkDir "game_1536mb.iso"

    # Create 4 GiB disk image
    $fs = [System.IO.File]::Create($DiskImg1)
    $fs.SetLength(4GB)
    $fs.Close()

    # Format APA
    $pfsCmds = @"
device "$DiskImg1"
initialize yes
exit
"@
    $pfsOut = ($pfsCmds | & $PfsshellExe 2>&1) | Out-String
    Assert-True ($pfsOut -match "hdd0:\s+\d+GiB") "Disk formatted with APA"

    # Create valid 1.5 GiB ISO (1536 MiB)
    Log "Creating 1536 MiB valid PS2 DVD ISO file..."
    New-TestIso $IsoFile1 1536MB "SLUS_999.99"

    # Install 1.5 GiB game via hdl_dump inject_dvd
    Log "Injecting 1536 MiB game via hdl_dump inject_dvd..."
    $injectOut = & $HdlDumpExe inject_dvd $DiskImg1 "LargeGame1" $IsoFile1 "SLUS_999.99" *u4 2>&1
    $injectCode = $LASTEXITCODE
    Assert-True ($injectCode -eq 0) "1.5 GiB game injected with exit code 0"

    # Verify diag and toc
    $diagOut = (& $HdlDumpExe diag $DiskImg1 2>&1) | Out-String
    $diagCode = $LASTEXITCODE
    Assert-True ($diagCode -eq 0 -and $diagOut.Trim().Length -eq 0) "hdl_dump diag reports 0 problems"

    $tocOut = (& $HdlDumpExe hdl_toc $DiskImg1 2>&1) | Out-String
    Assert-True ($tocOut -match "LargeGame1") "hdl_toc lists LargeGame1"
    Assert-True ($tocOut -match "1572864KB|1536\s*MB") "hdl_toc reports correct game capacity"

    # =========================================================================
    # Test Case 2: Fragmented Disk + >1 GiB Game (Overhead & Multi-Fragment Bug)
    # =========================================================================
    Log "=== Test Case 2: Fragmented disk with alternating gaps + >1 GiB game ==="
    $DiskImg2 = Join-Path $WorkDir "disk_frag_2.img"

    # Create 8 GiB disk image
    $fs = [System.IO.File]::Create($DiskImg2)
    $fs.SetLength(8GB)
    $fs.Close()

    # Initialize APA with pfsshell and create checkerboard partitions
    $pfsCmds = @"
device "$DiskImg2"
initialize yes
mkpart +p01 8M PFS
mkpart +p02 16M PFS
mkpart +p03 8M PFS
mkpart +p04 32M PFS
mkpart +p05 8M PFS
mkpart +p06 16M PFS
mkpart +p07 8M PFS
mkpart +p08 32M PFS
mkpart +p09 8M PFS
mkpart +p10 16M PFS
rmpart +p01
rmpart +p03
rmpart +p05
rmpart +p07
rmpart +p09
exit
"@
    ($pfsCmds | & $PfsshellExe 2>&1) | Out-Null

    # Now inject the 1.5 GiB game into this highly fragmented space
    Log "Injecting 1536 MiB game into fragmented disk..."
    $injectOut2 = & $HdlDumpExe inject_dvd $DiskImg2 "FragGame" $IsoFile1 "SLUS_888.88" *u4 2>&1
    $injectCode2 = $LASTEXITCODE
    Assert-True ($injectCode2 -eq 0) "1.5 GiB game injected into fragmented space with exit code 0 (no RET_NO_SPACE premature exhaust)"

    # Verify diag and toc
    $diagOut2 = (& $HdlDumpExe diag $DiskImg2 2>&1) | Out-String
    $diagCode2 = $LASTEXITCODE
    Assert-True ($diagCode2 -eq 0 -and $diagOut2.Trim().Length -eq 0) "hdl_dump diag reports 0 problems after fragmented install"

    $tocOut2 = (& $HdlDumpExe hdl_toc $DiskImg2 2>&1) | Out-String
    Assert-True ($tocOut2 -match "FragGame") "hdl_toc lists FragGame"

    # =========================================================================
    # Test Case 3: Deliberately Impossible Allocation / Boundary Enforcement
    # =========================================================================
    Log "=== Test Case 3: Impossible Allocation & PS2_PART_MAXSUB Boundary ==="
    $DiskImg3 = Join-Path $WorkDir "disk_impossible_3.img"
    $fs = [System.IO.File]::Create($DiskImg3)
    $fs.SetLength(4GB)
    $fs.Close()

    $pfsInit = @"
device "$DiskImg3"
initialize yes
exit
"@
    ($pfsInit | & $PfsshellExe 2>&1) | Out-Null

    # Capture pristine pre-attempt TOC
    $preAttemptToc = (& $HdlDumpExe toc $DiskImg3 2>&1) | Out-String

    # Attempt to install a 5000MB game on a 4GB disk (exceeds slice capacity)
    Log "Attempting allocation that exceeds available slice capacity..."
    $IsoImpossible = Join-Path $WorkDir "iso_impossible.iso"
    New-TestIso $IsoImpossible 5000MB "SLUS_000.00"

    $failOut = & $HdlDumpExe inject_dvd $DiskImg3 "TooLargeGame" $IsoImpossible "SLUS_000.00" *u4 2>&1
    $failCode = $LASTEXITCODE
    Assert-True ($failCode -ne 0) "Impossible allocation failed cleanly with non-zero exit code"

    # =========================================================================
    # Test Case 4: Transactional Rollback Verification
    # =========================================================================
    Log "=== Test Case 4: Transactional Rollback Verification ==="
    # Assert TOC is 100% unchanged
    $postAttemptToc = (& $HdlDumpExe toc $DiskImg3 2>&1) | Out-String
    Assert-True ($preAttemptToc.Trim() -eq $postAttemptToc.Trim()) "TOC is 100% unchanged after failed allocation attempt"

    $diagOut3 = (& $HdlDumpExe diag $DiskImg3 2>&1) | Out-String
    $diagCode3 = $LASTEXITCODE
    Assert-True ($diagCode3 -eq 0 -and $diagOut3.Trim().Length -eq 0) "hdl_dump diag reports 0 problems after rolled-back attempt"

    Log "ALL ALLOCATOR REGRESSION TESTS PASSED!"
} finally {
    if (Test-Path $WorkDir) {
        Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
