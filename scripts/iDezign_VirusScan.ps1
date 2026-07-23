# ============================================================================
#  iDezign_VirusScan.ps1
#  Standalone Microsoft Defender scan - Quick / Full - with live progress,
#  threat report, and a timestamped log file on the Desktop.
#
#  History: this was Cleanup Phase 1i until v3.5. Split out so a scan can be
#  run any time from the Toolkit menu without dragging a full Cleanup along.
#  Same choices, same engine: signature update first, scan in a background
#  job with a 60-second heartbeat, then a threat report scoped to detections
#  that happened during THIS scan window.
#
#  Choices:
#    Q = Quick scan (3-5 min)      - active malware locations only
#    F = Full scan (30 min - 4 hr) - every file, including archives
#    S = Skip / exit (or just press Enter)
#
#  Run as Administrator. No reboot.
# ============================================================================

$ScriptVersion = '2026.07.03-virusscan-v1.0'

#region --- Safety + module load -------------------------------------------

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Re-launch from the iDezign Toolkit GUI (which auto-elevates) or right-click -> Run as Administrator." -ForegroundColor Yellow
    Pause
    exit 1
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$modulePath = Join-Path $ScriptDir 'iDezign_Common.psm1'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force -ErrorAction SilentlyContinue
}

if (Get-Command -Name Show-VersionCheck -ErrorAction SilentlyContinue) {
    Show-VersionCheck -ScriptName 'iDezign_VirusScan.ps1' -CurrentVersion $ScriptVersion -ScriptDir $ScriptDir
}

#endregion

#region --- Banner ---------------------------------------------------------

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  iDezign Toolkit - Virus Scan (Microsoft Defender)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Script version : $ScriptVersion" -ForegroundColor DarkGray
Write-Host "  Started        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host ""

#endregion

#region --- Scan type prompt ------------------------------------------------

Write-Host "  Quick scan = 3-5 min, Full scan = 30 min - 4 hours." -ForegroundColor DarkYellow
$scanType = 'None'
do {
    $raw = Read-Host "Defender scan: (Q)uick / (F)ull / (S)kip  [Enter = Skip]"
    $answer = $raw.Trim().ToUpper()
    # Empty (just Enter pressed) = Skip
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = 'S' }
    switch ($answer) {
        'Q'    { $scanType = 'Quick' }
        'F'    { $scanType = 'Full' }
        'S'    { $scanType = 'None' }
        default { $answer = $null; Write-Host "  Please enter Q, F, S, or press Enter to skip." -ForegroundColor Yellow }
    }
} while (-not $answer)

if ($scanType -eq 'None') {
    Write-Host ""
    Write-Host "  Skipped - nothing scanned." -ForegroundColor DarkGray
    Start-Sleep -Seconds 2
    exit 0
}

#endregion

#region --- Run the scan ----------------------------------------------------

Write-Host "`nRunning Microsoft Defender $($scanType.ToLower()) scan..." -ForegroundColor Green

# Scan log on the Desktop (standalone tool - no staging dir like Cleanup had).
# Created before the scan starts so even errors get logged; timestamped so
# multiple runs don't overwrite each other.
$scanLogFile = Join-Path "$env:USERPROFILE\Desktop" ("iDezign_VirusScan_$(Get-Date -Format 'yyyy-MM-dd_HHmm').txt")

# Helper: write to both console and the log file.
function Write-ScanLog {
    param(
        [string]$Text,
        [string]$Color = 'DarkGray'
    )
    Write-Host $Text -ForegroundColor $Color
    try {
        $logLine = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Text"
        Add-Content -Path $scanLogFile -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

Write-ScanLog "Scan log: $scanLogFile" 'DarkGray'

# Are Defender cmdlets available? (They aren't on machines where Defender
# has been replaced by a 3rd-party AV like CrowdStrike or Sophos.)
if (-not (Get-Command Start-MpScan -ErrorAction SilentlyContinue)) {
    Write-ScanLog "Defender cmdlets not available - is Microsoft Defender installed and enabled?" 'Yellow'
    Write-ScanLog "If a 3rd-party AV is managing protection, use that product's scanner instead." 'DarkYellow'
} else {
    try {
        # 1. Update signatures first - no point scanning with stale definitions
        Write-ScanLog "Updating Defender signatures..." 'DarkGray'
        try {
            Update-MpSignature -ErrorAction Stop
            Write-ScanLog "Signatures updated." 'DarkGray'
        } catch {
            Write-ScanLog "Signature update failed (continuing with current sigs): $($_.Exception.Message)" 'DarkYellow'
        }

        # 2. Capture start time so we can identify NEW threats afterwards
        $scanStart = Get-Date
        Write-ScanLog "Starting $scanType scan at $($scanStart.ToString('HH:mm:ss'))..." 'DarkGray'
        $estDuration = if ($scanType -eq 'Quick') { '3-5 minutes' } else { '30 min to 4 hours' }
        Write-ScanLog "Estimated duration: $estDuration." 'DarkGray'

        # 3. Kick off as a background job so we can poll status
        $mpScanType = "${scanType}Scan"  # 'QuickScan' or 'FullScan' - what Start-MpScan expects
        $scanJob = Start-Job -Name "iDezign-${scanType}Scan" -ScriptBlock {
            param($type)
            Start-MpScan -ScanType $type -ErrorAction Stop
        } -ArgumentList $mpScanType

        # 4. Poll loop with progress every 60 sec (quick scan may finish in
        # the first sleep cycle - that's fine, loop exits cleanly)
        $pollSec = 60
        while ($scanJob.State -eq 'Running') {
            Start-Sleep -Seconds $pollSec
            $elapsed = (Get-Date) - $scanStart
            $elapsedStr = '{0:hh\:mm\:ss}' -f $elapsed
            Write-ScanLog "  Scan still running... elapsed: $elapsedStr" 'DarkGray'
        }

        # 5. Collect results
        $scanError = $null
        try {
            $null = Receive-Job -Job $scanJob -ErrorAction Stop
        } catch {
            $scanError = $_.Exception.Message
        }
        Remove-Job -Job $scanJob -Force -ErrorAction SilentlyContinue

        $totalElapsed = (Get-Date) - $scanStart
        $totalStr = '{0:hh\:mm\:ss}' -f $totalElapsed

        if ($scanError) {
            Write-ScanLog "Scan job ended with error: $scanError" 'Red'
        } else {
            Write-ScanLog "Scan completed in $totalStr." 'Green'
        }

        # 6. Check for threats detected during this scan window
        try {
            $allThreats = Get-MpThreatDetection -ErrorAction Stop
            $newThreats = $allThreats | Where-Object { $_.InitialDetectionTime -ge $scanStart }
            if ($newThreats) {
                Write-ScanLog "" 'Red'
                Write-ScanLog "*** $($newThreats.Count) THREAT(S) DETECTED during scan ***" 'Red'
                foreach ($t in $newThreats) {
                    $tName = try { (Get-MpThreat -ThreatID $t.ThreatID -ErrorAction Stop).ThreatName } catch { "ID $($t.ThreatID)" }
                    Write-ScanLog "  - $tName" 'Red'
                    Write-ScanLog "    Resources: $($t.Resources -join '; ')" 'Red'
                }
                Write-ScanLog "Review in Windows Security -> Virus & threat protection -> Protection history." 'Yellow'
            } else {
                Write-ScanLog "No threats detected." 'Green'
            }
        } catch {
            Write-ScanLog "Could not query threat history: $($_.Exception.Message)" 'DarkYellow'
        }

        Write-Host ""
        Write-Host "  Full scan log saved to: $scanLogFile" -ForegroundColor Cyan
    } catch {
        Write-ScanLog "ERROR during scan: $($_.Exception.Message)" 'Red'
    }
}

#endregion

Write-Host ""
Write-Host "Press any key to close this window..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
