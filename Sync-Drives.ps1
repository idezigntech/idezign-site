<#
======================================================================
 Sync-Drives.ps1  -  Two-way folder synchronizer for Windows
======================================================================

 WHAT IT DOES
   Keeps two folders (typically on two external drives) in sync in BOTH
   directions. The newer version of any changed file wins. Anything that
   gets deleted or overwritten is NOT lost - it is moved into a dated
   "_SyncTrash" folder on the drive it left, so you can always recover it.

 HOW IT STAYS SAFE
   True two-way sync has to know what the drives looked like LAST time,
   otherwise it can't tell "this file was added here" apart from "this
   file was deleted there." The script saves a small state file
   (.syncstate.json) after every run and reads it on the next run to make
   that distinction correctly.

 FIRST RUN
   On the very first run there is no prior state, so the script simply
   UNIONS both drives - every file present on either side is copied to the
   other. Nothing is deleted on a first run. After that, deletions are
   tracked normally.

 USAGE
   1. Just run it - the script lists your connected drives and asks you
      to pick the two to sync. No editing required.
        powershell -ExecutionPolicy Bypass -File .\Sync-Drives.ps1 -DryRun
   2. Always test first with -DryRun (above) to preview the actions. When
      the dry run finishes it will offer to immediately run for real.
   3. Or run live straight away by omitting -DryRun:
        powershell -ExecutionPolicy Bypass -File .\Sync-Drives.ps1

   Skip the prompt by passing paths directly (handy for scheduled tasks):
        .\Sync-Drives.ps1 -DriveA "E:\" -DriveB "F:\Backup"

 MODES
   TWO-WAY (default): both drives kept in sync, newer file wins, deletions
     tracked via the state file. This is the original behavior.
   ONE-WAY: a mirror in a single direction. DriveA is the SOURCE (FROM)
     and DriveB is the DESTINATION (TO). The source is authoritative:
     new/changed files copy FROM -> TO, and anything on TO that isn't on
     FROM is moved to TO's trash so the destination ends up matching the
     source. Nothing is ever hard-deleted; replaced/removed files are
     archived in _SyncTrash and recoverable.
     Run one-way non-interactively like:
        .\Sync-Drives.ps1 -Mode OneWay -From "D:\" -To "F:\"
   ADDITIVE (one-way, no deletes): copies new and newer files FROM -> TO,
     but never removes anything from the destination. Good for piling
     backups onto a drive without losing what's already there.
        .\Sync-Drives.ps1 -Mode Additive -From "D:\" -To "F:\"

 DESTINATION-NEWER PROMPT (one-way modes)
   If the same file is on both drives but the DESTINATION's copy is newer
   than the source's, the script pauses and asks before overwriting it.
   Answer "n" to keep the newer file; answer "y" to replace it with the
   source version (the newer file is moved to trash, never hard-deleted).
   In unattended runs it keeps the newer file and logs it.

 COMPATIBLE WITH  Windows PowerShell 5.1 and PowerShell 7.x.
======================================================================
#>

[CmdletBinding()]
param(
    # The two endpoints. Leave empty to be asked interactively.
    # In ONE-WAY mode, DriveA is the SOURCE (copy FROM) and
    # DriveB is the DESTINATION (copy TO). Aliases: -From / -To.
    [Alias('Source','From')]
    [string]$DriveA = "",
    [Alias('Dest','Destination','To')]
    [string]$DriveB = "",

    # "TwoWay" (default) keeps both drives in sync; the newer file wins.
    # "OneWay" mirrors DriveA -> DriveB only; the source is authoritative.
    # Leave empty to be asked interactively.
    [ValidateSet("", "TwoWay", "OneWay", "Additive")]
    [string]$Mode = "",

    # Show what WOULD happen without changing anything.
    [switch]$DryRun,

    # Compare file contents by hash instead of size+timestamp.
    # Slower, but catches files that changed without updating their date.
    [switch]$UseHash
)

# ---------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------
$TrashFolderName = "_SyncTrash"          # created on each drive as needed
$StateFileName   = ".syncstate.json"     # stored on Drive A
$LogFolderName   = "_SyncLogs"           # stored on Drive A
$TimeStamp       = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

# Folders/files to ignore everywhere (system + our own bookkeeping).
$Excludes = @(
    $TrashFolderName, $StateFileName, $LogFolderName,
    "System Volume Information", '$RECYCLE.BIN', ".Trash-*",
    "Thumbs.db", "desktop.ini", ".DS_Store"
)

# ---------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------
$script:LogLines = New-Object System.Collections.Generic.List[string]
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] {1,-5} {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
    $script:LogLines.Add($line)
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "DO"    { Write-Host $line -ForegroundColor Green }
        "DRY"   { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
}

# Overall timer + a throttle so the progress bar refreshes smoothly
# (at most a few times a second) instead of on every single file.
$script:Clock      = [System.Diagnostics.Stopwatch]::StartNew()
$script:LastTickMs = -1000
function Test-Tick {
    # Returns $true at most ~5x/second, so callers know when to redraw.
    param([switch]$Force)
    $now = [int]$script:Clock.Elapsed.TotalMilliseconds
    if ($Force -or ($now - $script:LastTickMs) -ge 200) {
        $script:LastTickMs = $now
        return $true
    }
    return $false
}

# Human-readable byte sizes for the summary (works on 5.1 and 7.x).
function Format-Bytes {
    param([double]$Bytes)
    $units = "B","KB","MB","GB","TB"
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes /= 1024; $i++ }
    return ("{0:N1} {1}" -f $Bytes, $units[$i])
}

# ---------------------------------------------------------------------
# Interactive drive picker (used when -DriveA / -DriveB not supplied)
# ---------------------------------------------------------------------
function Show-DriveMenu {
    # List real, ready filesystem drives with size + free space + label.
    $drives = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.Size -gt 0 } |
        Sort-Object DeviceID
    $typeName = @{ 2 = "Removable"; 3 = "Fixed"; 4 = "Network"; 5 = "CD/DVD" }

    Write-Host ""
    Write-Host "Available drives:" -ForegroundColor White
    Write-Host ("  {0,-3} {1,-6} {2,-11} {3,9} {4,9}  {5}" -f "#","Drive","Type","Size","Free","Label")
    Write-Host ("  " + ("-" * 60))
    $i = 0
    $map = @{}
    foreach ($d in $drives) {
        $i++
        $map[$i] = ($d.DeviceID + "\")
        $sizeGB = "{0:N0} GB" -f ($d.Size / 1GB)
        $freeGB = "{0:N0} GB" -f ($d.FreeSpace / 1GB)
        $t = $typeName[[int]$d.DriveType]; if (-not $t) { $t = "Other" }
        Write-Host ("  {0,-3} {1,-6} {2,-11} {3,9} {4,9}  {5}" -f `
            $i, $d.DeviceID, $t, $sizeGB, $freeGB, $d.VolumeName)
    }
    Write-Host ""
    return $map
}

function Read-DriveChoice {
    param([string]$Prompt, [hashtable]$Map)
    while ($true) {
        $ans = (Read-Host $Prompt).Trim()
        if ($ans -eq "") { continue }
        # Accept a menu number...
        if ($ans -match '^\d+$' -and $Map.ContainsKey([int]$ans)) {
            return $Map[[int]$ans]
        }
        # ...or a typed path / drive letter (e.g. "E", "E:", "F:\Backup").
        if ($ans -match '^[A-Za-z]$') { $ans = "$ans`:\" }
        elseif ($ans -match '^[A-Za-z]:$') { $ans = "$ans\" }
        if (Test-Path -LiteralPath $ans) { return $ans }
        Write-Host "  '$ans' isn't a listed number or a valid path. Try again." -ForegroundColor Yellow
    }
}

# Ask for the mode first (if it wasn't supplied on the command line).
if ([string]::IsNullOrWhiteSpace($Mode)) {
    if ([Environment]::UserInteractive) {
        Write-Host ""
        Write-Host "Choose mode:" -ForegroundColor White
        Write-Host "  1) Two-way sync     (both drives kept in sync; newer file wins)"
        Write-Host "  2) One-way mirror   (destination becomes an exact copy of source;"
        Write-Host "                       extras on the destination are moved to trash)"
        Write-Host "  3) One-way add      (copy new/updated files to destination;"
        Write-Host "                       never deletes or removes anything on destination)"
        $m = (Read-Host "Mode (1/2/3)").Trim()
        $Mode = switch ($m) { "2" { "OneWay" } "3" { "Additive" } default { "TwoWay" } }
    } else {
        $Mode = "TwoWay"   # safe default for unattended/scheduled runs
    }
}
$directional = ($Mode -eq "OneWay" -or $Mode -eq "Additive")

if ([string]::IsNullOrWhiteSpace($DriveA) -or [string]::IsNullOrWhiteSpace($DriveB)) {
    $map = Show-DriveMenu
    Write-Host "Pick by number, or type a drive letter / folder path." -ForegroundColor White
    Write-Host "(You can point at a subfolder too, e.g. F:\Backup)" -ForegroundColor DarkGray
    if ($directional) {
        if ([string]::IsNullOrWhiteSpace($DriveA)) {
            $DriveA = Read-DriveChoice "  Copy FROM (source)     " $map
        }
        if ([string]::IsNullOrWhiteSpace($DriveB)) {
            $DriveB = Read-DriveChoice "  Copy TO   (destination)" $map
        }
    } else {
        if ([string]::IsNullOrWhiteSpace($DriveA)) {
            $DriveA = Read-DriveChoice "  First drive/folder  (A)" $map
        }
        if ([string]::IsNullOrWhiteSpace($DriveB)) {
            $DriveB = Read-DriveChoice "  Second drive/folder (B)" $map
        }
    }
    Write-Host ""
    Write-Host "About to run:" -ForegroundColor White
    if ($Mode -eq "OneWay") {
        Write-Host "    Mode  : ONE-WAY mirror"
        Write-Host "    FROM  : $DriveA"
        Write-Host "    TO    : $DriveB"
        Write-Host "    (anything on TO that isn't on FROM is moved to TO's trash)" -ForegroundColor DarkGray
    } elseif ($Mode -eq "Additive") {
        Write-Host "    Mode  : ONE-WAY add (no deletes)"
        Write-Host "    FROM  : $DriveA"
        Write-Host "    TO    : $DriveB"
        Write-Host "    (new and newer files copied to TO; nothing on TO is removed)" -ForegroundColor DarkGray
    } else {
        Write-Host "    Mode  : TWO-WAY sync"
        Write-Host "    A     : $DriveA"
        Write-Host "    B     : $DriveB"
    }
    Write-Host ("    Run   : {0}" -f $(if($DryRun){"DRY RUN (preview only)"}else{"LIVE (will modify files)"}))
    $confirm = (Read-Host "Proceed? (y/n)").Trim().ToLower()
    if ($confirm -ne "y" -and $confirm -ne "yes") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------
function Assert-Drive {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "$Name path not found: $Path  (is the drive plugged in?)" "ERROR"
        exit 1
    }
}
Assert-Drive $DriveA "DriveA"
Assert-Drive $DriveB "DriveB"

$DriveA = (Resolve-Path -LiteralPath $DriveA).Path.TrimEnd('\') + '\'
$DriveB = (Resolve-Path -LiteralPath $DriveB).Path.TrimEnd('\') + '\'

if ($DriveA -ieq $DriveB) {
    Write-Log "DriveA and DriveB are the same location. Nothing to do." "ERROR"
    exit 1
}

Write-Log "Sync starting"
if ($Mode -eq "OneWay") {
    Write-Log "  Mode    : ONE-WAY mirror  (source is authoritative)"
    Write-Log "  FROM    : $DriveA"
    Write-Log "  TO      : $DriveB"
} elseif ($Mode -eq "Additive") {
    Write-Log "  Mode    : ONE-WAY add  (new/updated only; no deletes)"
    Write-Log "  FROM    : $DriveA"
    Write-Log "  TO      : $DriveB"
} else {
    Write-Log "  Mode    : TWO-WAY"
    Write-Log "  Drive A : $DriveA"
    Write-Log "  Drive B : $DriveB"
}
Write-Log ("  Run     : {0}{1}" -f $(if($DryRun){"DRY RUN (no changes) "}else{"LIVE "}), $(if($UseHash){"+ hash compare"}else{""}))

# ---------------------------------------------------------------------
# Build an index of one side: relative path -> file info
# ---------------------------------------------------------------------
function Test-Excluded {
    param([string]$RelPath)
    $first = ($RelPath -split '[\\/]')[0]
    foreach ($ex in $Excludes) {
        if ($first -like $ex) { return $true }
        if ($RelPath -like "*\$ex" -or $RelPath -like "*\$ex\*") { return $true }
        if ($RelPath -like $ex) { return $true }
    }
    return $false
}

function Get-Index {
    param([string]$Root, [string]$Label, [int]$ProgressId = 1)
    $index = @{}
    $seen = 0
    # Stream the enumeration so we can show a live count while scanning a
    # large drive (total isn't known up front, so this bar shows activity
    # and a running tally rather than a percentage).
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $seen++
        $rel = $_.FullName.Substring($Root.Length)
        if (-not (Test-Excluded $rel)) {
            $index[$rel] = [pscustomobject]@{
                Rel     = $rel
                Full    = $_.FullName
                Size    = $_.Length
                Mtime   = $_.LastWriteTimeUtc
                MtimeMs = [int64]($_.LastWriteTimeUtc - [datetime]'1970-01-01').TotalMilliseconds
            }
        }
        if (Test-Tick) {
            Write-Progress -Id $ProgressId -Activity "Scanning $Label" `
                -Status "$seen files found... ($($index.Count) to sync)"
        }
    }
    Write-Progress -Id $ProgressId -Activity "Scanning $Label" -Completed
    return $index
}

Write-Log "Scanning Drive A..."
$idxA = Get-Index -Root $DriveA -Label "Drive A ($DriveA)" -ProgressId 1
Write-Log "  $($idxA.Count) files on A"
Write-Log "Scanning Drive B..."
$idxB = Get-Index -Root $DriveB -Label "Drive B ($DriveB)" -ProgressId 1
Write-Log "  $($idxB.Count) files on B"

# ---------------------------------------------------------------------
# Load previous state (set of relative paths that existed last sync)
# ---------------------------------------------------------------------
$statePath = Join-Path $DriveA $StateFileName
$prevSet = @{}
$firstRun = $true
if ($Mode -eq "OneWay") {
    Write-Log "One-way mirror: the destination will be made to match the source."
} elseif ($Mode -eq "Additive") {
    Write-Log "Additive: new/updated files copied to destination; nothing on it is removed."
} elseif (Test-Path -LiteralPath $statePath) {
    try {
        $raw = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        foreach ($p in $raw.paths) { $prevSet[$p] = $true }
        $firstRun = $false
        Write-Log "Loaded previous state: $($prevSet.Count) tracked files"
    } catch {
        Write-Log "Could not read state file; treating as first run." "WARN"
    }
} else {
    Write-Log "No previous state found - FIRST RUN (union only, no deletions)." "WARN"
}

# ---------------------------------------------------------------------
# Helpers: compare, copy, trash
# ---------------------------------------------------------------------
function Get-FileHashSafe {
    param([string]$Path)
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    catch { return $null }
}

# Returns: 'A' if A is newer, 'B' if B is newer, 'same' if equal
function Compare-Pair {
    param($a, $b)
    if ($UseHash) {
        $ha = Get-FileHashSafe $a.Full
        $hb = Get-FileHashSafe $b.Full
        if ($ha -and $hb -and $ha -eq $hb) { return 'same' }
    } else {
        if ($a.Size -eq $b.Size -and [math]::Abs($a.MtimeMs - $b.MtimeMs) -le 2000) {
            return 'same'   # within 2s tolerance (FAT/exFAT timestamp rounding)
        }
    }
    if ($a.Mtime -gt $b.Mtime) { return 'A' }
    elseif ($b.Mtime -gt $a.Mtime) { return 'B' }
    else { return 'same' }
}

$stats = @{ Copied = 0; Updated = 0; Trashed = 0; Conflicts = 0; Skipped = 0
            BytesCopied = [int64]0; BytesTrashed = [int64]0
            AtoB = 0; BtoA = 0 }

function Move-ToTrash {
    param([string]$DriveRoot, [string]$Rel)
    $src = Join-Path $DriveRoot $Rel
    if (-not (Test-Path -LiteralPath $src)) { return }
    $len = (Get-Item -LiteralPath $src -ErrorAction SilentlyContinue).Length
    if ($len) { $stats.BytesTrashed += [int64]$len }
    $trashRoot = Join-Path (Join-Path $DriveRoot $TrashFolderName) $TimeStamp
    $dest = Join-Path $trashRoot $Rel
    if ($DryRun) {
        Write-Log "TRASH  $DriveRoot$Rel" "DRY"
    } else {
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Move-Item -LiteralPath $src -Destination $dest -Force
        Write-Log "TRASH  $DriveRoot$Rel" "DO"
    }
    $stats.Trashed++
}

function Copy-File {
    param([string]$SrcRoot, [string]$DstRoot, [string]$Rel, [string]$Why)
    $src = Join-Path $SrcRoot $Rel
    $dst = Join-Path $DstRoot $Rel
    $len = (Get-Item -LiteralPath $src -ErrorAction SilentlyContinue).Length
    if ($len) { $stats.BytesCopied += [int64]$len }
    if ($SrcRoot -eq $DriveA) { $stats.AtoB++ } else { $stats.BtoA++ }
    if ($DryRun) {
        Write-Log "$Why  $SrcRoot$Rel  ->  $DstRoot" "DRY"
    } else {
        $dstDir = Split-Path $dst -Parent
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-Log "$Why  $SrcRoot$Rel  ->  $DstRoot" "DO"
    }
}

# Asked (in one-way modes) when the destination's copy is NEWER than the
# source's. Returns $true to replace it (the newer file is sent to trash,
# not hard-deleted), $false to keep the destination as-is.
function Confirm-DestOverwrite {
    param([string]$Rel)
    $stats.Conflicts++
    if ($DryRun) {
        Write-Log "CONFLICT  destination is newer; would ask whether to replace: $Rel" "DRY"
        return $false
    }
    if (-not [Environment]::UserInteractive) {
        Write-Log "KEEP   destination is newer; left as-is (non-interactive): $Rel" "WARN"
        return $false
    }
    Write-Host ""
    Write-Host "Destination has a NEWER version of:" -ForegroundColor Yellow
    Write-Host "    $Rel" -ForegroundColor Yellow
    $a = (Read-Host "Replace it with the older SOURCE copy? Newer file goes to trash (y/n)").Trim().ToLower()
    return ($a -eq 'y' -or $a -eq 'yes')
}

# ---------------------------------------------------------------------
# Main reconciliation
# ---------------------------------------------------------------------
$allRel = [System.Collections.Generic.HashSet[string]]::new()
foreach ($k in $idxA.Keys) { [void]$allRel.Add($k) }
foreach ($k in $idxB.Keys) { [void]$allRel.Add($k) }

$total = $allRel.Count
$done  = 0
foreach ($rel in $allRel) {
    $done++
    if (Test-Tick) {
        $pct = if ($total -gt 0) { [int](($done / $total) * 100) } else { 100 }
        Write-Progress -Id 2 -Activity "Synchronizing" `
            -Status "$done of $total files  ($pct%)  -  $rel" -PercentComplete $pct
    }
    $onA = $idxA.ContainsKey($rel)
    $onB = $idxB.ContainsKey($rel)
    $wasTracked = $prevSet.ContainsKey($rel)

    if ($Mode -eq "OneWay") {
        # ----- ONE-WAY: source (A) is authoritative; make B match A. -----
        if ($onA -and $onB) {
            $cmp = Compare-Pair $idxA[$rel] $idxB[$rel]
            if ($cmp -eq 'same') {
                $stats.Skipped++
            } elseif ($cmp -eq 'B') {
                # Destination copy is NEWER than source - ask before replacing.
                if (Confirm-DestOverwrite $rel) {
                    Move-ToTrash $DriveB $rel
                    Copy-File $DriveA $DriveB $rel "UPDATE"; $stats.Updated++
                } else {
                    $stats.Skipped++
                }
            } else {
                # Source is newer: source wins. Old dest copy goes to trash.
                Move-ToTrash $DriveB $rel
                Copy-File $DriveA $DriveB $rel "UPDATE"; $stats.Updated++
            }
        }
        elseif ($onA -and -not $onB) {
            # New on source -> copy to destination.
            Copy-File $DriveA $DriveB $rel "COPY  "; $stats.Copied++
        }
        elseif ($onB -and -not $onA) {
            # Extra on destination (not on source) -> remove it (to trash).
            Move-ToTrash $DriveB $rel
        }
    }
    elseif ($Mode -eq "Additive") {
        # ----- ADDITIVE: copy new/updated A -> B; never delete on B. -----
        if ($onA -and $onB) {
            $cmp = Compare-Pair $idxA[$rel] $idxB[$rel]
            if ($cmp -eq 'A') {
                # Source is newer -> refresh destination (old copy to trash).
                Move-ToTrash $DriveB $rel
                Copy-File $DriveA $DriveB $rel "UPDATE"; $stats.Updated++
            } elseif ($cmp -eq 'B') {
                # Destination copy is NEWER than source - ask before replacing.
                if (Confirm-DestOverwrite $rel) {
                    Move-ToTrash $DriveB $rel
                    Copy-File $DriveA $DriveB $rel "UPDATE"; $stats.Updated++
                } else {
                    $stats.Skipped++
                }
            } else {
                # Identical -> leave destination as-is.
                $stats.Skipped++
            }
        }
        elseif ($onA -and -not $onB) {
            # New on source -> copy to destination.
            Copy-File $DriveA $DriveB $rel "COPY  "; $stats.Copied++
        }
        else {
            # Extra on destination -> never removed in additive mode.
            $stats.Skipped++
        }
    }
    else {
        # ----- TWO-WAY: newer wins; state distinguishes add vs delete. ---
        if ($onA -and $onB) {
            # Exists on both - newer wins; loser goes to trash before overwrite.
            $cmp = Compare-Pair $idxA[$rel] $idxB[$rel]
            switch ($cmp) {
                'same' { $stats.Skipped++ }
                'A'    { Move-ToTrash $DriveB $rel; Copy-File $DriveA $DriveB $rel "UPDATE"; $stats.Updated++ }
                'B'    { Move-ToTrash $DriveA $rel; Copy-File $DriveB $DriveA $rel "UPDATE"; $stats.Updated++ }
            }
        }
        elseif ($onA -and -not $onB) {
            if ($wasTracked -and -not $firstRun) {
                # Existed last time, now gone from B => deleted on B. Remove from A.
                Move-ToTrash $DriveA $rel
            } else {
                # New file on A => copy to B.
                Copy-File $DriveA $DriveB $rel "COPY  "; $stats.Copied++
            }
        }
        elseif ($onB -and -not $onA) {
            if ($wasTracked -and -not $firstRun) {
                # Deleted on A. Remove from B.
                Move-ToTrash $DriveB $rel
            } else {
                Copy-File $DriveB $DriveA $rel "COPY  "; $stats.Copied++
            }
        }
    }
}
Write-Progress -Id 2 -Activity "Synchronizing" -Completed

# ---------------------------------------------------------------------
# Save new state = files present on Drive A after this sync.
# (Only needed for two-way; one-way is a stateless mirror.)
# ---------------------------------------------------------------------
if (-not $DryRun -and $Mode -eq "TwoWay") {
    $finalIdx = Get-Index -Root $DriveA -Label "Drive A (saving state)" -ProgressId 1
    $newState = [pscustomobject]@{
        savedUtc = (Get-Date).ToUniversalTime().ToString("o")
        paths    = @($finalIdx.Keys)
    }
    $newState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
    Write-Log "State saved: $($finalIdx.Count) files"
}

# ---------------------------------------------------------------------
# Summary of what was done + log file
# ---------------------------------------------------------------------
$script:Clock.Stop()
$elapsed = "{0:hh\:mm\:ss}" -f $script:Clock.Elapsed
$verb    = if ($DryRun) { "would copy" } else { "copied   " }

Write-Log "========================================"
Write-Log "  SYNC SUMMARY" "DO"
Write-Log "========================================"
if ($directional) {
    Write-Log ("  Source (FROM)       : {0} ({1} files)" -f $DriveA, $idxA.Count)
    Write-Log ("  Destination (TO)    : {0} ({1} files)" -f $DriveB, $idxB.Count)
    Write-Log ("  New files copied    : {0,6}  (FROM -> TO)" -f $stats.Copied)
} else {
    Write-Log ("  Drive A             : {0} ({1} files)" -f $DriveA, $idxA.Count)
    Write-Log ("  Drive B             : {0} ({1} files)" -f $DriveB, $idxB.Count)
    Write-Log ("  New files copied    : {0,6}  ({1} A->B, {2} B->A)" -f $stats.Copied, $stats.AtoB, $stats.BtoA)
}
Write-Log ("  Files updated       : {0,6}  (newer version won)" -f $stats.Updated)
Write-Log ("  Files trashed       : {0,6}  (archived, not lost)" -f $stats.Trashed)
Write-Log ("  Unchanged / skipped : {0,6}" -f $stats.Skipped)
if ($directional -and $stats.Conflicts -gt 0) {
    Write-Log ("  Dest-newer prompts  : {0,6}  (destination had a newer copy)" -f $stats.Conflicts)
}
Write-Log ("  Data {0}      : {1}" -f $verb, (Format-Bytes $stats.BytesCopied))
Write-Log ("  Data archived       : {0}" -f (Format-Bytes $stats.BytesTrashed))
Write-Log ("  Elapsed time        : {0}" -f $elapsed)
Write-Log "----------------------------------------"
if ($stats.Trashed -gt 0 -and -not $DryRun) {
    Write-Log ("  Recover trashed files from: <drive>\{0}\{1}\" -f $TrashFolderName, $TimeStamp)
}

# Write the run log to Drive A (skip on dry run so nothing is touched).
if (-not $DryRun) {
    $logDir = Join-Path $DriveA $LogFolderName
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir "sync_$TimeStamp.log"
    $script:LogLines | Set-Content -LiteralPath $logFile -Encoding UTF8
    Write-Host ""
    Write-Host "Full log written to: $logFile" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------
# After a dry run, offer to immediately re-run for real on the same drives
# ---------------------------------------------------------------------
if ($DryRun) {
    Write-Log "DRY RUN - nothing was changed." "DRY"
    if ([Environment]::UserInteractive) {
        Write-Host ""
        $again = (Read-Host "Run again for REAL now and apply these changes? (y/n)").Trim().ToLower()
        if ($again -eq 'y' -or $again -eq 'yes') {
            Write-Host ""
            Write-Host "Re-running LIVE on the same drives..." -ForegroundColor Green
            $forward = @{ DriveA = $DriveA; DriveB = $DriveB; Mode = $Mode }
            if ($UseHash) { $forward['UseHash'] = $true }
            & $PSCommandPath @forward
        } else {
            Write-Log "Left as-is. Re-run without -DryRun whenever you're ready." "DRY"
        }
    } else {
        Write-Log "Re-run without -DryRun to apply." "DRY"
    }
} else {
    Write-Log "Sync complete." "DO"
}
