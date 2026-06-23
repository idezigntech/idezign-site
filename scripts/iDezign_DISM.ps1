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

$ScriptVersion = '2026.06.03-dism-v1'

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

# Use Show-VersionCheck if available (it's defined in Common.psm1)
if (Get-Command -Name Show-VersionCheck -ErrorAction SilentlyContinue) {
    Show-VersionCheck -ScriptName 'iDezign_DISM.ps1' -CurrentVersion $ScriptVersion -ScriptDir $ScriptDir
}

#endregion

#region --- Banner ---------------------------------------------------------

if (Get-Command -Name Get-iDezignBanner -ErrorAction SilentlyContinue) {
    Get-iDezignBanner -Title 'DISM + SFC Health Pass' -Subtitle 'Component store repair + system file check'
} else {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  iDezign Toolkit - DISM + SFC Health Pass" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Script version : $ScriptVersion" -ForegroundColor DarkGray
    Write-Host "  Started        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host ""
}

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
    param(
        [Parameter(Mandatory)] [string] $Phase   # CheckHealth / ScanHealth / RestoreHealth
    )
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ("  DISM /Online /Cleanup-Image /{0}" -f $Phase) -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & DISM.exe /Online /Cleanup-Image /$Phase 2>&1 | Out-String
    $code = $LASTEXITCODE
    $sw.Stop()
    Write-Host $output
    Write-Host ("  ({0} done in {1:N1}s, exit code {2})" -f $Phase, $sw.Elapsed.TotalSeconds, $code) -ForegroundColor DarkGray
    return @{ ExitCode = $code; Output = $output }
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
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  SFC /scannow" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = & sfc.exe /scannow 2>&1 | Out-String
    $code = $LASTEXITCODE
    $sw.Stop()
    Write-Host $output
    Write-Host ("  (SFC done in {0:N1}s, exit code {1})" -f $sw.Elapsed.TotalSeconds, $code) -ForegroundColor DarkGray
    return @{ ExitCode = $code; Output = $output }
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

# Phase 1: baseline CheckHealth (fast, no Windows Update contact)
$beforeCheck = Invoke-DismPhase -Phase 'CheckHealth'
$beforeStatus = ConvertTo-DismStatus $beforeCheck.Output

# Phase 2: ScanHealth (deeper, sets corruption flag)
$scan = Invoke-DismPhase -Phase 'ScanHealth'
$scanStatus = ConvertTo-DismStatus $scan.Output

# Phase 3: RestoreHealth - only if scan found something fixable
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

# Phase 4: SFC /scannow (always runs - catches system files DISM doesn't touch)
$sfc = Invoke-SfcScan
$sfcStatus = ConvertTo-SfcStatus $sfc.Output

# Phase 5: after-snapshot CheckHealth (so the summary can show change)
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
