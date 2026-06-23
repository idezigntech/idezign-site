# ============================================================================
#  iDezign_DISM.ps1
#  Standalone DISM + SFC health pass. Faster than Remediation when you just
#  want to repair the component store and system files without the full
#  Remediation battery (essential services, Defender, time sync, etc).
#
#  Flow:
#    1. CheckHealth (baseline)  - quick "is the store flagged as broken" check
#    2. ScanHealth              - deep scan; sets exit code if corruption found
#    3. RestoreHealth           - actual repair; runs ONLY if scan finds anything
#    4. SFC /scannow            - system file checker pass
#    5. CheckHealth (after)     - re-check; show before/after summary
#
#  Run as Administrator. Closes when done; no auto-reboot.
# ============================================================================

$ScriptVersion = '2026.06.23-dism-v1.1'

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
    Show-VersionCheck -ScriptName 'iDezign_DISM.ps1' -CurrentVersion $ScriptVersion -ScriptDir $ScriptDir
}

#endregion

#region --- Banner ---------------------------------------------------------

# v1.1: don't call Get-iDezignBanner (its parameter names differ by version
# of Common.psm1). Use the fallback banner unconditionally - it's clear,
# self-contained, and won't error on parameter mismatches.
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  iDezign Toolkit - DISM + SFC Health Pass" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Script version : $ScriptVersion" -ForegroundColor DarkGray
Write-Host "  Started        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host ""

#endregion

#region --- Transcript -----------------------------------------------------

$logDir  = "$env:USERPROFILE\Desktop"
$logName = "iDezign_DISM_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"
$logPath = Join-Path $logDir $logName

try {
    Start-Transcript -Path $logPath -Append -ErrorAction Stop | Out-Null
    Write-Host "  Logging to: $logPath" -ForegroundColor DarkGray
    Write-Host ""
} catch {
    Write-Host "  (transcript could not start: $($_.Exception.Message))" -ForegroundColor DarkYellow
    Write-Host ""
}

#endregion

#region --- Helpers --------------------------------------------------------

function Invoke-DismPhase {
    <#
        v1.1: runs DISM as a background job so we can show a live progress
        indicator while it works. DISM's own ASCII progress bar gets lost
        when we capture stdout, so we substitute Write-Progress + a heartbeat
        line every 10 seconds. The transcript still captures the final output.
    #>
    param(
        [Parameter(Mandatory)] [string] $Phase   # CheckHealth / ScanHealth / RestoreHealth
    )
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ("  DISM /Online /Cleanup-Image /{0}" -f $Phase) -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  (running in background - heartbeat every 10s so you know it's alive)" -ForegroundColor DarkGray
    Write-Host ""

    $job = Start-Job -ScriptBlock {
        param($p)
        $output = & DISM.exe /Online /Cleanup-Image /$p 2>&1 | Out-String
        return @{ ExitCode = $LASTEXITCODE; Output = $output }
    } -ArgumentList $Phase

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $nextBeat = 10  # seconds until next heartbeat line

    while ($job.State -eq 'Running') {
        Start-Sleep -Milliseconds 500
        $elapsed = [int]$sw.Elapsed.TotalSeconds

        # Live progress bar at top of terminal (indeterminate spinner)
        Write-Progress `
            -Activity ("DISM /{0}" -f $Phase) `
            -Status ("Running... {0:mm\:ss} elapsed" -f $sw.Elapsed) `
            -PercentComplete -1

        # Heartbeat line every 10s in the transcript stream
        if ($elapsed -ge $nextBeat) {
            Write-Host ("  ...still running   ({0:mm\:ss} elapsed)" -f $sw.Elapsed) -ForegroundColor DarkGray
            $nextBeat += 10
        }
    }

    Write-Progress -Activity ("DISM /{0}" -f $Phase) -Completed

    $result = Receive-Job -Job $job
    Remove-Job -Job $job -Force
    $sw.Stop()

    Write-Host ""
    Write-Host $result.Output
    Write-Host ("  ({0} done in {1:N1}s, exit code {2})" -f $Phase, $sw.Elapsed.TotalSeconds, $result.ExitCode) -ForegroundColor DarkGray

    return @{ ExitCode = $result.ExitCode; Output = $result.Output }
}

function ConvertTo-DismStatus {
    param([string] $Output)
    if (-not $Output) { return 'unknown' }
    if ($Output -match 'No component store corruption detected') { return 'healthy' }
    if ($Output -match 'The component store is repairable')      { return 'repairable' }
    if ($Output -match 'The restore operation completed successfully') { return 'repaired' }
    if ($Output -match 'The component store cannot be repaired') { return 'broken' }
    return 'unknown'
}

function Invoke-SfcScan {
    <#
        v1.1: same job + heartbeat pattern as DISM, but SFC has its own
        nice percentage progress when it prints to host. We still wrap it
        in a job so the heartbeat works consistently across phases.
    #>
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  SFC /scannow" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  (running in background - heartbeat every 10s so you know it's alive)" -ForegroundColor DarkGray
    Write-Host ""

    $job = Start-Job -ScriptBlock {
        $output = & sfc.exe /scannow 2>&1 | Out-String
        return @{ ExitCode = $LASTEXITCODE; Output = $output }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $nextBeat = 10

    while ($job.State -eq 'Running') {
        Start-Sleep -Milliseconds 500
        $elapsed = [int]$sw.Elapsed.TotalSeconds

        Write-Progress `
            -Activity "SFC /scannow" `
            -Status ("Running... {0:mm\:ss} elapsed" -f $sw.Elapsed) `
            -PercentComplete -1

        if ($elapsed -ge $nextBeat) {
            Write-Host ("  ...still running   ({0:mm\:ss} elapsed)" -f $sw.Elapsed) -ForegroundColor DarkGray
            $nextBeat += 10
        }
    }

    Write-Progress -Activity "SFC /scannow" -Completed

    $result = Receive-Job -Job $job
    Remove-Job -Job $job -Force
    $sw.Stop()

    Write-Host ""
    Write-Host $result.Output
    Write-Host ("  (SFC done in {0:N1}s, exit code {1})" -f $sw.Elapsed.TotalSeconds, $result.ExitCode) -ForegroundColor DarkGray

    return @{ ExitCode = $result.ExitCode; Output = $result.Output }
}

function ConvertTo-SfcStatus {
    param([string] $Output)
    if (-not $Output) { return 'unknown' }
    if ($Output -match 'did not find any integrity violations')        { return 'clean' }
    if ($Output -match 'found corrupt files and successfully repaired'){ return 'repaired' }
    if ($Output -match 'found corrupt files but was unable to fix')    { return 'unfixable' }
    if ($Output -match 'could not perform the requested operation')    { return 'failed' }
    return 'unknown'
}

#endregion

#region --- Run the pass ---------------------------------------------------

$beforeCheck = Invoke-DismPhase -Phase 'CheckHealth'
$beforeStatus = ConvertTo-DismStatus $beforeCheck.Output

$scan = Invoke-DismPhase -Phase 'ScanHealth'
$scanStatus = ConvertTo-DismStatus $scan.Output

$restoreRan = $false
$restoreStatus = 'skipped'
if ($scanStatus -eq 'repairable' -or $scan.ExitCode -ne 0) {
    Write-Host ""
    Write-Host "  Scan reported corruption - running RestoreHealth to repair..." -ForegroundColor Yellow
    $restore = Invoke-DismPhase -Phase 'RestoreHealth'
    $restoreRan = $true
    $restoreStatus = ConvertTo-DismStatus $restore.Output
} else {
    Write-Host ""
    Write-Host "  Scan found nothing repairable - skipping RestoreHealth." -ForegroundColor Green
}

$sfc = Invoke-SfcScan
$sfcStatus = ConvertTo-SfcStatus $sfc.Output

$afterCheck = Invoke-DismPhase -Phase 'CheckHealth'
$afterStatus = ConvertTo-DismStatus $afterCheck.Output

#endregion

#region --- Before/After Summary -------------------------------------------

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

function Get-StatusColour {
    param([string]$s)
    switch -Regex ($s) {
        '^(healthy|clean|repaired)$'   { 'Green';  break }
        '^(repairable|skipped)$'       { 'Yellow'; break }
        '^(broken|unfixable|failed)$'  { 'Red';    break }
        default                        { 'Gray' }
    }
}

Write-Host "  DISM /CheckHealth before : " -NoNewline -ForegroundColor DarkGray
Write-Host $beforeStatus -ForegroundColor (Get-StatusColour $beforeStatus)

Write-Host "  DISM /ScanHealth         : " -NoNewline -ForegroundColor DarkGray
Write-Host $scanStatus   -ForegroundColor (Get-StatusColour $scanStatus)

Write-Host "  DISM /RestoreHealth      : " -NoNewline -ForegroundColor DarkGray
Write-Host $restoreStatus -ForegroundColor (Get-StatusColour $restoreStatus)

Write-Host "  SFC /scannow             : " -NoNewline -ForegroundColor DarkGray
Write-Host $sfcStatus    -ForegroundColor (Get-StatusColour $sfcStatus)

Write-Host "  DISM /CheckHealth after  : " -NoNewline -ForegroundColor DarkGray
Write-Host $afterStatus  -ForegroundColor (Get-StatusColour $afterStatus)

Write-Host ""
if ($beforeStatus -ne 'healthy' -and $afterStatus -eq 'healthy') {
    Write-Host "  Result: corruption repaired - component store is now healthy." -ForegroundColor Green
} elseif ($beforeStatus -eq 'healthy' -and $afterStatus -eq 'healthy') {
    Write-Host "  Result: store was healthy before and after - no changes needed." -ForegroundColor Green
} elseif ($afterStatus -in @('broken','unfixable','failed')) {
    Write-Host "  Result: corruption remains - manual inspection required." -ForegroundColor Red
    Write-Host "          Check the log on Desktop and the CBS log at:" -ForegroundColor DarkYellow
    Write-Host "          C:\Windows\Logs\CBS\CBS.log" -ForegroundColor DarkYellow
} else {
    Write-Host "  Result: see phases above for detail." -ForegroundColor Yellow
}

if (Test-Path $logPath) {
    Write-Host ""
    Write-Host "  Full log: $logPath" -ForegroundColor DarkGray
}

Write-Host ""

try { Stop-Transcript | Out-Null } catch { }

Write-Host "Press any key to close this window..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

#endregion
