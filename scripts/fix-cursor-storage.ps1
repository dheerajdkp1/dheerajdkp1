#Requires -Version 5.1
<#
.SYNOPSIS
  Repairs Cursor "Storage Error" for state.vscdb on Windows.

.DESCRIPTION
  - Stops Cursor processes
  - Backs up globalStorage
  - Tries restore from state.vscdb.corrupted.* then state.vscdb.backup
  - Clears stale WAL/SHM lock files
  - Optionally VACUUMs oversized DB if sqlite3 is available

  Run: Right-click -> "Run with PowerShell"
  Or:  powershell -ExecutionPolicy Bypass -File fix-cursor-storage.ps1
#>

$ErrorActionPreference = "Stop"

$GlobalStorage = Join-Path $env:APPDATA "Cursor\User\globalStorage"
$StateDb       = Join-Path $GlobalStorage "state.vscdb"
$BackupRoot    = Join-Path $env:USERPROFILE "Desktop\Cursor-storage-backup-$(Get-Date -Format 'yyyy-MM-dd_HHmmss')"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    WARN: $msg" -ForegroundColor Yellow }

Write-Host @"

 Cursor Storage Repair
 ---------------------
 Target: $StateDb

"@ -ForegroundColor White

if (-not (Test-Path $GlobalStorage)) {
    Write-Error "Cursor globalStorage not found at: $GlobalStorage"
    exit 1
}

# --- 1. Stop Cursor ---
Write-Step "Stopping Cursor processes"
$cursorProcs = Get-Process -Name "Cursor" -ErrorAction SilentlyContinue
if ($cursorProcs) {
    $cursorProcs | Stop-Process -Force
    Start-Sleep -Seconds 2
    Write-Ok "Stopped $($cursorProcs.Count) Cursor process(es)"
} else {
    Write-Ok "No Cursor processes running"
}

# --- 2. Backup ---
Write-Step "Backing up globalStorage to Desktop"
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
Copy-Item -Path (Join-Path $GlobalStorage "*") -Destination $BackupRoot -Recurse -Force
Write-Ok "Backup saved: $BackupRoot"

function Get-FileSizeMB($path) {
    if (Test-Path $path) {
        return [math]::Round((Get-Item $path).Length / 1MB, 2)
    }
    return 0
}

$currentSize = Get-FileSizeMB $StateDb
Write-Host "    Current state.vscdb size: $currentSize MB"

# --- 3. Move broken files aside ---
Write-Step "Moving current state files to OLD subfolder"
$OldDir = Join-Path $GlobalStorage "OLD-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OldDir -Force | Out-Null

$patterns = @("state.vscdb", "state.vscdb.backup", "state.vscdb-wal", "state.vscdb-shm")
foreach ($name in $patterns) {
    $src = Join-Path $GlobalStorage $name
    if (Test-Path $src) {
        Move-Item -Path $src -Destination (Join-Path $OldDir $name) -Force
        Write-Ok "Moved $name -> OLD"
    }
}

# --- 4. Pick best restore source ---
Write-Step "Selecting best restore source"

$corruptedFiles = Get-ChildItem -Path $GlobalStorage -Filter "state.vscdb.corrupted.*" -File -ErrorAction SilentlyContinue |
    Sort-Object Length -Descending

$restoreSource = $null
$restoreReason = ""

if ($corruptedFiles -and $corruptedFiles.Count -gt 0) {
    $restoreSource = $corruptedFiles[0].FullName
    $restoreReason = "largest state.vscdb.corrupted.* ($([math]::Round($corruptedFiles[0].Length/1MB,2)) MB)"
} elseif (Test-Path (Join-Path $OldDir "state.vscdb.backup")) {
    $restoreSource = Join-Path $OldDir "state.vscdb.backup"
    $restoreReason = "state.vscdb.backup from OLD folder"
}

if ($restoreSource) {
    Copy-Item -Path $restoreSource -Destination $StateDb -Force
    Write-Ok "Restored state.vscdb from $restoreReason"
    Write-Ok "Source: $restoreSource"
} else {
    Write-Warn "No corrupted backup or .backup file found — Cursor will create a fresh state.vscdb on next launch"
    Write-Warn "Chat history may be inaccessible unless you manually restore from: $BackupRoot"
}

# --- 5. Integrity check (optional, if sqlite3 exists) ---
$sqlite3 = Get-Command sqlite3 -ErrorAction SilentlyContinue
if ($sqlite3 -and (Test-Path $StateDb)) {
    Write-Step "Running SQLite integrity check"
    $check = & sqlite3 $StateDb "PRAGMA integrity_check;" 2>&1
    if ($check -eq "ok") {
        Write-Ok "integrity_check: ok"
        $sizeMB = Get-FileSizeMB $StateDb
        if ($sizeMB -gt 500) {
            Write-Warn "DB is large ($sizeMB MB). Running VACUUM..."
            & sqlite3 $StateDb "VACUUM;"
            Write-Ok "VACUUM complete. New size: $(Get-FileSizeMB $StateDb) MB"
        }
    } else {
        Write-Warn "integrity_check failed: $check"
        Write-Warn "Trying .recover into recovered.vscdb..."
        $recovered = Join-Path $GlobalStorage "recovered.vscdb"
        & sqlite3 $StateDb ".recover" | & sqlite3 $recovered
        if (Test-Path $recovered) {
            Move-Item -Path $StateDb -Destination (Join-Path $OldDir "state.vscdb.failed") -Force
            Move-Item -Path $recovered -Destination $StateDb -Force
            Write-Ok "Replaced state.vscdb with recovered copy"
        }
    }
}

# --- 6. Done ---
Write-Host @"

========================================
 Repair complete.
========================================

 Backup:  $BackupRoot
 OLD dir: $OldDir

 Next: Start Cursor normally.

 If Storage Error persists:
   1. Pause OneDrive sync on AppData
   2. Update Cursor (Help -> About)
   3. Post on forum.cursor.com with file sizes from backup folder

"@ -ForegroundColor Green

$launch = Read-Host "Launch Cursor now? (Y/n)"
if ($launch -ne "n" -and $launch -ne "N") {
    $cursorExe = @(
        "${env:LOCALAPPDATA}\Programs\cursor\Cursor.exe",
        "${env:ProgramFiles}\Cursor\Cursor.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($cursorExe) {
        Start-Process $cursorExe
        Write-Ok "Launched Cursor"
    } else {
        Write-Warn "Could not find Cursor.exe — start it manually from Start menu"
    }
}
