# ============================================================================
#  iDezign_Diagnostics.ps1
#  Read-only health check for sick / suspect Windows machines.
#  Run as Administrator. Makes NO changes to the system.
# ============================================================================
#  Outputs:
#   * Text report  : C:\iDezign_Diagnostics\Diagnostics_Latest.txt
#   * HTML report  : C:\iDezign_Diagnostics\Diagnostics_Latest.html
#   * JSON snapshot: C:\iDezign_Diagnostics\snapshots\Snapshot_YYYY-MM-DD_HHmm.json
#   * On-screen colored summary with "Top issues" ranking
#
#  Previous Latest reports are auto-archived to:
#   * C:\iDezign_Diagnostics\Diagnostics_YYYY-MM-DD_HHmm.html  (etc.)
#  using the OLD report's generation time, before the new run overwrites Latest.
#  The HTML report auto-opens in the default browser at end of run.
#
#  Sections:
#   1. System snapshot       (OS, model, BIOS, TPM, uptime, activation, clock)
#   2. Disk health           (SMART, free space, BitLocker)
#   3. Memory & CPU pressure (live samples, top processes)
#   4. Recent events         (event log errors, hotfixes, crashes)
#   5. Services              (stopped auto-start, non-Microsoft running)
#   6. Network               (adapters, DNS, gateway, TCP probe, profiles, sharing)
#   7. Security              (Defender, firewall, threats, exclusions, tasks)
#   8. Performance hotspots  (disk queue, I/O, network connections)
#   9. Pending state         (CBS/WU/file rename flags)
#  10. Dentrix-specific      (only if Dentrix is detected)
#  11. Remote support        (TeamViewer host status)
#  12. iDezign Configuration Verification (baseline check - power, network,
#                            apps, REPAIR account, exclusions, naming)
#  13. Server-specific checks (if Server OS detected, runs in addition)
#  + Compare to last run     (if a prior snapshot exists)
#
#  This script is READ-ONLY. It does not modify the system in any way.
# ============================================================================

#region --- Safety + setup ---------------------------------------------------

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Use Run-Diagnostics.bat (it self-elevates) or right-click -> Run with PowerShell as Admin." -ForegroundColor Yellow
    Pause
    exit 1
}

$ErrorActionPreference = 'Continue'

# Version stamp - bumped whenever the HTML report format changes.
# Visible in the HTML report header so we can verify deployed version at a glance.
$ScriptVersion = '2026.05.19-migrate-svc-net-sec'

# Load shared module if present (non-fatal if missing - the script has its
# own copy of needed functions as fallback).
$ModulePath = Join-Path $PSScriptRoot 'iDezign_Common.psm1'
if (Test-Path $ModulePath) {
    Import-Module $ModulePath -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "(note: iDezign_Common.psm1 not found alongside script - using built-in functions)" -ForegroundColor DarkYellow
}

# Version check at startup - confirm this is the latest copy vs the manifest.
if (Get-Command Show-VersionCheck -ErrorAction SilentlyContinue) {
    Show-VersionCheck -ScriptName 'iDezign_Diagnostics.ps1' `
                      -CurrentVersion $ScriptVersion `
                      -ScriptDir $PSScriptRoot
}

# Detect server OS - used to skip workstation-specific checks and adjust
# thresholds (e.g. uptime on a file server is expected to be high).
$ServerInfo = $null
if (Get-Command Get-ServerOSDetails -ErrorAction SilentlyContinue) {
    $ServerInfo = Get-ServerOSDetails
} else {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $ServerInfo = @{
            IsServer       = ($os.ProductType -eq 2 -or $os.ProductType -eq 3)
            IsDC           = ($os.ProductType -eq 2)
            OSCaption      = $os.Caption
            OSVersion      = $os.Version
            IsDomainJoined = [bool]$cs.PartOfDomain
            DomainName     = $cs.Domain
            InstalledRoles = @()
        }
    } catch {
        $ServerInfo = @{ IsServer = $false; IsDC = $false }
    }
}
$IsServer = [bool]$ServerInfo.IsServer
$IsDC     = [bool]$ServerInfo.IsDC

$OutputDir   = 'C:\iDezign_Diagnostics'
$SnapshotDir = Join-Path $OutputDir 'snapshots'
$Timestamp   = Get-Date -Format 'yyyy-MM-dd_HHmm'

# --- File naming strategy ---
# Reports are always written to the SAME filename ("Diagnostics_Latest.html"
# / .txt) so techs always know where the current report is. Before writing
# the new run, if a Latest file already exists, it's renamed using ITS OWN
# write timestamp - that way the archive name reflects when that report
# was actually generated, not when we're archiving it now. This gives:
#   * Diagnostics_Latest.html        <- always the most recent
#   * Diagnostics_2026-05-15_1430.html <- previous run, dated
#   * Diagnostics_2026-05-10_0912.html <- run before that, dated
# Snapshot JSON keeps the dated-only naming because it's specifically for
# point-in-time historical comparison (see "Compare to last run" section).
$ReportTxt   = Join-Path $OutputDir  "Diagnostics_Latest.txt"
$ReportHtml  = Join-Path $OutputDir  "Diagnostics_Latest.html"
$SnapshotFn  = Join-Path $SnapshotDir "Snapshot_$Timestamp.json"

# Create output dirs
if (-not (Test-Path $OutputDir))   { New-Item -Path $OutputDir   -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $SnapshotDir)) { New-Item -Path $SnapshotDir -ItemType Directory -Force | Out-Null }

# --- Archive any existing Latest reports before we overwrite ---
# Both .html and .txt are archived using THEIR LastWriteTime, not the current
# script run time - so the archive name reflects when that older report was
# actually generated. If the rename fails (file locked, permissions), we
# fall through to overwrite mode and log a warning.
function Move-LatestToArchive {
    param(
        [string]$LatestPath,
        [string]$ArchivePrefix = 'Diagnostics'
    )
    if (-not (Test-Path $LatestPath)) { return }
    try {
        $latestFile = Get-Item -LiteralPath $LatestPath -ErrorAction Stop
        $archiveStamp = $latestFile.LastWriteTime.ToString('yyyy-MM-dd_HHmm')
        $ext = $latestFile.Extension  # includes the dot, e.g. '.html'
        $archiveName = "${ArchivePrefix}_${archiveStamp}${ext}"
        $archivePath = Join-Path (Split-Path $LatestPath -Parent) $archiveName
        # If archive target somehow exists (re-run within same minute), add seconds
        if (Test-Path $archivePath) {
            $archiveStamp = $latestFile.LastWriteTime.ToString('yyyy-MM-dd_HHmmss')
            $archiveName = "${ArchivePrefix}_${archiveStamp}${ext}"
            $archivePath = Join-Path (Split-Path $LatestPath -Parent) $archiveName
        }
        Move-Item -LiteralPath $LatestPath -Destination $archivePath -ErrorAction Stop
        Write-Host "  Archived previous report -> $archiveName" -ForegroundColor DarkGray
    } catch {
        Write-Host "  Could not archive $LatestPath - will overwrite. Error: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

Move-LatestToArchive -LatestPath $ReportHtml
Move-LatestToArchive -LatestPath $ReportTxt

$ScriptStart = Get-Date

# Findings collection - each section adds verdict + details + flags here
# Verdict: 'OK', 'ATTENTION', 'CRITICAL'
# Severity (for Top Issues ranking): 0=info, 1=attention, 2=critical
$Findings = New-Object System.Collections.Generic.List[object]
$Snapshot = [ordered]@{}

function Add-Finding {
    param(
        [string]$Section,
        [ValidateSet('OK','ATTENTION','CRITICAL')] [string]$Verdict,
        [string]$Headline,
        [array]$Details = @(),
        [array]$Issues = @()    # specific issue strings for Top Issues ranking
    )
    $Findings.Add([PSCustomObject]@{
        Section  = $Section
        Verdict  = $Verdict
        Headline = $Headline
        Details  = $Details
        Issues   = $Issues
        Severity = switch ($Verdict) { 'CRITICAL' {2} 'ATTENTION' {1} default {0} }
    })
}

# A detail line can be a plain string OR a severity-tagged object created by
# New-Detail. The tagged form is preferred for new/edited code because the
# color comes from EXPLICIT metadata rather than guessing from the text - no
# risk of a line like "0 errors found" lighting up red by accident.
#
# Sections that still emit plain strings keep working unchanged: the HTML
# renderer falls back to text pattern-matching for any line that isn't tagged.
#
# Severity values:
#   fail  -> red    (a real problem - failed check, missing requirement)
#   warn  -> amber  (worth attention but not a hard failure)
#   pass  -> green  (an explicit good result, e.g. a baseline check that matches)
#   info  -> default gray (neutral informational line)
#   plain -> default gray (same as info; the default)
function New-Detail {
    param(
        [string]$Text,
        [ValidateSet('fail','warn','pass','info','plain')]
        [string]$Severity = 'plain'
    )
    [PSCustomObject]@{
        PSTypeName = 'iDezign.DetailLine'
        Text       = $Text
        Severity   = $Severity
    }
}

# Extract the plain-text of a detail line whether it's a tagged object or a
# raw string. Used by the .txt report (and anywhere that wants text only).
function Get-DetailText {
    param($Line)
    if ($Line -is [string]) { return $Line }
    if ($null -ne $Line.Text) { return [string]$Line.Text }
    return [string]$Line
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  [$Title]" -ForegroundColor Cyan
}

#endregion

#region --- Banner -----------------------------------------------------------

Clear-Host
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  iDezign Diagnostics - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "  Version: $ScriptVersion$(if(Get-Command Get-iDezignCommonVersion -EA SilentlyContinue){"  |  module: $(Get-iDezignCommonVersion)"})" -ForegroundColor DarkGray
Write-Host "  Computer: $env:COMPUTERNAME   User: $env:USERNAME" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  This is a READ-ONLY diagnostic. No changes will be made." -ForegroundColor DarkGray
Write-Host "  Expect ~30-60 seconds to complete." -ForegroundColor DarkGray
Write-Host "============================================================" -ForegroundColor Cyan

# Big yellow server banner if applicable. Diagnostics is read-only, so the
# warning is informational - no destructive operations to disable.
if ($IsServer) {
    if (Get-Command Show-ServerWarning -ErrorAction SilentlyContinue) {
        Show-ServerWarning -ServerInfo $ServerInfo -ToolName 'Diagnostics' `
                           -Gated @(
                               'Uptime threshold relaxed (60 days instead of 30)',
                               'TPM/BitLocker not flagged (often missing on servers)',
                               'Server-specific section added at end'
                           )
    }
}

#endregion

#region --- 1. System snapshot -----------------------------------------------

Write-Section "1/12  System snapshot"

try {
    $os    = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cs    = Get-CimInstance Win32_ComputerSystem  -ErrorAction Stop
    $bios  = Get-CimInstance Win32_BIOS            -ErrorAction Stop

    $uptimeSpan = (Get-Date) - $os.LastBootUpTime
    $uptimeStr  = "$([int]$uptimeSpan.TotalDays)d $($uptimeSpan.Hours)h $($uptimeSpan.Minutes)m"

    $installDate = $os.InstallDate
    $installAge  = [int]((Get-Date) - $installDate).TotalDays
    $installAgeYears = [math]::Round($installAge / 365.25, 1)
    $installAgeStr  = "$installAge days ($installAgeYears years)"

    $biosAgeDays = $null
    try {
        $biosDate    = [Management.ManagementDateTimeConverter]::ToDateTime($bios.ReleaseDate)
        $biosAgeDays = [int]((Get-Date) - $biosDate).TotalDays
    } catch { }

    # TPM
    $tpmPresent = $false
    $tpmReady   = $false
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $tpmPresent = $tpm.TpmPresent
        $tpmReady   = $tpm.TpmReady
    } catch { }

    # Secure Boot
    $secureBoot = $null
    try { $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop } catch { $secureBoot = $false }

    $sysDetails = @(
        "OS              : $($os.Caption) ($($os.Version) build $($os.BuildNumber))"
        "Manufacturer    : $($cs.Manufacturer)"
        "Model           : $($cs.Model)"
        "Serial          : $($bios.SerialNumber)"
        "BIOS version    : $($bios.SMBIOSBIOSVersion) (release $(if($biosAgeDays){"$biosAgeDays days old"}else{'unknown'}))"
        "Install date    : $($installDate.ToString('yyyy-MM-dd')) (Age: $installAgeStr)"
        "Last boot       : $($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm'))"
        "Uptime          : $uptimeStr"
        "TPM present     : $tpmPresent  /  Ready: $tpmReady"
        "Secure Boot     : $secureBoot"
    )

    $verdict = 'OK'
    $issues  = @()
    # Servers are expected to have long uptime - relax the threshold there.
    $uptimeThresholdDays = if ($IsServer) { 60 } else { 30 }
    if ($uptimeSpan.TotalDays -gt $uptimeThresholdDays) {
        $verdict = 'ATTENTION'
        $issues += "Uptime over $uptimeThresholdDays days ($([int]$uptimeSpan.TotalDays) days) - reboot may be overdue"
    }
    if ($biosAgeDays -and $biosAgeDays -gt 1825) {  # 5 years
        if ($verdict -eq 'OK') { $verdict = 'ATTENTION' }
        $issues += "BIOS is over 5 years old - check for vendor firmware update"
    }
    # Aging Windows install - candidate for reimage rather than indefinite patching.
    if ($installAge -gt 1825) {  # 5 years
        if ($verdict -eq 'OK') { $verdict = 'ATTENTION' }
        $issues += "Windows install is over 5 years old ($installAgeYears years) - consider reimage for stability"
    }

    # --- Windows activation status (inline read-only check) ---
    # Unactivated Windows can refuse Windows Update, refuse some installs, and
    # nag users. Useful diagnostic info even when not a critical fail.
    $actStatus = 'unknown'
    try {
        $actLic = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
                  Where-Object { $_.PartialProductKey -and $_.Name -like 'Windows*' } |
                  Select-Object -First 1
        if ($actLic) {
            $actStatus = switch ([int]$actLic.LicenseStatus) {
                0 { 'Unlicensed' }
                1 { 'Licensed (activated)' }
                2 { 'OOB Grace period' }
                3 { 'OOT Grace period' }
                4 { 'Non-Genuine Grace' }
                5 { 'Notification mode (not activated)' }
                6 { 'Extended Grace period' }
                default { "Unknown ($($actLic.LicenseStatus))" }
            }
            $sysDetails += ""
            $sysDetails += "Activation:"
            $sysDetails += "  Status        : $actStatus"
            $sysDetails += "  Edition       : $($actLic.Description)"
            $sysDetails += "  Partial key   : $($actLic.PartialProductKey)"
            if ($actLic.LicenseStatus -ne 1) {
                if ($verdict -eq 'OK') { $verdict = 'ATTENTION' }
                $issues += "Windows activation status: $actStatus"
            }
        }
    } catch { }

    # --- System clock + time sync status (read-only) ---
    # We DON'T call Sync-SystemTime here - that's a write operation. Just
    # report current state via w32tm. Wildly wrong year is a critical flag.
    try {
        $currentTime = Get-Date
        $tzId = try { (Get-TimeZone).Id } catch { 'unknown' }
        $sysDetails += ""
        $sysDetails += "System clock:"
        $sysDetails += "  Local time    : $($currentTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        $sysDetails += "  Time zone     : $tzId"

        # Parse w32tm /query /status for richer info
        try {
            $w32output = & w32tm.exe /query /status 2>&1 | Out-String
            $sourceLine = ($w32output -split "`r?`n") | Where-Object { $_ -match '^\s*Source:' } | Select-Object -First 1
            $lastSyncLine = ($w32output -split "`r?`n") | Where-Object { $_ -match '^\s*Last Successful Sync Time:' } | Select-Object -First 1
            $strataLine = ($w32output -split "`r?`n") | Where-Object { $_ -match '^\s*Stratum:' } | Select-Object -First 1
            if ($sourceLine)   { $sysDetails += "  Time source   : $($sourceLine.Trim() -replace '^Source:\s*','')" }
            if ($strataLine)   { $sysDetails += "  $($strataLine.Trim())" }
            if ($lastSyncLine) { $sysDetails += "  $($lastSyncLine.Trim())" }
        } catch { }

        # Sanity-check year - dead CMOS battery or wedged NTP shows up here
        $year = $currentTime.Year
        if ($year -lt 2025 -or $year -gt 2035) {
            $verdict = 'CRITICAL'
            $issues += "System year is $year - clock is wildly wrong (CMOS battery? NTP unreachable?)"
        }
    } catch { }

    Add-Finding -Section "System snapshot" -Verdict $verdict `
                -Headline "$($os.Caption) build $($os.BuildNumber), $uptimeStr uptime" `
                -Details $sysDetails -Issues $issues

    $Snapshot['System'] = @{
        OS         = $os.Caption
        Build      = $os.BuildNumber
        Model      = $cs.Model
        Serial     = $bios.SerialNumber
        UptimeDays = [int]$uptimeSpan.TotalDays
        InstallAge = $installAge
        Activation = $actStatus
        Year       = (Get-Date).Year
    }
} catch {
    Add-Finding -Section "System snapshot" -Verdict 'ATTENTION' `
                -Headline "Could not gather system info" `
                -Details @("Error: $($_.Exception.Message)")
}

Write-Host "    done." -ForegroundColor DarkGray

#endregion

#region --- 2. Disk health ---------------------------------------------------

Write-Section "2/12  Disk health"

try {
    $disks  = Get-PhysicalDisk -ErrorAction Stop
    $vols   = Get-Volume       -ErrorAction Stop | Where-Object DriveLetter
    $blocks = $null
    try { $blocks = Get-BitLockerVolume -ErrorAction Stop } catch { }

    $verdict     = 'OK'
    $issues      = @()
    $diskDetails = @()
    $volDetails  = @()
    $snapDisks   = @()
    $snapVols    = @()

    foreach ($d in $disks) {
        $rel = $null
        try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }

        $wear = if ($rel.Wear) { "$($rel.Wear)%" } else { 'n/a' }
        $temp = if ($rel.Temperature) { "$($rel.Temperature)C" } else { 'n/a' }
        $rerr = if ($null -ne $rel.ReadErrorsTotal)  { $rel.ReadErrorsTotal  } else { 'n/a' }
        $werr = if ($null -ne $rel.WriteErrorsTotal) { $rel.WriteErrorsTotal } else { 'n/a' }

        $diskDetails += "Disk: $($d.FriendlyName)  [$($d.MediaType), $([math]::Round($d.Size/1GB,0))GB]"
        $diskDetails += "  Health=$($d.HealthStatus)  Op=$($d.OperationalStatus)  Wear=$wear  Temp=$temp  ReadErr=$rerr  WriteErr=$werr"

        $snapDisks += @{
            Name=$d.FriendlyName; Media=$d.MediaType; SizeGB=[math]::Round($d.Size/1GB,0)
            Health=$d.HealthStatus; Wear=$rel.Wear; Temp=$rel.Temperature
            ReadErrors=$rel.ReadErrorsTotal; WriteErrors=$rel.WriteErrorsTotal
        }

        if ($d.HealthStatus -ne 'Healthy') {
            $verdict = 'CRITICAL'
            $issues += "Disk '$($d.FriendlyName)' health = $($d.HealthStatus) - BACKUP IMMEDIATELY"
        }
        if ($rel.Wear -and [int]$rel.Wear -ge 80) {
            $verdict = 'CRITICAL'
            $issues += "SSD '$($d.FriendlyName)' wear = $($rel.Wear)% - replace soon"
        } elseif ($rel.Wear -and [int]$rel.Wear -ge 60) {
            if ($verdict -eq 'OK') { $verdict = 'ATTENTION' }
            $issues += "SSD '$($d.FriendlyName)' wear = $($rel.Wear)% - monitor"
        }
        if ($rel.Temperature -and [int]$rel.Temperature -ge 70) {
            if ($verdict -ne 'CRITICAL') { $verdict = 'ATTENTION' }
            $issues += "Disk '$($d.FriendlyName)' temp = $($rel.Temperature)C - check cooling"
        }
        if ($rerr -ne 'n/a' -and [int]$rerr -gt 0) {
            if ($verdict -ne 'CRITICAL') { $verdict = 'ATTENTION' }
            $issues += "Disk '$($d.FriendlyName)' has $rerr read errors logged"
        }
    }

    foreach ($v in $vols) {
        $freePct = if ($v.Size -gt 0) { [math]::Round(($v.SizeRemaining / $v.Size) * 100, 1) } else { 0 }
        $blState = ($blocks | Where-Object { $_.MountPoint -eq "$($v.DriveLetter):" }).VolumeStatus
        $blStr   = if ($blState) { $blState } else { 'n/a' }

        $volDetails += "Volume $($v.DriveLetter): [$($v.FileSystemLabel)]  $([math]::Round($v.SizeRemaining/1GB,1))GB free of $([math]::Round($v.Size/1GB,1))GB ($freePct%)  Health=$($v.HealthStatus)  BitLocker=$blStr"

        $snapVols += @{
            Letter=$v.DriveLetter; Label=$v.FileSystemLabel; SizeGB=[math]::Round($v.Size/1GB,1)
            FreeGB=[math]::Round($v.SizeRemaining/1GB,1); FreePct=$freePct
            Health=$v.HealthStatus; BitLocker=$blStr
        }

        if ($freePct -lt 5) {
            $verdict = 'CRITICAL'
            $issues += "Volume $($v.DriveLetter): only $freePct% free - URGENT"
        } elseif ($freePct -lt 15) {
            if ($verdict -ne 'CRITICAL') { $verdict = 'ATTENTION' }
            $issues += "Volume $($v.DriveLetter): only $freePct% free - cleanup needed"
        }
        if ($v.HealthStatus -ne 'Healthy') {
            $verdict = 'CRITICAL'
            $issues += "Volume $($v.DriveLetter): health = $($v.HealthStatus)"
        }
    }

    $headline = "$($disks.Count) physical disk(s), $($vols.Count) volume(s)"
    Add-Finding -Section "Disk health" -Verdict $verdict -Headline $headline `
                -Details ($diskDetails + @('') + $volDetails) -Issues $issues

    $Snapshot['Disks']   = $snapDisks
    $Snapshot['Volumes'] = $snapVols
} catch {
    Add-Finding -Section "Disk health" -Verdict 'ATTENTION' `
                -Headline "Disk inventory failed" -Details @("Error: $($_.Exception.Message)")
}

Write-Host "    done." -ForegroundColor DarkGray

#endregion

#region --- 3. Memory & CPU pressure ----------------------------------------

Write-Section "3/12  Memory & CPU pressure (sampling 5 sec...)"

try {
    $os2     = Get-CimInstance Win32_OperatingSystem
    $totalMB = [math]::Round($os2.TotalVisibleMemorySize / 1024, 0)
    $freeMB  = [math]::Round($os2.FreePhysicalMemory     / 1024, 0)
    $usedPct = [math]::Round((($totalMB - $freeMB) / $totalMB) * 100, 1)

    # 5-second CPU average (3 samples, 2 sec apart)
    $cpuSamples = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 2 -MaxSamples 3 -ErrorAction Stop
    $cpuAvg     = [math]::Round(($cpuSamples.CounterSamples.CookedValue | Measure-Object -Average).Average, 1)

    # Top processes
    $topMem = Get-Process | Sort-Object WS  -Descending | Select-Object -First 5 Name, Id, @{N='RAM_MB';E={[math]::Round($_.WS/1MB,0)}}
    $topCpu = Get-Process | Sort-Object CPU -Descending | Where-Object CPU -gt 0 | Select-Object -First 5 Name, Id, @{N='CPU_Total_Sec';E={[math]::Round($_.CPU,0)}}

    $details = @(
        "RAM       : $freeMB MB free / $totalMB MB total ($usedPct% used)"
        "CPU avg   : $cpuAvg% (5-sec sample)"
        ""
        "Top 5 by RAM:"
    )
    $details += ($topMem | ForEach-Object { "  {0,-25} PID {1,-7} {2,8} MB" -f $_.Name, $_.Id, $_.RAM_MB })
    $details += ""
    $details += "Top 5 by lifetime CPU seconds:"
    $details += ($topCpu | ForEach-Object { "  {0,-25} PID {1,-7} {2,8} sec" -f $_.Name, $_.Id, $_.CPU_Total_Sec })

    $verdict = 'OK'
    $issues  = @()
    if ($freeMB -lt 512) {
        $verdict = 'CRITICAL'
        $issues += "Only $freeMB MB RAM free - system is under severe pressure"
    } elseif ($freeMB -lt 1024) {
        $verdict = 'ATTENTION'
        $issues += "Only $freeMB MB RAM free - check top processes"
    }
    if ($cpuAvg -ge 90) {
        $verdict = 'CRITICAL'
        $issues += "CPU sustained at $cpuAvg% - find runaway process"
    } elseif ($cpuAvg -ge 70) {
        if ($verdict -eq 'OK') { $verdict = 'ATTENTION' }
        $issues += "CPU at $cpuAvg% - elevated"
    }
    # Single process eating > 50% of RAM
    $bigGlut = $topMem | Where-Object { $_.RAM_MB -gt ($totalMB * 0.5) }
    if ($bigGlut) {
        if ($verdict -eq 'OK') { $verdict = 'ATTENTION' }
        foreach ($g in $bigGlut) {
            $issues += "$($g.Name) using $($g.RAM_MB) MB (>50% of total RAM)"
        }
    }

    Add-Finding -Section "Memory & CPU" -Verdict $verdict `
                -Headline "$freeMB MB RAM free, CPU avg $cpuAvg%" -Details $details -Issues $issues

    $Snapshot['MemoryCPU'] = @{
        TotalRAM_MB = $totalMB; FreeRAM_MB = $freeMB; UsedPct = $usedPct
        CPUavg = $cpuAvg
        TopRAM = ($topMem | ForEach-Object { @{Name=$_.Name; MB=$_.RAM_MB} })
    }
} catch {
    Add-Finding -Section "Memory & CPU" -Verdict 'ATTENTION' `
                -Headline "Sampling failed" -Details @("Error: $($_.Exception.Message)")
}

Write-Host "    done." -ForegroundColor DarkGray

#endregion

#region --- 4. Recent events ------------------------------------------------

Write-Section "4/12  Recent events (last 7 days)"

try {
    $since = (Get-Date).AddDays(-7)

    $sysCritErr = Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=$since} -MaxEvents 200 -ErrorAction SilentlyContinue
    $appCritErr = Get-WinEvent -FilterHashtable @{LogName='Application'; Level=1,2; StartTime=$since} -MaxEvents 200 -ErrorAction SilentlyContinue

    # Group by Event ID + Provider to spot recurring issues
    $sysGroups = $sysCritErr | Group-Object Id, ProviderName | Sort-Object Count -Descending | Select-Object -First 5
    $appGroups = $appCritErr | Group-Object Id, ProviderName | Sort-Object Count -Descending | Select-Object -First 5

    $hotfixes = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 5
    $crashDumps = Get-ChildItem 'C:\Windows\Minidump' -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since

    # Event ID 41 = unexpected shutdown (kernel-power) - serious signal
    $unexpectedShutdown = $sysCritErr | Where-Object Id -eq 41

    $details = @()
    $details += "System log errors (7 days): $($sysCritErr.Count)"
    if ($sysGroups) {
        $details += "  Top recurring:"
        $details += ($sysGroups | ForEach-Object { "    {0,3}x  ID {1}  ({2})" -f $_.Count, ($_.Name -split ',')[0], (($_.Name -split ',')[1].Trim()) })
    }
    $details += ""
    $details += "Application log errors (7 days): $($appCritErr.Count)"
    if ($appGroups) {
        $details += "  Top recurring:"
        $details += ($appGroups | ForEach-Object { "    {0,3}x  ID {1}  ({2})" -f $_.Count, ($_.Name -split ',')[0], (($_.Name -split ',')[1].Trim()) })
    }
    $details += ""
    $details += "Unexpected shutdowns (Event 41) in last 7 days: $($unexpectedShutdown.Count)"
    $details += "Crash dumps in C:\Windows\Minidump (7 days): $($crashDumps.Count)"
    $details += ""
    $details += "Last 5 hotfixes:"
    $details += ($hotfixes | ForEach-Object { "  $($_.HotFixID)  $($_.Description)  $(if($_.InstalledOn){$_.InstalledOn.ToString('yyyy-MM-dd')}else{'date unknown'})" })

    $verdict = 'OK'
    $issues  = @()
    if ($unexpectedShutdown.Count -ge 1) {
        $verdict = 'CRITICAL'
        $issues += "$($unexpectedShutdown.Count) unexpected shutdown(s) in 7 days (PSU/RAM/overheat suspect)"
    }
    if ($crashDumps.Count -ge 1) {
        if ($verdict -ne 'CRITICAL') { $verdict = 'ATTENTION' }
        $issues += "$($crashDumps.Count) BSOD crash dump(s) in last 7 days"
    }
    if ($sysCritErr.Count -gt 100) {
        if ($verdict -eq 'OK') { $verdict = 'ATTENTION' }
        $issues += "High system error volume: $($sysCritErr.Count) in 7 days"
    }

    Add-Finding -Section "Recent events" -Verdict $verdict `
                -Headline "$($sysCritErr.Count) sys / $($appCritErr.Count) app errors, $($crashDumps.Count) BSODs" `
                -Details $details -Issues $issues

    $Snapshot['Events'] = @{
        SystemErrors7d=$sysCritErr.Count; AppErrors7d=$appCritErr.Count
        UnexpectedShutdowns=$unexpectedShutdown.Count; CrashDumps=$crashDumps.Count
    }
} catch {
    Add-Finding -Section "Recent events" -Verdict 'ATTENTION' `
                -Headline "Event log query failed" -Details @("Error: $($_.Exception.Message)")
}

Write-Host "    done." -ForegroundColor DarkGray

#endregion

#region --- 5. Services ------------------------------------------------------

Write-Section "5/12  Services"

try {
    $svcs = Get-CimInstance Win32_Service -ErrorAction Stop

    # Services set to Auto but not running (excluding the well-known trigger-start ones).
    # BITS explicitly excluded - set to Auto (Delayed Start) but spends most of its
    # time stopped, triggering false positives Eric doesn't want to see.
    $autoStopped = $svcs | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and $_.Name -notmatch '^(BITS|gupdate|MapsBroker|sppsvc|edgeupdate|TrustedInstaller|WbioSrvc|RemoteRegistry)' }

    # Essential services we explicitly care about
    # NOTE: BITS intentionally omitted from this list (per Eric's preference).
    # BITS frequently goes Stopped/Manual on healthy boxes; flagging it
    # produced false positives more often than real findings.
    $essentials = @('wuauserv','WinDefend','RpcSs','Dhcp','Dnscache','LanmanServer','LanmanWorkstation','Schedule')
    $essentialState = @()
    foreach ($e in $essentials) {
        $s = $svcs | Where-Object Name -eq $e
        if ($s) {
            $essentialState += [PSCustomObject]@{ Name=$e; State=$s.State; StartMode=$s.StartMode }
        }
    }

    # Non-Microsoft running services (top 10)
    $thirdParty = $svcs | Where-Object {
        $_.State -eq 'Running' -and
        $_.PathName -and
        ($_.PathName -notmatch 'Windows\\System32' -or $_.PathName -match 'svchost.*-k')
    } | Select-Object -First 15 Name, DisplayName, PathName

    # Build detail lines with explicit severity. Essential services that are
    # running show green, anything not running shows red - so the section reads
    # at a glance. Auto-stopped services go amber only when they cross the count
    # that actually drives an ATTENTION verdict (>5), matching the headline.
    $autoStoppedCount = ($autoStopped | Measure-Object).Count

    $details = @("Essential services:")
    $details += ($essentialState | ForEach-Object {
        $line = "  {0,-22} {1,-10} (StartMode={2})" -f $_.Name, $_.State, $_.StartMode
        if ($_.State -eq 'Running') { New-Detail -Text $line -Severity 'pass' }
        else                        { New-Detail -Text $line -Severity 'fail' }
    })
    $details += ""

    $autoHeader = "Auto-start services currently STOPPED ($autoStoppedCount):"
    if ($autoStoppedCount -gt 5) { $details += New-Detail -Text $autoHeader -Severity 'warn' }
    else                         { $details += $autoHeader }
    if ($autoStopped) {
        $details += ($autoStopped | Select-Object -First 10 | ForEach-Object {
            $line = "  $($_.Name) - $($_.DisplayName)"
            if ($autoStoppedCount -gt 5) { New-Detail -Text $line -Severity 'warn' } else { $line }
        })
    }
    $details += ""
    $details += "Top 15 non-Microsoft running services:"
    $details += ($thirdParty | ForEach-Object { "  $($_.Name) - $($_.DisplayName)" })

    $verdict = 'OK'
    $issues  = @()
    $criticalDown = $essentialState | Where-Object { $_.State -ne 'Running' }
    if ($criticalDown) {
        $verdict = 'CRITICAL'
        foreach ($cd in $criticalDown) {
            $issues += "Essential service '$($cd.Name)' is $($cd.State)"
        }
    }
    if (($autoStopped | Measure-Object).Count -gt 5) {
        if ($verdict -eq 'OK') { $verdict = 'ATTENTION' }
        $issues += "$(($autoStopped | Measure-Object).Count) auto-start services are stopped"
    }

    Add-Finding -Section "Services" -Verdict $verdict `
                -Headline "$(($essentialState | Where-Object State -eq Running).Count)/$($essentials.Count) essentials running, $(($autoStopped | Measure-Object).Count) auto-start stopped" `
                -Details $details -Issues $issues

    $Snapshot['Services'] = @{
        EssentialDown = @($criticalDown | ForEach-Object { $_.Name })
        AutoStopped   = ($autoStopped | Measure-Object).Count
    }
} catch {
    Add-Finding -Section "Services" -Verdict 'ATTENTION' `
                -Headline "Service enumeration failed" -Details @("Error: $($_.Exception.Message)")
}

Write-Host "    done." -ForegroundColor DarkGray

#endregion

#region --- 6. Network -------------------------------------------------------

Write-Section "6/12  Network"

try {
    $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object Status -ne 'Disabled'
    $ipCfg    = Get-NetIPConfiguration -ErrorAction Stop | Where-Object IPv4DefaultGateway

    $details = @("Active adapters:")
    foreach ($a in $adapters) {
        $details += "  $($a.Name) [$($a.InterfaceDescription)]  Status=$($a.Status)  Speed=$($a.LinkSpeed)"
    }
    $details += ""
    $details += "IP configurations with default gateway:"
    foreach ($c in $ipCfg) {
        $details += "  $($c.InterfaceAlias)"
        $details += "    IPv4    : $($c.IPv4Address.IPAddress -join ', ')"
        $details += "    Gateway : $($c.IPv4DefaultGateway.NextHop)"
        $details += "    DNS     : $($c.DNSServer.ServerAddresses -join ', ')"
    }

    # Gateway ping
    $verdict = 'OK'
    $issues  = @()
    $gwPing  = $null
    if ($ipCfg) {
        $gw = $ipCfg[0].IPv4DefaultGateway.NextHop
        try {
            $gwPing = Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction Stop
            $details += ""
            if ($gwPing) {
                $details += New-Detail -Text "Gateway ping ($gw): OK" -Severity 'pass'
            } else {
                $details += New-Detail -Text "Gateway ping ($gw): FAILED" -Severity 'fail'
                $verdict = 'CRITICAL'
                $issues += "Cannot ping default gateway $gw"
            }
        } catch { }
    }

    # DNS resolution test (timed)
    $dnsOk    = $false
    $dnsMs    = $null
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $null = Resolve-DnsName -Name 'www.microsoft.com' -Type A -ErrorAction Stop -QuickTimeout
        $sw.Stop()
        $dnsOk = $true
        $dnsMs = $sw.ElapsedMilliseconds
        if ($dnsMs -gt 1000) {
            $details += New-Detail -Text "DNS resolve test (microsoft.com): OK but SLOW in $dnsMs ms" -Severity 'warn'
            if ($verdict -eq 'OK') { $verdict = 'ATTENTION' }
            $issues += "DNS resolution slow ($dnsMs ms)"
        } else {
            $details += New-Detail -Text "DNS resolve test (microsoft.com): OK in $dnsMs ms" -Severity 'pass'
        }
    } catch {
        $details += New-Detail -Text "DNS resolve test (microsoft.com): FAILED ($($_.Exception.Message))" -Severity 'fail'
        $verdict = 'CRITICAL'
        $issues += "DNS resolution failed"
    }

    # Internet reachability
    $inetOk = $false
    try {
        $resp = Invoke-WebRequest 'https://www.microsoft.com' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $inetOk = ($resp.StatusCode -eq 200)
        if ($inetOk) {
            $details += New-Detail -Text "Internet reach (HTTPS): OK" -Severity 'pass'
        } else {
            $details += New-Detail -Text "Internet reach (HTTPS): HTTP $($resp.StatusCode)" -Severity 'warn'
        }
    } catch {
        $details += New-Detail -Text "Internet reach (HTTPS): FAILED ($($_.Exception.Message))" -Severity 'fail'
        if ($verdict -ne 'CRITICAL') { $verdict = 'ATTENTION' }
        $issues += "HTTPS internet test failed"
    }

    # --- Multi-target TCP probe (defense-in-depth check) ---
    # Quick TCP connect to 3 different hosts so we can tell apart:
    #   - DNS broken     (raw IP works, hostnames don't)
    #   - MS CDN blocked (other targets work, Microsoft doesn't)
    #   - General no-net (all fail)
    $details += ""
    $details += "TCP connectivity probe (3-second timeout each):"
    $tcpTargets = @(
        @{ Host='8.8.8.8'; Port=443; Name='Google DNS IP (8.8.8.8)' },
        @{ Host='download.windowsupdate.com'; Port=443; Name='Windows Update CDN' },
        @{ Host='dl.google.com'; Port=443; Name='Google CDN' }
    )
    $tcpReachable = 0
    foreach ($t in $tcpTargets) {
        $tcpOk = $false
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            $async = $tcpClient.BeginConnect($t.Host, $t.Port, $null, $null)
            $waited = $async.AsyncWaitHandle.WaitOne(3000, $false)
            if ($waited -and $tcpClient.Connected) { $tcpOk = $true; $tcpReachable++ }
            $tcpClient.Close()
        } catch { }
        if ($tcpOk) {
            $details += New-Detail -Text "  $($t.Name): OK" -Severity 'pass'
        } else {
            $details += New-Detail -Text "  $($t.Name): UNREACHABLE" -Severity 'fail'
        }
    }
    if ($tcpReachable -eq 0) {
        $verdict = 'CRITICAL'
        $issues += "No TCP targets reachable - no internet"
    } elseif ($tcpReachable -lt $tcpTargets.Count) {
        if ($verdict -eq 'OK') { $verdict = 'ATTENTION' }
        $issues += "Partial internet connectivity ($tcpReachable/$($tcpTargets.Count) targets) - DNS or firewall filtering?"
    }

    # --- Network profile category per connection ---
    # Public profile blocks file sharing/discovery. For most workstations
    # (workgroup, dental practice), Private is desired. DomainAuthenticated
    # is also acceptable. Public is usually wrong.
    $details += ""
    $details += "Network connection profiles:"
    $profiles = @()
    try { $profiles = Get-NetConnectionProfile -ErrorAction Stop } catch { }
    foreach ($p in $profiles) {
        if ($p.NetworkCategory -eq 'Public') {
            $details += New-Detail -Text "  $($p.Name) on '$($p.InterfaceAlias)' : $($p.NetworkCategory)" -Severity 'warn'
            if ($verdict -eq 'OK') { $verdict = 'ATTENTION' }
            $issues += "Network '$($p.Name)' is Public - file sharing/discovery blocked"
        } else {
            $details += New-Detail -Text "  $($p.Name) on '$($p.InterfaceAlias)' : $($p.NetworkCategory)" -Severity 'pass'
        }
    }

    # --- File/Print Sharing + Network Discovery firewall state ---
    # Even on Private profile, sharing/discovery is often disabled by default
    # on Win11. Report whether the firewall rule groups are enabled.
    try {
        $fpsRules = Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction Stop |
                    Where-Object { $_.Profile -match 'Private|Any' }
        $fpsEnabled = ($fpsRules | Where-Object Enabled -eq 'True').Count
        if ($fpsRules.Count -gt 0 -and $fpsEnabled -eq 0) {
            $details += New-Detail -Text "  File/Print Sharing rules enabled for Private: $fpsEnabled of $($fpsRules.Count)" -Severity 'warn'
            $issues += "File/Print Sharing rules are all disabled - SMB won't work"
        } else {
            $details += "  File/Print Sharing rules enabled for Private: $fpsEnabled of $($fpsRules.Count)"
        }
    } catch { }
    try {
        $ndRules = Get-NetFirewallRule -DisplayGroup 'Network Discovery' -ErrorAction Stop |
                   Where-Object { $_.Profile -match 'Private|Any' }
        $ndEnabled = ($ndRules | Where-Object Enabled -eq 'True').Count
        $details += "  Network Discovery rules enabled for Private  : $ndEnabled of $($ndRules.Count)"
    } catch { }

    Add-Finding -Section "Network" -Verdict $verdict `
                -Headline "$($adapters.Count) adapters, DNS $(if($dnsOk){'OK'}else{'FAIL'}), Internet $(if($inetOk){'OK'}else{'FAIL'}), TCP $tcpReachable/3" `
                -Details $details -Issues $issues

    $Snapshot['Network'] = @{
        Adapters=$adapters.Count; GatewayPing=$gwPing
        DNSOk=$dnsOk; DNSms=$dnsMs; InternetOk=$inetOk
        TCPReachable=$tcpReachable; TCPTotal=$tcpTargets.Count
        Profiles=($profiles | ForEach-Object { @{ Name=$_.Name; Category="$($_.NetworkCategory)" } })
    }
} catch {
    Add-Finding -Section "Network" -Verdict 'ATTENTION' `
                -Headline "Network probe failed" -Details @("Error: $($_.Exception.Message)")
}

Write-Host "    done." -ForegroundColor DarkGray

#endregion

#region --- 7. Security -----------------------------------------------------

Write-Section "7/12  Security posture"

try {
    $details = @()
    $verdict = 'OK'
    $issues  = @()

    # Windows Defender
    $mp = $null
    try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { }

    if ($mp) {
        $sigAge = if ($mp.AntispywareSignatureLastUpdated) {
            [int]((Get-Date) - $mp.AntispywareSignatureLastUpdated).TotalDays
        } else { 999 }

        $details += "Windows Defender:"
        # Enabled / Real-time: green when on, red when off (these drive CRITICAL)
        if ($mp.AntivirusEnabled) {
            $details += New-Detail -Text "  Enabled            : $($mp.AntivirusEnabled)" -Severity 'pass'
        } else {
            $details += New-Detail -Text "  Enabled            : $($mp.AntivirusEnabled)" -Severity 'fail'
        }
        if ($mp.RealTimeProtectionEnabled) {
            $details += New-Detail -Text "  Real-time          : $($mp.RealTimeProtectionEnabled)" -Severity 'pass'
        } else {
            $details += New-Detail -Text "  Real-time          : $($mp.RealTimeProtectionEnabled)" -Severity 'fail'
        }
        # Signature age: green if fresh, amber/red if stale
        $sigLine = "  Sig last updated   : $(if($mp.AntispywareSignatureLastUpdated){$mp.AntispywareSignatureLastUpdated.ToString('yyyy-MM-dd HH:mm')}else{'never'}) ($sigAge days ago)"
        if ($sigAge -gt 7) {
            $details += New-Detail -Text $sigLine -Severity 'warn'
        } else {
            $details += New-Detail -Text $sigLine -Severity 'pass'
        }
        $details += "  Quick scan ended   : $(if($mp.QuickScanEndTime){$mp.QuickScanEndTime.ToString('yyyy-MM-dd HH:mm')}else{'never'})"
        $details += "  Full scan ended    : $(if($mp.FullScanEndTime){$mp.FullScanEndTime.ToString('yyyy-MM-dd HH:mm')}else{'never'})"
        # Tamper protection: green when on, amber when off (defense-in-depth, not critical)
        if ($mp.IsTamperProtected) {
            $details += New-Detail -Text "  Tamper protection  : $($mp.IsTamperProtected)" -Severity 'pass'
        } else {
            $details += New-Detail -Text "  Tamper protection  : $($mp.IsTamperProtected)" -Severity 'warn'
        }

        if (-not $mp.AntivirusEnabled) {
            $verdict = 'CRITICAL'
            $issues += "Defender antivirus is DISABLED"
        }
        if (-not $mp.RealTimeProtectionEnabled) {
            $verdict = 'CRITICAL'
            $issues += "Defender real-time protection is OFF"
        }
        if ($sigAge -gt 7) {
            if ($verdict -ne 'CRITICAL') { $verdict = 'ATTENTION' }
            $issues += "Defender signatures $sigAge days old"
        }

        # Recent threats
        $threats = Get-MpThreatDetection -ErrorAction SilentlyContinue | Sort-Object InitialDetectionTime -Descending | Select-Object -First 10
        if ($threats) {
            $details += ""
            $details += New-Detail -Text "Recent threat detections ($($threats.Count)):" -Severity 'fail'
            $details += ($threats | ForEach-Object {
                New-Detail -Text "  $($_.InitialDetectionTime.ToString('yyyy-MM-dd HH:mm')) - $($_.ThreatID) - $($_.Resources -join '; ')" -Severity 'fail'
            })
            $verdict = 'CRITICAL'
            $issues += "$($threats.Count) recent threat detection(s) - investigate"
        }

        # --- Defender exclusion summary ---
        # Report current exclusions for visibility. Lots of exclusions can be
        # legit (Dentrix/SQL) or suspicious (malware hides behind exclusions).
        # We report counts + samples so a tech can spot anything unexpected.
        try {
            $pref = Get-MpPreference -ErrorAction Stop
            $pathCount = ($pref.ExclusionPath    | Measure-Object).Count
            $procCount = ($pref.ExclusionProcess | Measure-Object).Count
            $extCount  = ($pref.ExclusionExtension | Measure-Object).Count
            $details += ""
            $details += "Defender exclusions:"
            # Large path exclusion lists go amber - common malware-hiding tactic
            if ($pathCount -gt 25) {
                $details += New-Detail -Text "  Paths      : $pathCount" -Severity 'warn'
            } else {
                $details += "  Paths      : $pathCount"
            }
            $details += "  Processes  : $procCount"
            $details += "  Extensions : $extCount"
            if ($pathCount -gt 0) {
                $details += "  Path exclusions:"
                # Show all paths - useful for both legit verification AND
                # spotting suspicious exclusions added by malware
                foreach ($p in $pref.ExclusionPath) { $details += "    - $p" }
            }
            if ($procCount -gt 0) {
                $details += "  Process exclusions:"
                foreach ($p in $pref.ExclusionProcess) { $details += "    - $p" }
            }
            if ($extCount -gt 0) {
                $details += "  Extension exclusions:"
                foreach ($p in $pref.ExclusionExtension) { $details += "    - $p" }
            }
            # Flag unusually large exclusion lists - common malware tactic
            if ($pathCount -gt 25) {
                if ($verdict -ne 'CRITICAL') { $verdict = 'ATTENTION' }
                $issues += "Unusually many path exclusions ($pathCount) - verify each is legitimate"
            }
        } catch { }
    } else {
        $details += New-Detail -Text "Defender status: unavailable (third-party AV may be installed)" -Severity 'warn'
    }

    # Firewall
    $fw = Get-NetFirewallProfile -ErrorAction SilentlyContinue
    if ($fw) {
        $details += ""
        $details += "Firewall profiles:"
        foreach ($p in $fw) {
            if ($p.Enabled) {
                $details += New-Detail -Text "  $($p.Name) : Enabled=$($p.Enabled)" -Severity 'pass'
            } else {
                $details += New-Detail -Text "  $($p.Name) : Enabled=$($p.Enabled)" -Severity 'fail'
                if ($verdict -ne 'CRITICAL') { $verdict = 'ATTENTION' }
                $issues += "Firewall profile '$($p.Name)' is disabled"
            }
        }
    }

    # Suspicious scheduled tasks
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.State -eq 'Ready' -and
        $_.Author -and
        $_.Author -notlike "Microsoft*" -and
        $_.Author -notlike "*Windows*" -and
        $_.TaskPath -notlike "\Microsoft\*"
    }
    if ($tasks) {
        $details += ""
        $details += "Non-Microsoft scheduled tasks (top 10):"
        $details += ($tasks | Select-Object -First 10 | ForEach-Object { "  $($_.TaskPath)$($_.TaskName)  (author: $($_.Author))" })
    }

    Add-Finding -Section "Security" -Verdict $verdict `
                -Headline "Defender $(if($mp.AntivirusEnabled){'ON'}else{'OFF'}), sigs $sigAge days old" `
                -Details $details -Issues $issues

    $Snapshot['Security'] = @{
        DefenderEnabled = $mp.AntivirusEnabled
        RealTime        = $mp.RealTimeProtectionEnabled
        SigAgeDays      = $sigAge
        ThreatCount     = ($threats | Measure-Object).Count
    }
} catch {
    Add-Finding -Section "Security" -Verdict 'ATTENTION' `
                -Headline "Security probe failed" -Details @("Error: $($_.Exception.Message)")
}

Write-Host "    done." -ForegroundColor DarkGray

#endregion

#region --- 8. Performance hotspots -----------------------------------------

Write-Section "8/12  Performance hotspots"

try {
    # Disk queue length sample
    $dq = Get-Counter '\PhysicalDisk(_Total)\Avg. Disk Queue Length' -SampleInterval 1 -MaxSamples 3 -ErrorAction SilentlyContinue
    $dqAvg = if ($dq) { [math]::Round(($dq.CounterSamples.CookedValue | Measure-Object -Average).Average, 2) } else { 'n/a' }

    # Top processes by I/O bytes/sec
    $ioCounter = Get-Counter '\Process(*)\IO Data Bytes/sec' -MaxSamples 1 -ErrorAction SilentlyContinue
    $topIO = $ioCounter.CounterSamples |
             Where-Object { $_.InstanceName -ne '_total' -and $_.InstanceName -ne 'idle' -and $_.CookedValue -gt 0 } |
             Sort-Object CookedValue -Descending | Select-Object -First 5 InstanceName, CookedValue

    # TCP connections grouped by process
    $tcp = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
           Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 5

    $details = @(
        "Disk queue length (avg of 3 samples): $dqAvg"
        ""
        "Top 5 processes by I/O bytes/sec (snapshot):"
    )
    $details += ($topIO | ForEach-Object { "  {0,-25} {1,12:N0} B/sec" -f $_.InstanceName, $_.CookedValue })
    $details += ""
    $details += "Top 5 processes by TCP connection count:"
    foreach ($g in $tcp) {
        $pname = (Get-Process -Id $g.Name -ErrorAction SilentlyContinue).Name
        $details += "  PID $($g.Name) [$pname]  $($g.Count) connections"
    }

    $verdict = 'OK'
    $issues  = @()
    if ($dqAvg -ne 'n/a' -and [double]$dqAvg -gt 2) {
        $verdict = 'ATTENTION'
        $issues += "Disk queue length $dqAvg - I/O subsystem busy"
    }

    Add-Finding -Section "Performance" -Verdict $verdict `
                -Headline "Disk queue $dqAvg" -Details $details -Issues $issues

    $Snapshot['Performance'] = @{ DiskQueue=$dqAvg }
} catch {
    Add-Finding -Section "Performance" -Verdict 'ATTENTION' `
                -Headline "Performance sampling failed" -Details @("Error: $($_.Exception.Message)")
}

Write-Host "    done." -ForegroundColor DarkGray

#endregion

#region --- 9. Pending state ------------------------------------------------

Write-Section "9/12  Pending state (reboot signals)"

function Test-PendingReboot {
    $signals = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')   { $signals += 'CBS RebootPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')  { $signals += 'WindowsUpdate RebootRequired' }
    $sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($sm -and $sm.PendingFileRenameOperations) { $signals += 'PendingFileRenameOperations' }
    if (Test-Path 'C:\Windows\WinSxS\pending.xml') { $signals += 'pending.xml exists in WinSxS' }
    try {
        $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
        $target = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'      -Name ComputerName -ErrorAction Stop).ComputerName
        if ($active -and $target -and ($active -ne $target)) { $signals += "Computer rename pending ($active -> $target)" }
    } catch { }
    return $signals
}

try {
    $pending = Test-PendingReboot
    $details = @()
    $verdict = 'OK'
    $issues  = @()
    if ($pending.Count -gt 0) {
        $details += "Pending operations detected:"
        $details += ($pending | ForEach-Object { "  - $_" })
        $verdict = 'ATTENTION'
        $issues += "Reboot pending: $($pending -join '; ')"
    } else {
        $details += "No pending operations - system is clean."
    }

    Add-Finding -Section "Pending state" -Verdict $verdict `
                -Headline "$(if($pending.Count){"$($pending.Count) pending"}else{'clean'})" `
                -Details $details -Issues $issues

    $Snapshot['Pending'] = @{ Count=$pending.Count; Signals=$pending }
} catch {
    Add-Finding -Section "Pending state" -Verdict 'ATTENTION' `
                -Headline "Pending state check failed" -Details @("Error: $($_.Exception.Message)")
}

Write-Host "    done." -ForegroundColor DarkGray

#endregion

#region --- 10. Dentrix (conditional) ---------------------------------------

Write-Section "10/12 Dentrix-specific checks"

$dentrixDetected = $false
$dentrixDetails  = @()
$dentrixIssues   = @()
$dentrixVerdict  = 'OK'

# Detection heuristics
$dentrixPaths = @(
    'C:\Program Files\Dentrix',
    'C:\Program Files (x86)\Dentrix',
    'C:\Dentrix',
    'C:\DENTRIX'
)
$dentrixSvcs = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Dentrix' -or $_.DisplayName -match 'Dentrix' }
$dentrixReg  = Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Dentrix Dental Systems'

foreach ($p in $dentrixPaths) {
    if (Test-Path $p) { $dentrixDetected = $true; $dentrixDetails += "Found install path: $p" }
}
if ($dentrixSvcs) {
    $dentrixDetected = $true
    $dentrixDetails += "Dentrix services found:"
    foreach ($s in $dentrixSvcs) {
        $dentrixDetails += "  $($s.Name) - $($s.DisplayName)  State=$($s.Status)"
        if ($s.Status -ne 'Running' -and $s.StartType -eq 'Automatic') {
            $dentrixVerdict = 'CRITICAL'
            $dentrixIssues += "Dentrix service '$($s.Name)' is $($s.Status) but set to auto-start"
        }
    }
}
if ($dentrixReg) { $dentrixDetected = $true; $dentrixDetails += "Dentrix registry key present (32-bit)" }

if ($dentrixDetected) {
    # SQL Server (Dentrix uses SQL Server)
    $sql = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'MSSQL' -or $_.Name -match 'SQLBrowser' }
    if ($sql) {
        $dentrixDetails += ""
        $dentrixDetails += "SQL Server services:"
        foreach ($s in $sql) {
            $dentrixDetails += "  $($s.Name) - State=$($s.Status)  StartType=$($s.StartType)"
            if ($s.Name -match 'MSSQL\$' -and $s.Status -ne 'Running') {
                $dentrixVerdict = 'CRITICAL'
                $dentrixIssues += "SQL instance '$($s.Name)' not running - Dentrix will not work"
            }
        }
    } else {
        $dentrixDetails += ""
        $dentrixDetails += "No SQL Server services found - may be a workstation pointing at a server"
    }

    # TCP 1433 listening?
    $sqlListen = Get-NetTCPConnection -State Listen -LocalPort 1433 -ErrorAction SilentlyContinue
    $dentrixDetails += ""
    $dentrixDetails += "TCP 1433 (SQL Server) listening: $(if($sqlListen){'YES'}else{'no (normal for workstation)'})"

    # Network share - typical Dentrix data path
    $shares = Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Dentrix|DXOne' }
    if ($shares) {
        $dentrixDetails += ""
        $dentrixDetails += "Dentrix-related SMB shares hosted:"
        $dentrixDetails += ($shares | ForEach-Object { "  $($_.Name) -> $($_.Path)" })
    }

    Add-Finding -Section "Dentrix" -Verdict $dentrixVerdict `
                -Headline "Dentrix detected on this machine" `
                -Details $dentrixDetails -Issues $dentrixIssues
} else {
    Add-Finding -Section "Dentrix" -Verdict 'OK' `
                -Headline "Dentrix not detected - section skipped" `
                -Details @("No Dentrix install path, service, or registry key found.")
    Write-Host "    Dentrix not detected - skipping." -ForegroundColor DarkGray
}

Write-Host "    done." -ForegroundColor DarkGray

#endregion

#region --- 11. TeamViewer (iDezign branded host) ---------------------------
# iDezign's branded TeamViewer Host comes from get.teamviewer.com/idezign.
# That installer is a "Custom Host" module, which means TeamViewer's MSI
# stamps a CustomConfigID into the registry. If the value is present and
# non-empty, we know it was a custom-branded install (vs someone manually
# downloading TeamViewer from teamviewer.com).
#
# What we check:
#   1. Is TeamViewer installed at all? (registry + service + install path)
#   2. Is the TeamViewer service running?
#   3. Does it have a CustomConfigID (i.e. is it the iDezign-branded build)?
#   4. Version string + install date for reference.

Write-Section "11/12 Remote support (TeamViewer Host)"

$tvDetails  = @()
$tvIssues   = @()
$tvVerdict  = 'OK'
$tvDetected = $false
$tvBranded  = $false

# Registry hives to check (32-bit hive on 64-bit Windows is where TV lives)
$tvRegKeys = @(
    'HKLM:\SOFTWARE\TeamViewer',
    'HKLM:\SOFTWARE\WOW6432Node\TeamViewer'
)

$tvRegFound = $null
foreach ($k in $tvRegKeys) {
    if (Test-Path $k) {
        $tvRegFound = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if ($tvRegFound) { break }
    }
}

# Service detection - the host service is TeamViewer; full client may also be present
$tvSvc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^TeamViewer' }

# Install paths
$tvPaths = @(
    "$env:ProgramFiles\TeamViewer",
    "${env:ProgramFiles(x86)}\TeamViewer",
    "$env:ProgramFiles\TeamViewer Host",
    "${env:ProgramFiles(x86)}\TeamViewer Host"
) | Where-Object { Test-Path $_ }

if ($tvRegFound -or $tvSvc -or $tvPaths) {
    $tvDetected = $true

    $tvVersion = $tvRegFound.Version
    $tvClientID = $tvRegFound.ClientID
    $tvCustomConfigID = $tvRegFound.CustomConfigID

    $tvDetails += "TeamViewer detected:"
    $tvDetails += "  Version          : $(if($tvVersion){$tvVersion}else{'(unknown)'})"
    $tvDetails += "  ClientID         : $(if($tvClientID){$tvClientID}else{'(not set)'})"
    if ($tvPaths) {
        $tvDetails += "  Install path(s)  :"
        foreach ($p in $tvPaths) { $tvDetails += "    $p" }
    }
    if ($tvSvc) {
        $tvDetails += "  Service(s)       :"
        foreach ($s in $tvSvc) {
            $tvDetails += "    $($s.Name) - Status=$($s.Status) StartType=$($s.StartType)"
            if ($s.Status -ne 'Running' -and $s.StartType -eq 'Automatic') {
                $tvVerdict = 'CRITICAL'
                $tvIssues += "TeamViewer service '$($s.Name)' is not running but set to auto-start"
            }
        }
    } else {
        $tvVerdict = 'ATTENTION'
        $tvIssues += "TeamViewer is installed but no TeamViewer service was found"
    }

    # The iDezign-branded check: CustomConfigID present and non-empty
    $tvDetails += ""
    if ($tvCustomConfigID -and $tvCustomConfigID.ToString().Trim() -ne '') {
        $tvBranded = $true
        $tvDetails += "  CustomConfigID   : $tvCustomConfigID  <-- BRANDED INSTALL DETECTED"
        $tvDetails += "  Verdict          : Looks like an iDezign-branded Host install."
    } else {
        $tvDetails += "  CustomConfigID   : (not present - this is a stock TeamViewer install)"
        $tvDetails += ""
        $tvDetails += "  This is NOT the iDezign-branded TeamViewer Host."
        $tvDetails += "  To replace with the branded version:"
        $tvDetails += "    1. Uninstall current TeamViewer (Control Panel -> Programs)"
        $tvDetails += "    2. Download branded host from: https://get.teamviewer.com/idezign"
        $tvDetails += "    3. Run installer - it self-configures with iDezign settings"
        if ($tvVerdict -eq 'OK') { $tvVerdict = 'ATTENTION' }
        $tvIssues += "TeamViewer present but not iDezign-branded - replace with get.teamviewer.com/idezign build"
    }

    $headline = if ($tvBranded) {
        "iDezign-branded TeamViewer Host installed (v$tvVersion, ID $tvClientID)"
    } elseif ($tvDetected) {
        "TeamViewer installed but NOT branded - reinstall from get.teamviewer.com/idezign"
    } else {
        "TeamViewer not detected"
    }

    Add-Finding -Section "TeamViewer" -Verdict $tvVerdict `
                -Headline $headline -Details $tvDetails -Issues $tvIssues

    $Snapshot['TeamViewer'] = @{
        Installed     = $tvDetected
        Branded       = $tvBranded
        Version       = $tvVersion
        ClientID      = $tvClientID
        CustomConfig  = $tvCustomConfigID
    }
} else {
    # Servers often DO have TeamViewer Host so this is meaningful on both.
    Add-Finding -Section "TeamViewer" -Verdict 'ATTENTION' `
                -Headline "TeamViewer not installed - install from get.teamviewer.com/idezign" `
                -Details @(
                    "No TeamViewer registry, service, or install path was found.",
                    "",
                    "Recommended action:",
                    "  1. Browse to https://get.teamviewer.com/idezign",
                    "  2. Run the downloaded branded Host installer",
                    "  3. It will auto-configure with iDezign settings"
                ) `
                -Issues @("TeamViewer Host not installed - install from get.teamviewer.com/idezign for unattended access")

    $Snapshot['TeamViewer'] = @{ Installed = $false; Branded = $false }
}

Write-Host "    done." -ForegroundColor DarkGray

#endregion

#region --- 12. Server-specific checks (conditional) ------------------------

if ($IsServer) {
    Write-Section "13/13 Server-specific checks"

    $details = @()
    $issues  = @()
    $verdict = 'OK'

    $details += "Role classification:"
    $details += "  ProductType    : $($ServerInfo.ProductType) ($(if($IsDC){'Domain Controller'}else{'Member Server'}))"
    $details += "  OS             : $($ServerInfo.OSCaption)"
    $details += "  Domain-joined  : $($ServerInfo.IsDomainJoined)  (Domain: $($ServerInfo.DomainName))"
    $details += ""

    # Installed Server roles (the big picture: what is this server FOR?)
    if ($ServerInfo.InstalledRoles -and $ServerInfo.InstalledRoles.Count -gt 0) {
        $details += "Installed roles ($($ServerInfo.InstalledRoles.Count)):"
        foreach ($r in $ServerInfo.InstalledRoles) {
            $details += "  - $r"
        }
    } else {
        $details += "No major roles installed (or Get-WindowsFeature not available)."
    }
    $details += ""

    # SMB1 - critical security check on file servers / dental servers
    try {
        $smb1 = Get-SmbServerConfiguration -ErrorAction Stop
        $details += "SMB1 protocol enabled : $($smb1.EnableSMB1Protocol)"
        if ($smb1.EnableSMB1Protocol) {
            $verdict = 'ATTENTION'
            $issues += "SMB1 is ENABLED - vulnerable to ransomware (WannaCry/EternalBlue); disable unless absolutely required"
        }
    } catch {
        $details += "SMB1 check: unavailable"
    }
    $details += ""

    # Hyper-V detection + running VMs
    if ($ServerInfo.InstalledRoles -contains 'Hyper-V') {
        try {
            $vms = Get-VM -ErrorAction Stop
            $running = $vms | Where-Object State -eq 'Running'
            $details += "Hyper-V host:"
            $details += "  VMs total      : $($vms.Count)"
            $details += "  VMs running    : $($running.Count)"
            $details += "  VMs stopped    : $(($vms | Where-Object State -eq 'Off').Count)"
            foreach ($v in $running | Select-Object -First 10) {
                $details += "    + $($v.Name)  (CPU=$($v.ProcessorCount), RAM=$([math]::Round($v.MemoryAssigned/1GB,1))GB, Uptime=$([int]$v.Uptime.TotalDays)d)"
            }
        } catch {
            $details += "Hyper-V cmdlets not available."
        }
        $details += ""
    }

    # File Server role - share inventory
    if ($ServerInfo.InstalledRoles -contains 'FileAndStorage-Services' -or $ServerInfo.InstalledRoles -contains 'FS-FileServer') {
        try {
            $shares = Get-SmbShare -ErrorAction Stop | Where-Object Name -notmatch '^[A-Z]\$$|^IPC\$$|^ADMIN\$$|^print\$$|^NETLOGON$|^SYSVOL$'
            $details += "Non-admin SMB shares ($($shares.Count)):"
            foreach ($s in $shares | Select-Object -First 15) {
                $details += "  $($s.Name) -> $($s.Path)"
            }
        } catch { }
        $details += ""
    }

    # DC-specific - basic AD-DS health check (without going too deep)
    if ($IsDC) {
        try {
            $adService = Get-Service -Name NTDS -ErrorAction SilentlyContinue
            if ($adService) {
                $details += "AD-DS service (NTDS) : $($adService.Status)"
                if ($adService.Status -ne 'Running') {
                    $verdict = 'CRITICAL'
                    $issues += "Active Directory service NTDS is NOT running - this DC is non-functional"
                }
            }
            $dnsServ = Get-Service -Name DNS -ErrorAction SilentlyContinue
            if ($dnsServ) {
                $details += "DNS Server service    : $($dnsServ.Status)"
                if ($dnsServ.Status -ne 'Running') {
                    if ($verdict -ne 'CRITICAL') { $verdict = 'ATTENTION' }
                    $issues += "DNS Server service is $($dnsServ.Status) - clients may lose name resolution"
                }
            }
        } catch { }
        $details += ""
    }

    # Print Server / spooler queue check (common dental ops issue)
    try {
        $spooler = Get-Service -Name Spooler -ErrorAction SilentlyContinue
        if ($spooler) {
            $details += "Print Spooler service : $($spooler.Status)"
            $jobs = Get-Printer -ErrorAction SilentlyContinue | ForEach-Object {
                Get-PrintJob -PrinterName $_.Name -ErrorAction SilentlyContinue
            }
            if ($jobs) {
                $stuck = $jobs | Where-Object { $_.SubmittedTime -lt (Get-Date).AddHours(-1) }
                $details += "Queued print jobs      : $($jobs.Count) total, $($stuck.Count) older than 1 hour"
                if ($stuck.Count -gt 0) {
                    if ($verdict -eq 'OK') { $verdict = 'ATTENTION' }
                    $issues += "$($stuck.Count) print job(s) stuck in queue > 1 hour - consider clearing"
                }
            }
        }
    } catch { }

    Add-Finding -Section "Server-specific" -Verdict $verdict `
                -Headline "$(if($IsDC){'DC'}else{'Member server'}), $($ServerInfo.InstalledRoles.Count) role(s) installed" `
                -Details $details -Issues $issues

    $Snapshot['ServerSpecific'] = @{
        IsDC          = $IsDC
        OSCaption     = $ServerInfo.OSCaption
        DomainJoined  = $ServerInfo.IsDomainJoined
        DomainName    = $ServerInfo.DomainName
        Roles         = $ServerInfo.InstalledRoles
    }

    Write-Host "    done." -ForegroundColor DarkGray
}

#endregion

#region --- 13. iDezign Configuration Verification --------------------------
# Compares current machine config against iDezign baseline.
# Each item gets one of three verdicts:
#   PASS  - matches baseline
#   FAIL  - doesn't match (flagged as issue)
#   INFO  - reported but no expectation (e.g. "Chrome installed: yes" is info)
# Whole-section verdict:
#   All PASS / INFO -> OK
#   Any FAIL on REQUIRED items -> ATTENTION (or CRITICAL for security-related)
# Required items are marked with [REQ] in the output line. Optional items
# with [opt] are just for visibility.

Write-Section "12/12 iDezign Configuration Verification"

try {
    $vDetails = @()
    $vIssues  = @()
    $vVerdict = 'OK'

    # Helper to format a verification line - aligned columns for readability
    function Add-VerifyLine {
        param(
            [string]$Status,   # PASS / FAIL / INFO
            [string]$Required, # [REQ] / [opt]
            [string]$Label,
            [string]$Value
        )
        $statusPad = $Status.PadRight(4)
        $reqPad    = $Required.PadRight(5)
        $labelPad  = $Label.PadRight(34)
        $text = "  $statusPad $reqPad $labelPad : $Value"

        # Map the known status straight to a severity - no guessing needed here,
        # this section literally knows whether each check passed or failed.
        $sev = switch ($Status) {
            'PASS'  { 'pass' }
            'FAIL'  { 'fail' }
            default { 'info' }   # INFO and anything else -> neutral
        }
        return (New-Detail -Text $text -Severity $sev)
    }

    # ===== Power configuration =====
    # Query individual settings by GUID using powercfg, then parse the AC index.
    # This is more reliable than parsing the whole /q output - powercfg with
    # specific GUIDs returns a small block, easy to regex.
    function Get-PowerSetting {
        param([string]$SubGuid, [string]$SettingGuid)
        try {
            $out = & powercfg /q SCHEME_CURRENT $SubGuid $SettingGuid 2>&1 | Out-String
            $m = [regex]::Match($out, 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)')
            if ($m.Success) { return [Convert]::ToInt32($m.Groups[1].Value, 16) }
        } catch { }
        return $null
    }

    try {
        # Standard Windows power scheme GUIDs (same across all versions of Windows)
        $G_SUB_DISK   = '0012ee47-9041-4b5d-9b77-535fba8b1442'
        $G_DISK_OFF   = '6738e2c4-e8a5-4a42-b16a-e040e769756e'   # "Turn off hard disk after"
        $G_SUB_SLEEP  = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
        $G_SLEEP_AFT  = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'   # "Sleep after"
        $G_SUB_VIDEO  = '7516b95f-f776-4464-8c53-06167f40cc99'
        $G_VIDEO_OFF  = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'   # "Turn off display after"

        # Hard disk timeout: expect 0 (never)
        $diskTimeout = Get-PowerSetting -SubGuid $G_SUB_DISK -SettingGuid $G_DISK_OFF
        if ($null -ne $diskTimeout) {
            if ($diskTimeout -eq 0) {
                $vDetails += Add-VerifyLine 'PASS' '[REQ]' 'Power: HDD timeout' 'NEVER (0)'
            } else {
                $vDetails += Add-VerifyLine 'FAIL' '[REQ]' 'Power: HDD timeout' "$diskTimeout sec (expected 0/never)"
                if ($vVerdict -eq 'OK') { $vVerdict = 'ATTENTION' }
                $vIssues += "Power: HDD timeout is $diskTimeout sec, expected NEVER (critical for Dentrix/SQL)"
            }
        } else {
            $vDetails += Add-VerifyLine 'INFO' '[opt]' 'Power: HDD timeout' 'could not query'
        }

        # Sleep timeout: expect 0
        $sleepTimeout = Get-PowerSetting -SubGuid $G_SUB_SLEEP -SettingGuid $G_SLEEP_AFT
        if ($null -ne $sleepTimeout) {
            if ($sleepTimeout -eq 0) {
                $vDetails += Add-VerifyLine 'PASS' '[REQ]' 'Power: Sleep timeout' 'NEVER (0)'
            } else {
                $vDetails += Add-VerifyLine 'FAIL' '[REQ]' 'Power: Sleep timeout' "$sleepTimeout sec (expected 0/never)"
                if ($vVerdict -eq 'OK') { $vVerdict = 'ATTENTION' }
                $vIssues += "Power: Sleep timeout is $sleepTimeout sec, expected NEVER"
            }
        }

        # Display timeout: baseline 3600 (60 min) but accept 30-120 min range as OK
        $videoTimeout = Get-PowerSetting -SubGuid $G_SUB_VIDEO -SettingGuid $G_VIDEO_OFF
        if ($null -ne $videoTimeout) {
            $videoMin = [math]::Round($videoTimeout / 60, 0)
            if ($videoTimeout -ge 1800 -and $videoTimeout -le 7200) {
                $vDetails += Add-VerifyLine 'PASS' '[opt]' 'Power: Display timeout' "$videoMin min (within 30-120 min)"
            } elseif ($videoTimeout -eq 0) {
                $vDetails += Add-VerifyLine 'INFO' '[opt]' 'Power: Display timeout' 'NEVER (unusual for workstations)'
            } else {
                $vDetails += Add-VerifyLine 'INFO' '[opt]' 'Power: Display timeout' "$videoMin min (baseline: 60 min)"
            }
        }

        # Hibernation feature: expect disabled (hiberfil.sys absent)
        $hiberfil = Test-Path 'C:\hiberfil.sys'
        if (-not $hiberfil) {
            $vDetails += Add-VerifyLine 'PASS' '[REQ]' 'Power: Hibernation' 'DISABLED (no hiberfil.sys)'
        } else {
            $hsize = try { [math]::Round((Get-Item 'C:\hiberfil.sys' -Force).Length / 1GB, 1) } catch { '?' }
            $vDetails += Add-VerifyLine 'FAIL' '[REQ]' 'Power: Hibernation' "ENABLED (hiberfil.sys = $hsize GB)"
            if ($vVerdict -eq 'OK') { $vVerdict = 'ATTENTION' }
            $vIssues += "Hibernation is enabled; expected disabled (would reclaim ~$hsize GB)"
        }
    } catch {
        $vDetails += Add-VerifyLine 'INFO' '[opt]' 'Power configuration' "query error: $($_.Exception.Message)"
    }
    $vDetails += ""

    # ===== Network configuration =====
    try {
        $netProfs = Get-NetConnectionProfile -ErrorAction SilentlyContinue
        if (-not $netProfs) {
            $vDetails += Add-VerifyLine 'INFO' '[opt]' 'Network profile' 'no active network'
        } else {
            $publicProfs = $netProfs | Where-Object NetworkCategory -eq 'Public'
            if (-not $publicProfs) {
                $vDetails += Add-VerifyLine 'PASS' '[REQ]' 'Network: profile category' "$($netProfs.Count) network(s), none Public"
            } else {
                $vDetails += Add-VerifyLine 'FAIL' '[REQ]' 'Network: profile category' "$($publicProfs.Count) network(s) on Public - file sharing blocked"
                if ($vVerdict -eq 'OK') { $vVerdict = 'ATTENTION' }
                $vIssues += "Network profile(s) on Public: $($publicProfs.Name -join ', ')"
            }
        }
    } catch { }

    # File/Print Sharing enabled for Private?
    try {
        $fpsRules = Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction Stop |
                    Where-Object Profile -match 'Private|Any'
        $fpsOn = ($fpsRules | Where-Object Enabled -eq 'True').Count
        if ($fpsRules.Count -gt 0 -and $fpsOn -gt 0) {
            $vDetails += Add-VerifyLine 'PASS' '[opt]' 'Network: File/Print Sharing' "$fpsOn of $($fpsRules.Count) rules enabled (Private)"
        } else {
            $vDetails += Add-VerifyLine 'FAIL' '[opt]' 'Network: File/Print Sharing' "DISABLED - SMB to/from this PC won't work"
        }
    } catch { }

    # Network Discovery for Private?
    try {
        $ndRules = Get-NetFirewallRule -DisplayGroup 'Network Discovery' -ErrorAction Stop |
                   Where-Object Profile -match 'Private|Any'
        $ndOn = ($ndRules | Where-Object Enabled -eq 'True').Count
        if ($ndRules.Count -gt 0 -and $ndOn -gt 0) {
            $vDetails += Add-VerifyLine 'PASS' '[opt]' 'Network: Discovery' "$ndOn of $($ndRules.Count) rules enabled (Private)"
        } else {
            $vDetails += Add-VerifyLine 'FAIL' '[opt]' 'Network: Discovery' 'DISABLED - this PC invisible to network browse'
        }
    } catch { }
    $vDetails += ""

    # ===== Applications =====
    # Chrome
    $chromeInstalled = (Test-Path 'C:\Program Files\Google\Chrome\Application\chrome.exe') -or
                      (Test-Path 'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe')
    if ($chromeInstalled) {
        $vDetails += Add-VerifyLine 'INFO' '[opt]' 'App: Google Chrome' 'INSTALLED'
    } else {
        $vDetails += Add-VerifyLine 'INFO' '[opt]' 'App: Google Chrome' 'not installed'
    }

    # Chrome as default browser (registry check)
    try {
        $httpDefault = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' -Name ProgId -ErrorAction Stop).ProgId
        if ($httpDefault -like 'ChromeHTML*') {
            $vDetails += Add-VerifyLine 'INFO' '[opt]' 'App: Chrome as default browser' 'YES'
        } else {
            $vDetails += Add-VerifyLine 'INFO' '[opt]' 'App: Chrome as default browser' "no (current: $httpDefault)"
        }
    } catch { }

    # Claude Desktop (MSIX provisioned)
    try {
        $claudePkg = Get-AppxPackage -AllUsers -Name '*claude*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($claudePkg) {
            $vDetails += Add-VerifyLine 'INFO' '[opt]' 'App: Claude Desktop' "INSTALLED ($($claudePkg.Version))"
        } else {
            $vDetails += Add-VerifyLine 'INFO' '[opt]' 'App: Claude Desktop' 'not installed'
        }
    } catch { }

    # Open-Shell
    $osInstalled = (Test-Path 'C:\Program Files\Open-Shell') -or (Test-Path 'C:\Program Files (x86)\Open-Shell')
    if ($osInstalled) {
        $vDetails += Add-VerifyLine 'INFO' '[opt]' 'App: Open-Shell' 'INSTALLED'
        # Check iDezign defaults applied
        try {
            $osMenuStyle = (Get-ItemProperty 'HKCU:\Software\IvoSoft\ClassicStartMenu\Settings' -Name MenuStyle -ErrorAction Stop).MenuStyle
            if ($osMenuStyle -eq 2) {
                $vDetails += Add-VerifyLine 'PASS' '[opt]' 'App: Open-Shell iDezign defaults' 'APPLIED (Win7-style menu)'
            } else {
                $vDetails += Add-VerifyLine 'INFO' '[opt]' 'App: Open-Shell iDezign defaults' "custom (MenuStyle=$osMenuStyle)"
            }
        } catch {
            $vDetails += Add-VerifyLine 'INFO' '[opt]' 'App: Open-Shell iDezign defaults' 'NOT applied (vanilla)'
        }
    } else {
        $vDetails += Add-VerifyLine 'INFO' '[opt]' 'App: Open-Shell' 'not installed'
    }

    # TeamViewer
    try {
        $tvSvc = Get-Service -Name 'TeamViewer' -ErrorAction Stop
        $vDetails += Add-VerifyLine 'PASS' '[opt]' 'App: TeamViewer service' "$($tvSvc.Status) (StartType=$($tvSvc.StartType))"
        if ($tvSvc.Status -ne 'Running') {
            if ($vVerdict -eq 'OK') { $vVerdict = 'ATTENTION' }
            $vIssues += "TeamViewer service installed but not running"
        }
    } catch {
        $vDetails += Add-VerifyLine 'INFO' '[opt]' 'App: TeamViewer service' 'not installed'
    }

    # Malwarebytes installer (staged for tech to run post-deploy)
    $mwbStaged = Test-Path "$env:USERPROFILE\Downloads\MBSetup.exe"
    $mwbStatus = if ($mwbStaged) { 'YES (in ~\Downloads)' } else { 'no' }
    $vDetails += Add-VerifyLine 'INFO' '[opt]' 'App: Malwarebytes installer staged' $mwbStatus
    $vDetails += ""

    # ===== Security configuration =====
    # REPAIR account exists and is in Administrators
    try {
        $repair = Get-LocalUser -Name 'REPAIR' -ErrorAction Stop
        $adminGroupName = if (Get-Command Get-AdminGroupName -EA SilentlyContinue) { Get-AdminGroupName } else { 'Administrators' }
        $isInAdmins = $false
        try {
            $isInAdmins = (Get-LocalGroupMember -Group $adminGroupName -ErrorAction Stop |
                           Where-Object { $_.Name -like "*\REPAIR" -or $_.Name -eq 'REPAIR' }) -ne $null
        } catch { }
        if ($isInAdmins) {
            $vDetails += Add-VerifyLine 'PASS' '[REQ]' 'Security: REPAIR account' "EXISTS + in $adminGroupName"
        } else {
            $vDetails += Add-VerifyLine 'FAIL' '[REQ]' 'Security: REPAIR account' "exists but NOT in $adminGroupName"
            if ($vVerdict -eq 'OK') { $vVerdict = 'ATTENTION' }
            $vIssues += "REPAIR account exists but is not an administrator"
        }
    } catch {
        $vDetails += Add-VerifyLine 'FAIL' '[REQ]' 'Security: REPAIR account' 'MISSING'
        if ($vVerdict -eq 'OK') { $vVerdict = 'ATTENTION' }
        $vIssues += "REPAIR admin account is missing - tech can't recover this machine"
    }

    # Defender exclusions (for Dentrix workstations - optional but reported)
    try {
        $defPref = Get-MpPreference -ErrorAction Stop
        $exclPaths = ($defPref.ExclusionPath | Measure-Object).Count
        $exclProcs = ($defPref.ExclusionProcess | Measure-Object).Count
        $hasDentrix = ($defPref.ExclusionPath -join ';') -match 'Dentrix|PDB|DXOne|SQL Server'
        if ($hasDentrix) {
            $vDetails += Add-VerifyLine 'PASS' '[opt]' 'Security: Dentrix/SQL exclusions' "configured ($exclPaths paths, $exclProcs processes)"
        } elseif ($exclPaths -gt 0 -or $exclProcs -gt 0) {
            $vDetails += Add-VerifyLine 'INFO' '[opt]' 'Security: Defender exclusions' "$exclPaths paths, $exclProcs processes (no Dentrix/SQL detected)"
        } else {
            $vDetails += Add-VerifyLine 'INFO' '[opt]' 'Security: Defender exclusions' 'none configured'
        }
    } catch { }

    # BitLocker on system drive
    try {
        if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
            $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
            if ($bl.EncryptionPercentage -gt 0) {
                $vDetails += Add-VerifyLine 'INFO' '[opt]' 'Security: BitLocker on C:' "ACTIVE ($($bl.EncryptionPercentage)%, $($bl.ProtectionStatus))"
            } else {
                $vDetails += Add-VerifyLine 'INFO' '[opt]' 'Security: BitLocker on C:' 'not active'
            }
        }
    } catch { }
    $vDetails += ""

    # ===== Naming convention =====
    # iDezign baseline is dd-MM-yy for both computer name and "Clean dd-MM-yy" for user.
    # This is INFO-only: many deployed workstations have client-chosen names.
    if ($env:COMPUTERNAME -match '^\d{2}-\d{2}-\d{2}$') {
        $vDetails += Add-VerifyLine 'INFO' '[opt]' 'Naming: computer name' "matches dd-MM-yy pattern ($env:COMPUTERNAME)"
    } else {
        $vDetails += Add-VerifyLine 'INFO' '[opt]' 'Naming: computer name' "$env:COMPUTERNAME (doesn't match dd-MM-yy)"
    }

    # ===== Pre-flight helper status summary =====
    # Just call them to show the module is loaded and the helpers respond.
    # No verification implications - they just record current state.
    if (Get-Command Test-iDezignDiskSpace -ErrorAction SilentlyContinue) {
        $vDetails += ""
        $vDetails += "  Module pre-flight helpers status:"
        $vDetails += "  (these are the same helpers Cleanup uses for pre-flight)"
        $vDetails += "  - Test-iDezignDiskSpace : available"
        $vDetails += "  - Test-iDezignNetwork   : available"
        $vDetails += "  - Test-iDezignBitLocker : available"
        $vDetails += "  - Get-iDezignActivationStatus : available"
        $vDetails += "  - Sync-SystemTime       : available (NOT called - read-only mode)"
    }

    # Count passes/fails for headline. Lines built by Add-VerifyLine are now
    # severity-tagged objects, so we read .Severity directly - more reliable
    # than regex. Plain-string lines (e.g. blank separators or the module-
    # availability lines) fall back to text matching.
    function Get-VerifySeverity {
        param($Line)
        if ($Line -isnot [string] -and $Line.Severity) { return [string]$Line.Severity }
        $t = (Get-DetailText -Line $Line)
        if     ($t -match '^\s*PASS\s') { return 'pass' }
        elseif ($t -match '^\s*FAIL\s') { return 'fail' }
        elseif ($t -match '^\s*INFO\s') { return 'info' }
        return 'plain'
    }
    $passCount = ($vDetails | Where-Object { (Get-VerifySeverity $_) -eq 'pass' }).Count
    $failCount = ($vDetails | Where-Object { (Get-VerifySeverity $_) -eq 'fail' }).Count
    $infoCount = ($vDetails | Where-Object { (Get-VerifySeverity $_) -eq 'info' }).Count

    Add-Finding -Section "iDezign Configuration Verification" -Verdict $vVerdict `
                -Headline "$passCount pass, $failCount fail, $infoCount info" `
                -Details $vDetails -Issues $vIssues

    $Snapshot['Verification'] = @{
        Pass = $passCount; Fail = $failCount; Info = $infoCount
        Verdict = $vVerdict
    }
} catch {
    Add-Finding -Section "iDezign Configuration Verification" -Verdict 'ATTENTION' `
                -Headline "Verification probe failed" -Details @("Error: $($_.Exception.Message)")
}

Write-Host "    done." -ForegroundColor DarkGray

#endregion

#region --- 11. Compare to last snapshot ------------------------------------

$lastSnapshot = Get-ChildItem $SnapshotDir -Filter 'Snapshot_*.json' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1

$compareDetails = @()
if ($lastSnapshot) {
    try {
        $prev = Get-Content $lastSnapshot.FullName -Raw | ConvertFrom-Json

        $compareDetails += "Previous snapshot: $($lastSnapshot.Name) ($($lastSnapshot.LastWriteTime))"
        $compareDetails += ""

        # System uptime
        if ($prev.System.UptimeDays -ne $null -and $Snapshot.System.UptimeDays -ne $null) {
            $compareDetails += "Uptime    : was $($prev.System.UptimeDays)d, now $($Snapshot.System.UptimeDays)d"
        }
        # RAM
        if ($prev.MemoryCPU.FreeRAM_MB -ne $null) {
            $delta = $Snapshot.MemoryCPU.FreeRAM_MB - $prev.MemoryCPU.FreeRAM_MB
            $compareDetails += "RAM free  : was $($prev.MemoryCPU.FreeRAM_MB) MB, now $($Snapshot.MemoryCPU.FreeRAM_MB) MB ($(if($delta -ge 0){'+'})$delta)"
        }
        # Volume C: free
        $prevC = $prev.Volumes | Where-Object Letter -eq 'C'
        $nowC  = $Snapshot.Volumes | Where-Object Letter -eq 'C'
        if ($prevC -and $nowC) {
            $delta = $nowC.FreeGB - $prevC.FreeGB
            $compareDetails += "C: free   : was $($prevC.FreeGB) GB, now $($nowC.FreeGB) GB ($(if($delta -ge 0){'+'})$([math]::Round($delta,1)))"
        }
        # Defender sig age
        if ($prev.Security.SigAgeDays -ne $null) {
            $compareDetails += "Sig age   : was $($prev.Security.SigAgeDays)d, now $($Snapshot.Security.SigAgeDays)d"
        }
        # Event errors
        if ($prev.Events.SystemErrors7d -ne $null) {
            $compareDetails += "Sys errs 7d: was $($prev.Events.SystemErrors7d), now $($Snapshot.Events.SystemErrors7d)"
        }
    } catch {
        $compareDetails += "Could not parse previous snapshot: $($_.Exception.Message)"
    }
    Add-Finding -Section "Compare to last run" -Verdict 'OK' `
                -Headline "Diff against $($lastSnapshot.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" -Details $compareDetails
} else {
    Add-Finding -Section "Compare to last run" -Verdict 'OK' `
                -Headline "No prior snapshot - this is the first run on this machine" -Details @()
}

# Save current snapshot
try {
    $Snapshot | ConvertTo-Json -Depth 10 | Set-Content -Path $SnapshotFn -Encoding UTF8
    # Rotate: keep newest 10
    Get-ChildItem $SnapshotDir -Filter 'Snapshot_*.json' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 10 | Remove-Item -Force -ErrorAction SilentlyContinue
} catch { }

#endregion

#region --- Build Top Issues ranking ----------------------------------------
# Severity-weighted, deduped, capped at 5 entries for the on-screen summary.

$allIssues = $Findings | Where-Object { $_.Issues.Count -gt 0 } | ForEach-Object {
    foreach ($i in $_.Issues) {
        [PSCustomObject]@{ Severity = $_.Severity; Section = $_.Section; Issue = $i }
    }
}
$topIssues = $allIssues | Sort-Object Severity -Descending | Select-Object -First 5

#endregion

#region --- Write text report -----------------------------------------------

$elapsed = (Get-Date) - $ScriptStart
$elapsedStr = "{0}m {1}s" -f $elapsed.Minutes, $elapsed.Seconds

$txt = @()
$txt += "============================================================"
$txt += "  iDezign Diagnostics Report"
$txt += "  Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$txt += "  Computer  : $env:COMPUTERNAME"
$txt += "  User      : $env:USERNAME"
$txt += "  Runtime   : $elapsedStr"
$txt += "============================================================"
$txt += ""
$txt += "SUMMARY"
$txt += "-------"
foreach ($f in $Findings) {
    $marker = switch ($f.Verdict) { 'CRITICAL' {'[CRIT]'} 'ATTENTION' {'[ATTN]'} default {'[ OK ]'} }
    $txt += ("  {0} {1,-22} {2}" -f $marker, $f.Section, $f.Headline)
}
$txt += ""
if ($topIssues) {
    $txt += "TOP ISSUES TO INVESTIGATE"
    $txt += "-------------------------"
    $rank = 0
    foreach ($t in $topIssues) {
        $rank++
        $txt += "  $rank. [$($t.Section)] $($t.Issue)"
    }
    $txt += ""
}
$txt += "============================================================"
$txt += "  DETAILED FINDINGS"
$txt += "============================================================"
foreach ($f in $Findings) {
    $txt += ""
    $txt += "[$($f.Verdict)] $($f.Section) - $($f.Headline)"
    $txt += ("-" * 60)
    foreach ($d in $f.Details) { $txt += "  $(Get-DetailText -Line $d)" }
}

$txt -join "`r`n" | Set-Content -Path $ReportTxt -Encoding UTF8

#endregion

#region --- Write HTML report -----------------------------------------------

$verdictColor = @{
    'OK'        = '#1e8e3e'   # green
    'ATTENTION' = '#e8710a'   # orange
    'CRITICAL'  = '#d93025'   # red
}
$verdictBg = @{
    'OK'        = '#e6f4ea'
    'ATTENTION' = '#fef7e0'
    'CRITICAL'  = '#fce8e6'
}

$css = @'
<style>
  body { font-family: -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif; background:#f6f7f9; color:#202124; margin:0; padding:24px; }
  .container { max-width:1100px; margin:0 auto; }
  h1 { margin:0 0 4px 0; font-size:28px; }
  .meta { color:#5f6368; font-size:13px; margin-bottom:24px; }
  .summary-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(260px,1fr)); gap:12px; margin-bottom:32px; }
  .card { padding:14px 16px; border-radius:8px; border-left:4px solid; background:#fff; box-shadow:0 1px 2px rgba(0,0,0,0.05); display:block; text-decoration:none; color:inherit; cursor:pointer; transition:transform 0.1s ease, box-shadow 0.1s ease; position:relative; }
  .card::after { content:'›'; position:absolute; right:14px; top:50%; transform:translateY(-50%); font-size:24px; color:#9aa0a6; opacity:0.5; transition:opacity 0.1s, transform 0.1s; }
  .card:hover { transform:translateY(-2px); box-shadow:0 4px 12px rgba(0,0,0,0.12); }
  .card:hover::after { opacity:1; right:10px; }
  .card:active { transform:translateY(0); }
  .card .verdict { font-size:11px; font-weight:700; letter-spacing:0.5px; }
  .card .section { font-size:15px; font-weight:600; margin:2px 0 4px 0; }
  .card .headline { font-size:13px; color:#5f6368; }
  .top-issues { background:#fff; padding:18px 22px; border-radius:8px; margin-bottom:32px; box-shadow:0 1px 2px rgba(0,0,0,0.05); border-left:4px solid #d93025; }
  .top-issues h2 { margin:0 0 12px 0; font-size:18px; }
  .top-issues ol { margin:0; padding-left:24px; }
  .top-issues li { margin:6px 0; }
  .top-issues .sec { color:#5f6368; font-size:12px; transition:color 0.1s; }
  .top-issues .sec:hover { color:#1a73e8; }
  .detail-section { background:#fff; padding:18px 22px; border-radius:8px; margin-bottom:16px; box-shadow:0 1px 2px rgba(0,0,0,0.05); scroll-margin-top:20px; }
  /* Sticky section headers - h3 sticks to viewport top as user scrolls through the section.
     Negative margins extend it to cover the card's horizontal padding so content
     scrolling underneath doesn't peek out either side. */
  .detail-section h3 { position:sticky; top:0; background:#fff; margin:-18px -22px 4px -22px; padding:14px 22px 10px 22px; font-size:16px; z-index:10; border-bottom:1px solid #eef0f3; border-radius:8px 8px 0 0; }
  .detail-section .sub { color:#5f6368; font-size:13px; margin-bottom:12px; }
  .detail-section pre { background:#f6f7f9; padding:12px; border-radius:4px; font-family:Consolas,Menlo,monospace; font-size:12px; overflow-x:auto; white-space:pre-wrap; word-break:break-all; margin:0; }
  /* Flagged lines inside a pre block - problem lines stand out in red, warnings
     in amber. The .flag-line span wraps the whole line so it reads at a glance. */
  .detail-section pre .flag-line { color:#d93025; font-weight:600; display:inline; }
  .detail-section pre .warn-line { color:#b8650a; font-weight:600; display:inline; }
  .detail-section pre .pass-line { color:#1e8e3e; display:inline; }
  .verdict-OK { color:#1e8e3e; }
  .verdict-ATTENTION { color:#e8710a; }
  .verdict-CRITICAL { color:#d93025; }
  .back-top { text-align:right; margin-top:14px; padding-top:10px; border-top:1px solid #eef0f3; }
  .back-top a { color:#5f6368; text-decoration:none; font-size:12px; padding:5px 12px; border-radius:14px; background:#f6f7f9; transition:background 0.15s, color 0.15s, transform 0.1s; display:inline-block; }
  .back-top a:hover { background:#e8eaed; color:#1a73e8; transform:translateY(-1px); }
  .back-top a:active { transform:translateY(0); }
  /* Floating nav buttons - appear in bottom-right after user scrolls past the tiles.
     Three buttons: help, jump-to-next-issue, back-to-top. */
  .floating-nav { position:fixed; bottom:24px; right:24px; display:flex; flex-direction:column; gap:10px; opacity:0; visibility:hidden; transition:opacity 0.2s, visibility 0.2s; z-index:100; }
  .floating-nav.visible { opacity:1; visibility:visible; }
  .floating-btn { width:46px; height:46px; border-radius:23px; border:none; cursor:pointer; background:#fff; color:#5f6368; font-size:18px; font-weight:600; box-shadow:0 2px 8px rgba(0,0,0,0.15); transition:transform 0.1s, box-shadow 0.1s, color 0.1s, background 0.1s; display:flex; align-items:center; justify-content:center; }
  .floating-btn:hover { transform:translateY(-2px); box-shadow:0 4px 12px rgba(0,0,0,0.2); color:#1a73e8; }
  .floating-btn:active { transform:translateY(0); }
  .floating-btn.has-issues { background:#fef7e0; color:#e8710a; }
  .floating-btn.has-critical { background:#fce8e6; color:#d93025; }
  .floating-btn.has-issues:hover, .floating-btn.has-critical:hover { color:inherit; }
  /* Keyboard shortcuts modal - appears on ? press, dims background. */
  .modal-backdrop { position:fixed; top:0; left:0; right:0; bottom:0; background:rgba(0,0,0,0.5); display:flex; align-items:center; justify-content:center; z-index:1000; opacity:0; visibility:hidden; transition:opacity 0.15s, visibility 0.15s; }
  .modal-backdrop.visible { opacity:1; visibility:visible; }
  .modal { background:#fff; padding:24px 32px; border-radius:8px; min-width:340px; box-shadow:0 8px 32px rgba(0,0,0,0.25); }
  .modal h3 { margin:0 0 16px 0; font-size:18px; }
  .modal table { width:100%; border-collapse:separate; border-spacing:0 4px; }
  .modal td { padding:4px 8px; vertical-align:middle; }
  .modal td.key { font-family:Consolas,Menlo,monospace; background:#f6f7f9; border:1px solid #e8eaed; border-radius:4px; text-align:center; width:60px; font-weight:600; font-size:13px; }
  .modal .hint { color:#5f6368; font-size:12px; margin-top:16px; text-align:center; }
  /* Print stylesheet - clean PDF/printer output. Hide all navigation chrome,
     ensure detail sections don't get split across pages, swap sticky headers
     to static so they don't repeat awkwardly. */
  @media print {
    body { background:#fff; padding:12px; color:#000; }
    .summary-grid, .floating-nav, .back-top, .modal-backdrop, .card::after { display:none !important; }
    .meta { color:#000; }
    .top-issues { page-break-after:avoid; box-shadow:none; border:1px solid #ccc; }
    .detail-section { page-break-inside:avoid; box-shadow:none; border:1px solid #ccc; margin-bottom:12px; }
    .detail-section h3 { position:static; background:#fff; border-bottom:1px solid #ccc; margin:-18px -22px 4px -22px; }
    .detail-section pre { font-size:9pt; background:#fafafa; border:1px solid #e0e0e0; }
    .footer { color:#666; }
  }
  .footer { text-align:center; color:#9aa0a6; font-size:12px; margin-top:32px; }
</style>
'@

$html = @()
$html += "<!DOCTYPE html><html><head><meta charset='utf-8'><title>iDezign Diagnostics - $env:COMPUTERNAME</title>$css</head><body><div class='container'>"
$html += "<h1>iDezign Diagnostics Report</h1>"
$html += "<div class='meta'>Computer: <strong>$env:COMPUTERNAME</strong> &nbsp;|&nbsp; User: $env:USERNAME &nbsp;|&nbsp; Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;|&nbsp; Runtime $elapsedStr &nbsp;|&nbsp; <span style='color:#9aa0a6;'>v$ScriptVersion</span> &nbsp;|&nbsp; <span style='color:#9aa0a6;'>Press <kbd style='background:#f6f7f9;border:1px solid #e8eaed;border-radius:3px;padding:1px 5px;font-family:Consolas,monospace;font-size:11px;'>?</kbd> for keyboard shortcuts</span></div>"

# Helper - slugify section name for use as HTML anchor id (e.g. "System snapshot" -> "section-system-snapshot")
function Get-SectionSlug {
    param([string]$Name)
    $s = $Name.ToLower() -replace '[^a-z0-9]+','-' -replace '^-+','' -replace '-+$',''
    return "section-$s"
}

# Pattern-match a plain string detail line to a severity. This is the FALLBACK
# path for sections that still emit plain strings (not yet migrated to New-Detail).
# Tagged lines skip this entirely and use their explicit severity.
function Get-LineSeverityFromText {
    param([string]$Raw)
    $trimmed = $Raw.TrimStart()
    if     ($trimmed -match '^FAIL\b') { return 'fail' }
    elseif ($trimmed -match '^PASS\b') { return 'pass' }
    elseif ($Raw -match '(?i)\b(FAILED|ERROR|CRITICAL)\b' -or
            $Raw -match '(?i)\bnot activated\b' -or
            $Raw -match '(?i)\bexpired\b' -or
            $Raw -match '(?i)\bmissing\b') { return 'fail' }
    elseif ($Raw -match '(?i)\b(WARNING|ATTENTION|expiring|out of date|could not|unable to|degraded)\b') { return 'warn' }
    return 'plain'
}

# Takes a finding's detail lines (mix of tagged objects and/or plain strings)
# and returns an HTML string with each line HTML-encoded and wrapped in a color
# span based on its severity. Tagged lines use their explicit .Severity; plain
# strings are pattern-matched via Get-LineSeverityFromText. This is what makes
# the flagged lines pop red/amber/green inside each tile's detail <pre> block.
function Format-DetailLines {
    param([array]$Lines)

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Lines) {
        # Resolve text + severity from either form
        if ($item -is [string]) {
            $text = $item
            $sev  = Get-LineSeverityFromText -Raw $text
        } else {
            $text = Get-DetailText -Line $item
            $sev  = if ($item.Severity) { [string]$item.Severity } else { 'plain' }
        }

        $enc = [System.Web.HttpUtility]::HtmlEncode($text)
        switch ($sev) {
            'fail'  { $out.Add("<span class='flag-line'>$enc</span>") }
            'warn'  { $out.Add("<span class='warn-line'>$enc</span>") }
            'pass'  { $out.Add("<span class='pass-line'>$enc</span>") }
            default { $out.Add($enc) }
        }
    }
    return ($out -join "`r`n")
}

# Reorder so the iDezign Configuration Verification section sits at the TOP of
# the report (it's the baseline pass/fail summary - the most useful thing to see
# first). It's collected near the end as Section 12/13, so we pull it to the
# front of the render order here. Both the summary tile grid AND the detail
# sections below follow this same order, so it leads in both places.
$verifyFinding = $Findings | Where-Object { $_.Section -like '*Configuration Verification*' } | Select-Object -First 1
if ($verifyFinding) {
    $rest = $Findings | Where-Object { $_ -ne $verifyFinding }
    $Findings = [System.Collections.Generic.List[object]]::new()
    $Findings.Add($verifyFinding)
    foreach ($r in $rest) { $Findings.Add($r) }
}

# Summary cards - each card is a clickable anchor that jumps to its detail section below.
# id='top' anchors the "back to top" links from each detail section.
$html += "<div id='top' class='summary-grid'>"
foreach ($f in $Findings) {
    $color = $verdictColor[$f.Verdict]
    $bg    = $verdictBg[$f.Verdict]
    $slug  = Get-SectionSlug -Name $f.Section
    $html += "<a class='card' href='#$slug' style='border-left-color:$color; background:$bg;' title='Jump to details'>"
    $html += "<div class='verdict verdict-$($f.Verdict)'>$($f.Verdict)</div>"
    $html += "<div class='section'>$($f.Section)</div>"
    $html += "<div class='headline'>$([System.Web.HttpUtility]::HtmlEncode($f.Headline))</div>"
    $html += "</a>"
}
$html += "</div>"

# Top issues - section tag is now a clickable link
if ($topIssues) {
    $html += "<div class='top-issues'>"
    $html += "<h2>Top issues to investigate</h2>"
    $html += "<ol>"
    foreach ($t in $topIssues) {
        $slug = Get-SectionSlug -Name $t.Section
        $html += "<li><a href='#$slug' class='sec' style='text-decoration:none;'>[$($t.Section)]</a> $([System.Web.HttpUtility]::HtmlEncode($t.Issue))</li>"
    }
    $html += "</ol></div>"
}

# Detailed findings - each gets an id matching its tile's anchor target
foreach ($f in $Findings) {
    $color = $verdictColor[$f.Verdict]
    $slug  = Get-SectionSlug -Name $f.Section
    $html += "<div id='$slug' class='detail-section' style='border-left:4px solid $color;'>"
    $html += "<h3>$($f.Section) <span class='verdict-$($f.Verdict)' style='font-size:13px;'>[$($f.Verdict)]</span></h3>"
    $html += "<div class='sub'>$([System.Web.HttpUtility]::HtmlEncode($f.Headline))</div>"
    if ($f.Details.Count -gt 0) {
        $html += "<pre>$(Format-DetailLines -Lines $f.Details)</pre>"
    }
    # Back-to-top link - returns to the tiles grid at the top of the report
    $html += "<div class='back-top'><a href='#top'>&#8593; Back to top</a></div>"
    $html += "</div>"
}

$html += "<div class='footer'>iDezign Technology - Diagnostic Report - $(Get-Date -Format 'yyyy')</div>"

# --- Floating navigation buttons (visible after scrolling past the tiles) ---
# Three buttons stacked vertically in bottom-right corner:
#   ?  = show keyboard shortcuts modal
#   !  = jump to next ATTENTION/CRITICAL section (styled if any issues exist)
#   ↑  = scroll back to top
$html += @"
<div class='floating-nav' id='floatingNav' role='navigation' aria-label='Report navigation'>
  <button class='floating-btn' id='btnHelp' title='Keyboard shortcuts (?)' aria-label='Show keyboard shortcuts'>?</button>
  <button class='floating-btn' id='btnNextIssue' title='Next issue (n)' aria-label='Jump to next attention or critical section'>!</button>
  <button class='floating-btn' id='btnTop' title='Back to top (g)' aria-label='Back to top'>&#8593;</button>
</div>
"@

# --- Keyboard shortcuts modal (hidden until ? pressed or help button clicked) ---
$html += @"
<div class='modal-backdrop' id='shortcutsModal' role='dialog' aria-modal='true' aria-labelledby='shortcutsTitle'>
  <div class='modal'>
    <h3 id='shortcutsTitle'>Keyboard shortcuts</h3>
    <table>
      <tr><td class='key'>j</td><td>Next section</td></tr>
      <tr><td class='key'>k</td><td>Previous section</td></tr>
      <tr><td class='key'>g</td><td>Back to top</td></tr>
      <tr><td class='key'>G</td><td>Last section</td></tr>
      <tr><td class='key'>n</td><td>Next attention/critical issue</td></tr>
      <tr><td class='key'>?</td><td>Show this help</td></tr>
      <tr><td class='key'>Esc</td><td>Close this help</td></tr>
    </table>
    <div class='hint'>Click outside this box or press Esc to close.</div>
  </div>
</div>
"@

# JavaScript: smooth-scroll for anchors, floating button show/hide on scroll,
# keyboard navigation between sections, shortcuts modal toggle, jump-to-next-issue
# logic with wraparound. All defensive: respects modifier keys, doesn't trigger
# when user is typing in (hypothetical) input fields.
$js = @'
<script>
document.addEventListener('DOMContentLoaded', function() {
  // --- Smooth-scroll for all in-page anchors (tiles, top issues, back-to-top) ---
  document.querySelectorAll('a[href^="#"]').forEach(function(link) {
    link.addEventListener('click', function(e) {
      var target = document.getElementById(this.getAttribute('href').substring(1));
      if (target) {
        e.preventDefault();
        target.scrollIntoView({ behavior: 'smooth', block: 'start' });
        // Save original inline bg so we cleanup correctly for any target
        // (including #top which is the summary-grid with no inline bg).
        var origBg = target.style.background;
        target.style.transition = 'background 0.3s';
        target.style.background = '#fff8e1';
        setTimeout(function(){ target.style.background = origBg; }, 1200);
      }
    });
  });

  // --- Helper: find which detail-section is currently in view ---
  // Returns the index of the section whose top is closest to (but not below)
  // the current scroll position. Used for j/k navigation and "next issue".
  function getCurrentSectionIndex() {
    var sections = Array.from(document.querySelectorAll('.detail-section'));
    var scrollY = window.scrollY || window.pageYOffset;
    var viewport = scrollY + 80;  // slight offset so a section "counts" once it's well into view
    for (var i = 0; i < sections.length; i++) {
      if (sections[i].offsetTop > viewport) {
        return Math.max(0, i - 1);
      }
    }
    return sections.length - 1;
  }

  function scrollToSection(idx) {
    var sections = document.querySelectorAll('.detail-section');
    if (idx >= 0 && idx < sections.length) {
      sections[idx].scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  }

  function scrollToTop() {
    var top = document.getElementById('top');
    if (top) {
      top.scrollIntoView({ behavior: 'smooth', block: 'start' });
    } else {
      window.scrollTo({ top: 0, behavior: 'smooth' });
    }
  }

  // --- Find next ATTENTION/CRITICAL section after current position ---
  // Wraps around to start of document if no issues found below current section.
  function nextIssue() {
    var sections = Array.from(document.querySelectorAll('.detail-section'));
    var current = getCurrentSectionIndex();
    function isIssue(section) {
      var v = section.querySelector('h3 span');
      return v && (v.classList.contains('verdict-ATTENTION') || v.classList.contains('verdict-CRITICAL'));
    }
    // Search forward from current+1
    for (var i = current + 1; i < sections.length; i++) {
      if (isIssue(sections[i])) {
        sections[i].scrollIntoView({ behavior: 'smooth', block: 'start' });
        return;
      }
    }
    // Wrap around: search from start to current
    for (var i = 0; i <= current; i++) {
      if (isIssue(sections[i])) {
        sections[i].scrollIntoView({ behavior: 'smooth', block: 'start' });
        return;
      }
    }
    // No issues found - flash the help icon to suggest reviewing manually
  }

  // --- Floating button: style "next issue" based on overall severity ---
  // If any CRITICAL exists, button is red. If any ATTENTION but no CRITICAL, orange.
  // If only OK sections, neutral. Done once at load - state doesn't change.
  var btnNextIssue = document.getElementById('btnNextIssue');
  if (btnNextIssue) {
    var anyCritical = !!document.querySelector('.detail-section h3 span.verdict-CRITICAL');
    var anyAttention = !!document.querySelector('.detail-section h3 span.verdict-ATTENTION');
    if (anyCritical) btnNextIssue.classList.add('has-critical');
    else if (anyAttention) btnNextIssue.classList.add('has-issues');
  }

  // --- Show/hide floating nav based on scroll position ---
  var nav = document.getElementById('floatingNav');
  function updateNav() {
    if (window.scrollY > 400) {
      nav.classList.add('visible');
    } else {
      nav.classList.remove('visible');
    }
  }
  window.addEventListener('scroll', updateNav, { passive: true });
  updateNav();

  // --- Floating button click handlers ---
  document.getElementById('btnTop').addEventListener('click', scrollToTop);
  document.getElementById('btnNextIssue').addEventListener('click', nextIssue);
  document.getElementById('btnHelp').addEventListener('click', function() {
    document.getElementById('shortcutsModal').classList.add('visible');
  });

  // --- Modal: click backdrop to close, but not clicks inside the modal box ---
  var modal = document.getElementById('shortcutsModal');
  modal.addEventListener('click', function(e) {
    if (e.target === modal) modal.classList.remove('visible');
  });

  // --- Keyboard navigation ---
  // j/k = next/prev section, g = top, G = bottom, n = next issue,
  // ? = show help, Esc = close help. Defensive: skip if modifier keys held
  // or user is typing in an input (no inputs currently, but safer this way).
  document.addEventListener('keydown', function(e) {
    if (e.ctrlKey || e.altKey || e.metaKey) return;
    var tag = (e.target.tagName || '').toUpperCase();
    if (tag === 'INPUT' || tag === 'TEXTAREA' || e.target.isContentEditable) return;

    // Escape always closes the modal regardless of other state
    if (e.key === 'Escape') {
      modal.classList.remove('visible');
      return;
    }

    // If modal is open, ignore other keys
    if (modal.classList.contains('visible')) return;

    var sections = document.querySelectorAll('.detail-section');
    var current = getCurrentSectionIndex();

    switch (e.key) {
      case 'j':
        e.preventDefault();
        scrollToSection(Math.min(current + 1, sections.length - 1));
        break;
      case 'k':
        e.preventDefault();
        scrollToSection(Math.max(current - 1, 0));
        break;
      case 'g':
        e.preventDefault();
        scrollToTop();
        break;
      case 'G':
        e.preventDefault();
        scrollToSection(sections.length - 1);
        break;
      case 'n':
        e.preventDefault();
        nextIssue();
        break;
      case '?':
        e.preventDefault();
        modal.classList.add('visible');
        break;
    }
  });
});
</script>
'@
$html += $js

$html += "</div></body></html>"

# Need System.Web for HtmlEncode
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

$html -join "`r`n" | Set-Content -Path $ReportHtml -Encoding UTF8

#endregion

#region --- On-screen summary -----------------------------------------------

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Diagnostics Summary - $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   (took $elapsedStr)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($f in $Findings) {
    $color = switch ($f.Verdict) { 'CRITICAL' {'Red'} 'ATTENTION' {'Yellow'} default {'Green'} }
    $marker = switch ($f.Verdict) { 'CRITICAL' {'[ X ]'} 'ATTENTION' {'[ ! ]'} default {'[ OK]'} }
    Write-Host ("  {0} " -f $marker) -ForegroundColor $color -NoNewline
    Write-Host ("{0,-22} " -f $f.Section) -NoNewline
    Write-Host $f.Headline -ForegroundColor DarkGray
}

Write-Host ""
if ($topIssues) {
    Write-Host "  Top issues to investigate:" -ForegroundColor Yellow
    $rank = 0
    foreach ($t in $topIssues) {
        $rank++
        $color = if ($t.Severity -eq 2) {'Red'} else {'Yellow'}
        Write-Host ("    {0}. " -f $rank) -ForegroundColor $color -NoNewline
        Write-Host ("[{0}] " -f $t.Section) -ForegroundColor DarkGray -NoNewline
        Write-Host $t.Issue
    }
    Write-Host ""
} else {
    Write-Host "  No critical issues flagged. Nice." -ForegroundColor Green
    Write-Host ""
}

Write-Host "  Reports written to:" -ForegroundColor Cyan
Write-Host "    Text : $ReportTxt"
Write-Host "    HTML : $ReportHtml"
Write-Host "    JSON : $SnapshotFn"
Write-Host ""

# Open the HTML report in the default browser. Wrap in try/catch so the script
# doesn't blow up if this happens to run on Server Core or any other system
# without a default browser association for .html.
Write-Host "  Opening HTML report in default browser..." -ForegroundColor DarkGray
try {
    Start-Process $ReportHtml -ErrorAction Stop
} catch {
    Write-Host "  Could not auto-open HTML: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Open it manually from: $ReportHtml" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Pause so the elevated PowerShell window doesn't auto-close on script exit.
# (Same reason we added this to the remediation script - launching via .bat
# with Start-Process -Verb RunAs spawns a new window that closes on exit.)
Read-Host "Press Enter to close this window"

#endregion
