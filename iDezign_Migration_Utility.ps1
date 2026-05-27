#Requires -Version 5.1
# ============================================================================
#  iDezign_Migration_Utility.ps1
#  User-data migration for a new computer. NON-DESTRUCTIVE to the old PC.
#
#  Modes:
#    Backup  (OLD pc) - copy Desktop/Downloads/Documents/Pictures + Chrome
#                       bookmarks to a timestamped Backup_<stamp> folder,
#                       report folder sizes, Defender-scan the result.
#                       Target can be the Desktop OR straight onto removable
#                       media so NOTHING is left on the source machine.
#    Restore (NEW pc) - copy folders back; Downloads filtered to recent files
#                       only (default last 60 days). Chrome = sign in + Sync.
#
#  Chrome passwords ride along via Chrome Sync (sign in on the new PC). The
#  manual CSV export is opt-in (-ExportPasswords) for no-Google-account clients.
#
#  RUN IN THE CLIENT'S OWN LOGGED-IN SESSION. A built-in session guard stops
#  the tool if it's running as a different account than the logged-in user
#  (which would back up the wrong profile). The GUI launches tools elevated,
#  so on standard-user machines launch this from the user's own session.
# ============================================================================

[CmdletBinding()]
param(
    [ValidateSet('Backup','Restore')] [string]$Mode,
    [string]$Destination,        # backup: write straight here (removable/share); nothing left local
    [string]$BackupPath,         # restore: path to a Backup_<stamp> folder
    [int]$RecentDays = 60,
    [string[]]$RecentFolders = @('Downloads'),
    [switch]$SkipOnlineOnly,
    [switch]$ExportPasswords,
    [switch]$SkipScan,
    [int]$ScanTimeoutMin = 30
)

$ScriptVersion = '2026.05.26-migrate-v1'
$ErrorActionPreference = 'Continue'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

#region --- Load shared module (same pattern as the other tools) -------------
$modulePath = Join-Path $ScriptDir 'iDezign_Common.psm1'
if (Test-Path $modulePath) { Import-Module $modulePath -Force -ErrorAction SilentlyContinue }
else { Write-Host "WARNING: iDezign_Common.psm1 not found - running in standalone mode with built-in fallbacks." -ForegroundColor DarkYellow }

# Thin shims: use the shared Common function when present, else a local fallback
# so the tool still works off a bare USB stick without the rest of the toolkit.
function Show-Banner {
    param([string]$ToolName,[string]$Subtitle)
    if (Get-Command Get-iDezignBanner -ErrorAction SilentlyContinue) { Get-iDezignBanner -ToolName $ToolName -Subtitle $Subtitle }
    else {
        Write-Host ""; Write-Host "============================================================" -ForegroundColor Cyan
        Write-Host "  $ToolName  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
        if ($Subtitle) { Write-Host "  $Subtitle" -ForegroundColor Cyan }
        Write-Host "  Computer: $env:COMPUTERNAME   User: $env:USERNAME" -ForegroundColor DarkGray
        Write-Host "============================================================" -ForegroundColor Cyan
    }
}
function Show-Version {
    if (Get-Command Show-VersionCheck -ErrorAction SilentlyContinue) {
        Show-VersionCheck -ScriptName 'iDezign_Migration_Utility.ps1' -CurrentVersion $ScriptVersion -ScriptDir $ScriptDir
    } else {
        $mf = Join-Path $ScriptDir 'iDezign_Versions.json'
        if (Test-Path $mf) {
            try {
                $latest = (Get-Content -Raw $mf | ConvertFrom-Json).scripts.'iDezign_Migration_Utility.ps1'
                if     ($latest -and $latest -eq $ScriptVersion) { Write-Host "  [version] OK - latest (v$ScriptVersion)" -ForegroundColor Green }
                elseif ($latest -and $ScriptVersion -lt $latest)  { Write-Host "  [version] OUTDATED (this v$ScriptVersion, latest v$latest)" -ForegroundColor Yellow }
                elseif ($latest)                                  { Write-Host "  [version] v$ScriptVersion newer than manifest v$latest" -ForegroundColor Cyan }
            } catch { Write-Host "  [version] manifest unreadable." -ForegroundColor DarkGray }
        }
    }
}
function Confirm-YN {
    param([string]$Prompt)
    if (Get-Command Read-iDezignYN -ErrorAction SilentlyContinue) { return ((Read-iDezignYN -Prompt $Prompt) -eq 'Y') }
    return ((Read-Host "  $Prompt") -match '^(y|yes)$')
}
function Start-Log {
    param([string]$Directory,[string]$Prefix)
    if (Get-Command Start-iDezignTranscript -ErrorAction SilentlyContinue) { return (Start-iDezignTranscript -Directory $Directory -Prefix $Prefix) }
    $p = Join-Path $Directory ("{0}_{1}.log" -f $Prefix, (Get-Date -Format 'yyyy-MM-dd_HHmm'))
    try { Start-Transcript -Path $p -Force -ErrorAction Stop | Out-Null; return $p } catch { return $null }
}
#endregion

#region --- Local helpers -----------------------------------------------------
function Get-DownloadsPath {
    $guid = '{374DE290-123F-4565-9164-39C4925E467B}'
    $key  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $raw  = (Get-ItemProperty -Path $key -Name $guid -ErrorAction SilentlyContinue).$guid
    if ($raw) { return [Environment]::ExpandEnvironmentVariables($raw) }
    return (Join-Path $env:USERPROFILE 'Downloads')
}
function Format-Size {
    param([long]$Bytes)
    if     ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N2} MB' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N2} KB' -f ($Bytes / 1KB) }
    else                    { "$Bytes B" }
}
function Get-FolderSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $s = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($s) { [long]$s } else { [long]0 }
}
function Invoke-Robocopy {
    param([string]$Source, [string]$Dest, [string[]]$ExtraArgs = @())
    if (-not (Test-Path -LiteralPath $Source)) { Write-Host "  (source not found, skipping: $Source)" -ForegroundColor DarkYellow; return }
    $null = New-Item -ItemType Directory -Path $Dest -Force
    $rcArgs = @($Source, $Dest, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:2', '/XJ', '/MT:16', '/NP', '/NFL', '/NDL') + $ExtraArgs
    robocopy @rcArgs
    if ($LASTEXITCODE -ge 8) { Write-Host "  robocopy errors (exit $LASTEXITCODE): $Source" -ForegroundColor Yellow }
    else                     { Write-Host "  OK (robocopy exit $LASTEXITCODE)" -ForegroundColor DarkGray }
}
function Find-Chrome {
    foreach ($c in @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}
function Invoke-DefenderScan {
    param([string]$Path, [int]$TimeoutMin = 30)
    $mp = $null
    $platform = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
    if (Test-Path $platform) {
        $mp = Get-ChildItem $platform -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
              ForEach-Object { Join-Path $_.FullName 'MpCmdRun.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $mp) { $legacy = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'; if (Test-Path $legacy) { $mp = $legacy } }

    if ($mp) {
        try { Start-Process $mp -ArgumentList '-SignatureUpdate' -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue } catch { }
        Write-Host "  Scanning with Microsoft Defender (timeout ${TimeoutMin}m, large sets take a while)..." -ForegroundColor DarkGray
        # Quote the path for the joined argument string (Start-ProcessWithTimeout joins args with spaces).
        $scanArgs = @('-Scan','-ScanType','3','-File', ('"{0}"' -f $Path))
        if (Get-Command Start-ProcessWithTimeout -ErrorAction SilentlyContinue) {
            $rc = Start-ProcessWithTimeout -FilePath $mp -ArgumentList $scanArgs -TimeoutMinutes $TimeoutMin -Label 'Defender scan'
        } else {
            $p = Start-Process $mp -ArgumentList $scanArgs -WindowStyle Hidden -PassThru
            if (-not $p.WaitForExit($TimeoutMin * 60 * 1000)) { try { $p.Kill() } catch { }; $rc = -1 } else { $rc = $p.ExitCode }
        }
        switch ($rc) {
            0       { Write-Host "  Clean - no threats found." -ForegroundColor Green }
            2       { Write-Host "  THREATS FOUND in the backup. Do NOT migrate it until cleaned (Get-MpThreatDetection)." -ForegroundColor Red }
            -1      { Write-Host "  Scan timed out (>${TimeoutMin}m) and was stopped. Scan manually before migrating." -ForegroundColor Yellow }
            default { Write-Host "  Scan inconclusive (code $rc). Scan manually before migrating." -ForegroundColor Yellow }
        }
        return
    }
    if (Get-Command Start-MpScan -ErrorAction SilentlyContinue) {
        try {
            $t0 = Get-Date
            Start-MpScan -ScanType CustomScan -ScanPath $Path -ErrorAction Stop
            $hits = Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $t0 }
            if ($hits) { Write-Host "  THREATS FOUND - review before migrating." -ForegroundColor Red } else { Write-Host "  Clean - no threats found." -ForegroundColor Green }
        } catch { Write-Host "  Defender unavailable ($($_.Exception.Message)). Third-party AV may own protection - scan manually." -ForegroundColor Yellow }
        return
    }
    Write-Host "  No Microsoft Defender scanner found. Scan '$Path' with the installed AV before migrating." -ForegroundColor Yellow
}
function Show-DriveOptions {
    Write-Host "  Available drives (system drive excluded):" -ForegroundColor DarkGray
    try {
        Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and ("$($_.DriveLetter):" -ne $env:SystemDrive) } |
            ForEach-Object {
                $tag = if ($_.DriveType -eq 'Removable') { '[removable]' } else { "[$($_.DriveType)]" }
                Write-Host ("    {0}:  {1,-14} {2,10} free   {3}" -f $_.DriveLetter, ($_.FileSystemLabel), (Format-Size ([long]$_.SizeRemaining)), $tag) -ForegroundColor Gray
            }
    } catch { Write-Host "    (could not enumerate drives)" -ForegroundColor DarkYellow }
}
#endregion

Show-Banner -ToolName "iDezign Migration Utility  v$ScriptVersion" -Subtitle "User-data migration (non-destructive backup + restore)"
Show-Version

#region --- Session guard (right profile) ------------------------------------
$procUser = [Environment]::UserName
$consoleUser = $null
try { $cs = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName; if ($cs) { $consoleUser = ($cs -split '\\')[-1] } } catch { }
if ($consoleUser -and ($consoleUser -ne $procUser)) {
    Write-Host ""
    Write-Host "STOP - wrong user context." -ForegroundColor Red
    Write-Host "  This process is running as : $procUser" -ForegroundColor Yellow
    Write-Host "  The logged-in user is      : $consoleUser" -ForegroundColor Yellow
    Write-Host "  Backing up now would capture '$procUser' (the wrong profile)." -ForegroundColor Yellow
    Write-Host "  Run this in $consoleUser's own session (if they're an admin, UAC consent-elevates" -ForegroundColor Yellow
    Write-Host "  without switching accounts)." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"; exit 1
}
#endregion

#region --- Mode selection ----------------------------------------------------
if (-not $Mode) {
    Write-Host ""
    Write-Host "  [1] BACKUP   - this is the OLD computer (capture user data)"
    Write-Host "  [2] RESTORE  - this is the NEW computer (lay data back down)"
    switch (Read-Host "Select 1 or 2") { '1' { $Mode = 'Backup' } '2' { $Mode = 'Restore' } default { Write-Host "Aborted." -ForegroundColor Yellow; exit 0 } }
}
#endregion

#region --- BACKUP ------------------------------------------------------------
if ($Mode -eq 'Backup') {
    $desktop   = [Environment]::GetFolderPath('DesktopDirectory')
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $pictures  = [Environment]::GetFolderPath('MyPictures')
    $downloads = Get-DownloadsPath
    $stamp     = Get-Date -Format 'yyyy-MM-dd_HHmm'

    if (-not $Destination) {
        Write-Host "`nWhere should the backup go?" -ForegroundColor Green
        Write-Host "  [1] Straight to a removable/other drive - NOTHING left on this PC (recommended)"
        Write-Host "  [2] This computer's Desktop"
        if ((Read-Host "Select 1 or 2") -eq '1') {
            Show-DriveOptions
            $Destination = (Read-Host "  Enter destination path (e.g. E:\ or E:\Migrations or \\nas\moves)").Trim()
            if (-not $Destination) { Write-Host "No path given - aborting." -ForegroundColor Yellow; exit 0 }
        }
    }
    if ($Destination) { $null = New-Item -ItemType Directory -Path $Destination -Force; $BackupRoot = Join-Path $Destination "Backup_$stamp" }
    else              { $BackupRoot = Join-Path $desktop "Backup_$stamp" }
    $null = New-Item -ItemType Directory -Path $BackupRoot -Force

    # Pre-flight space check
    $srcBytes = 0; foreach ($s in $desktop,$downloads,$documents,$pictures) { $srcBytes += (Get-FolderSize $s) }
    try {
        $free = (Get-Item ([System.IO.Path]::GetPathRoot($BackupRoot)) -ErrorAction Stop).PSDrive.Free
        if ($free -and ($free -lt $srcBytes)) {
            Write-Host "`n  WARNING: target free space $(Format-Size $free) < data to copy $(Format-Size $srcBytes)." -ForegroundColor Yellow
            if (-not (Confirm-YN "Continue anyway? (Y/N)")) { Write-Host "Aborted." -ForegroundColor Yellow; exit 0 }
        } else { Write-Host "`n  Pre-flight: ~$(Format-Size $srcBytes) to copy, $(Format-Size $free) free at target. OK." -ForegroundColor DarkGray }
    } catch { }

    $log = Start-Log -Directory $BackupRoot -Prefix '_backup'
    Write-Host "`nBackup root: $BackupRoot" -ForegroundColor Cyan
    Write-Host "(Source data is COPIED only - nothing on this PC is deleted, moved, or renamed.)`n" -ForegroundColor DarkGray

    $online = @(); if ($SkipOnlineOnly) { $online = @('/XA:O') }

    Write-Host "[1/5] Desktop" -ForegroundColor Green
    Invoke-Robocopy -Source $desktop -Dest (Join-Path $BackupRoot 'Desktop') `
        -ExtraArgs (@('/XD', $BackupRoot, (Join-Path $desktop 'Backup_*'), '$RECYCLE.BIN', 'System Volume Information') + $online)
    Write-Host "[2/5] Downloads" -ForegroundColor Green
    Invoke-Robocopy -Source $downloads -Dest (Join-Path $BackupRoot 'Downloads') -ExtraArgs $online
    Write-Host "[3/5] Documents" -ForegroundColor Green
    Invoke-Robocopy -Source $documents -Dest (Join-Path $BackupRoot 'Documents') -ExtraArgs $online
    Write-Host "[4/5] Pictures" -ForegroundColor Green
    Invoke-Robocopy -Source $pictures -Dest (Join-Path $BackupRoot 'Pictures') -ExtraArgs $online

    Write-Host "[5/5] Google Chrome" -ForegroundColor Green
    $googleDir = Join-Path $BackupRoot 'Google Backup'; $null = New-Item -ItemType Directory -Path $googleDir -Force
    $userData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
    if (Test-Path -LiteralPath $userData) {
        Get-ChildItem -LiteralPath $userData -Directory | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object {
            $bm = Join-Path $_.FullName 'Bookmarks'
            if (Test-Path -LiteralPath $bm) {
                Copy-Item -LiteralPath $bm -Destination (Join-Path $googleDir ("{0}_Bookmarks.json" -f $_.Name)) -Force
                Write-Host "  Saved bookmarks (fallback copy): $($_.Name)" -ForegroundColor DarkGray
            }
        }
    } else { Write-Host "  Chrome user data not found." -ForegroundColor DarkYellow }

    if ($ExportPasswords) {
        Write-Host "`n  >>> MANUAL: export passwords (no-Google-account clients only) <<<" -ForegroundColor Yellow
        Write-Host "    Chrome > Password Manager > Settings > Export passwords, authenticate, save as:"
        Write-Host "      $(Join-Path $googleDir 'ChromePasswords.csv')" -ForegroundColor White
        $chrome = Find-Chrome; if ($chrome) { Start-Process $chrome 'chrome://password-manager/settings' }
    } else {
        Write-Host "  Chrome plan: sign in + turn on Sync on the new PC. Bookmarks AND passwords" -ForegroundColor DarkGray
        Write-Host "  come down automatically - no file, set it and forget it." -ForegroundColor DarkGray
    }

    Write-Host "`n--- Folder sizes ---" -ForegroundColor Cyan
    $rows = foreach ($n in 'Desktop','Downloads','Documents','Pictures','Google Backup') {
        $sz = Get-FolderSize (Join-Path $BackupRoot $n)
        [pscustomobject]@{ Folder = $n; Size = (Format-Size $sz); Bytes = $sz }
    }
    $rows | Format-Table Folder, Size -AutoSize | Out-Host
    Write-Host ("Total: {0}" -f (Format-Size (($rows | Measure-Object Bytes -Sum).Sum))) -ForegroundColor White

    if (-not $SkipScan) { Write-Host "`n--- Virus scan ---" -ForegroundColor Cyan; Invoke-DefenderScan -Path $BackupRoot -TimeoutMin $ScanTimeoutMin }
    else                { Write-Host "`n(Virus scan skipped.)" -ForegroundColor DarkGray }

    Write-Host "`nBackup complete." -ForegroundColor Cyan
    if ($Destination) { Write-Host "On the removable/destination drive - nothing left on this PC:" -ForegroundColor Green }
    else              { Write-Host "On the Desktop:" -ForegroundColor Green }
    Write-Host "  $BackupRoot"
    try { Stop-Transcript | Out-Null } catch { }
}
#endregion

#region --- RESTORE -----------------------------------------------------------
if ($Mode -eq 'Restore') {
    if (-not $BackupPath) { $BackupPath = (Read-Host "Path to the Backup_<stamp> folder (you can paste it)").Trim('"').Trim() }
    if (-not (Test-Path -LiteralPath $BackupPath)) { Write-Host "Backup path not found: $BackupPath" -ForegroundColor Red; exit 1 }

    $destDesktop   = [Environment]::GetFolderPath('DesktopDirectory')
    $destDocuments = [Environment]::GetFolderPath('MyDocuments')
    $destPictures  = [Environment]::GetFolderPath('MyPictures')
    $destDownloads = Get-DownloadsPath

    $log = Start-Log -Directory $BackupPath -Prefix '_restore'
    Write-Host "`nRestoring from: $BackupPath" -ForegroundColor Cyan
    Write-Host "Downloads filtered to last $RecentDays days; other folders restored in full.`n" -ForegroundColor DarkGray

    $map = @(
        @{ Name='Desktop';   Src=(Join-Path $BackupPath 'Desktop');   Dst=$destDesktop   }
        @{ Name='Documents'; Src=(Join-Path $BackupPath 'Documents'); Dst=$destDocuments }
        @{ Name='Pictures';  Src=(Join-Path $BackupPath 'Pictures');  Dst=$destPictures  }
        @{ Name='Downloads'; Src=(Join-Path $BackupPath 'Downloads'); Dst=$destDownloads }
    )
    foreach ($m in $map) {
        Write-Host "[$($m.Name)]" -ForegroundColor Green
        $extra = @()
        if ($RecentFolders -contains $m.Name) { $extra = @("/MAXAGE:$RecentDays"); Write-Host "  (recent only: last $RecentDays days)" -ForegroundColor Yellow }
        Invoke-Robocopy -Source $m.Src -Dest $m.Dst -ExtraArgs $extra
    }

    Write-Host "`n[Google Chrome]" -ForegroundColor Green
    Write-Host "  PRIMARY: open Chrome, sign into the client's Google account, turn on Sync." -ForegroundColor White
    Write-Host "  Bookmarks, passwords, autofill, extensions all come down automatically." -ForegroundColor DarkGray
    $csv = Join-Path $BackupPath 'Google Backup\ChromePasswords.csv'
    if (Test-Path -LiteralPath $csv) {
        Write-Host "  FALLBACK (no Google account): Password Manager > Settings > Import:" -ForegroundColor DarkGray
        Write-Host "    $csv" -ForegroundColor White
        Write-Host "    Then securely wipe it:  cipher /w:`"$(Split-Path $csv)`"" -ForegroundColor Yellow
    }

    Write-Host "`nRestore complete." -ForegroundColor Cyan
    try { Stop-Transcript | Out-Null } catch { }
}
#endregion
