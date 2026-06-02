# ============================================================================
#  iDezign_Cleanup_Utility.ps1
#  Cleanup: Windows Update loop + optional installs + cleanup + accounts + renames
#  Run as Administrator. Will auto-reboot during the update phase.
# ============================================================================
#  All rename defaults are generated dynamically from Get-Date.
#
#  Flow:
#   * Self-stage to C:\iDezign_Cleanup_Utility\ if launched from a non-local path.
#   * Initial prompts. Answers persisted to state.json for resume-after-update.
#
#   0.  Windows Update loop  (auto-reboot + auto-resume)
#   0b. Pending-reboot sanity check (NEW): if CBS / WU / pending.xml flag any
#       pending operations after the update loop, reboot once more before
#       continuing. This prevents DISM error 0x800f0806 in Phase 2.
#   1.  Install software + config (optional):
#        a. Google Chrome (Enterprise MSI, silent)
#        b. Chrome as default browser for NEW user profiles (DISM XML)
#        c. Claude Desktop (MSIX, machine-wide)
#        d. Malwarebytes installer (download only, no install)
#        e. iDezign-branded TeamViewer Host (silent install)
#        f. Power settings (HDD never, display 1hr, no sleep/hibernate)
#        g. Open-Shell classic Start Menu (via Ninite, + iDezign defaults)
#        h. Network -> Private + File/Print sharing + discovery
#        i. Microsoft Defender scan (Quick / Full / Skip) + log file
#        j. Defender exclusions for Dentrix/SQL paths
#        k. Nuke OneDrive (uninstall + block reinstall + restore folders)
#           + optional Teams personal removal + Microsoft nag disable
#  2.  Cleanup (temp, Windows.old, event logs, DISM, etc.)
#  3.  Ensure REPAIR admin account exists (always runs)
#  4.  Rename user account     (optional)
#  5.  Rename computer         (optional)
#  6.  Final reboot prompt
#
#  REMINDER: delete C:\iDezign_Cleanup_Utility before capturing the image:
#      Remove-Item C:\iDezign_Cleanup_Utility -Recurse -Force
# ============================================================================

param(
    [switch]$ResumeAfterUpdate
)

#region --- Safety checks -----------------------------------------------------

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Use Run-Cleanup.bat (it self-elevates) or right-click -> Run with PowerShell as Admin." -ForegroundColor Yellow
    Pause
    exit 1
}

$ErrorActionPreference = 'Continue'
# VerbosePreference is deliberately SilentlyContinue. Earlier this was 'Continue',
# which caused Import-Module PSWindowsUpdate to flood the console with hundreds of
# "VERBOSE: exporting alias / function ..." lines on every import - looking like a
# hang. All of this script's real user-facing output goes through Write-Host with
# colors, so suppressing verbose loses nothing and removes the noise.
$VerbosePreference     = 'SilentlyContinue'

# Version stamp - bumped when behavior changes. Shown in console banner
# and recorded in transcript log so we can verify deployed version.
$ScriptVersion = '2026.06.01-v2.5-imaging-prep'

$ScriptPath = $MyInvocation.MyCommand.Path

# Load shared module if present. The module lives next to the script.
# This is non-fatal: if the module is missing, the script still works using
# its local copies of the functions, but warns so you notice.
$ModulePath = Join-Path (Split-Path $ScriptPath -Parent) 'iDezign_Common.psm1'
if (Test-Path $ModulePath) {
    Import-Module $ModulePath -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "  (note: iDezign_Common.psm1 not found alongside script - using built-in functions)" -ForegroundColor DarkYellow
}

# Version check - confirm at the very start of the run that this is the latest
# copy (compares embedded version to iDezign_Versions.json manifest).
if (Get-Command Show-VersionCheck -ErrorAction SilentlyContinue) {
    Show-VersionCheck -ScriptName 'iDezign_Cleanup_Utility.ps1' `
                      -CurrentVersion $ScriptVersion `
                      -ScriptDir (Split-Path $ScriptPath -Parent)
}

#endregion

#region --- Self-stage to local disk -----------------------------------------

$StagingDir = 'C:\iDezign_Cleanup_Utility'
$StagedPath = Join-Path $StagingDir (Split-Path $ScriptPath -Leaf)
$StateFile  = Join-Path $StagingDir 'state.json'

if (Get-Command Invoke-iDezignSelfStage -ErrorAction SilentlyContinue) {
    # Preferred path: module helper checks file freshness, stages both script
    # AND module, and tells us whether to re-launch.
    $stageResult = Invoke-iDezignSelfStage `
        -ScriptPath $ScriptPath `
        -StagingDir $StagingDir `
        -ResumeAfterUpdate:$ResumeAfterUpdate

    if ($stageResult.Error) {
        Write-Host "ERROR staging script: $($stageResult.Error)" -ForegroundColor Red
        Pause
        exit 1
    }
    if ($stageResult.NeedsRestage) {
        Write-Host "Re-launching from local copy..." -ForegroundColor Cyan
        Write-Host ""
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy','Bypass',
            '-File', "`"$($stageResult.StagedPath)`""
        )
        exit 0
    }
} elseif (-not $ResumeAfterUpdate -and $ScriptPath -ne $StagedPath) {
    # Fallback path: module didn't load.  Use the simpler "always-stage" logic
    # without freshness checks.  Loses the auto-update feature but still works.
    Write-Host ""
    Write-Host "Launched from : $ScriptPath" -ForegroundColor DarkGray
    Write-Host "Staging to    : $StagedPath" -ForegroundColor Cyan
    Write-Host "(RunOnce resume after reboot needs the script on a local path.)" -ForegroundColor DarkGray
    Write-Host "(Module not loaded - using fallback staging.)" -ForegroundColor DarkYellow
    Write-Host ""

    try {
        if (-not (Test-Path $StagingDir)) {
            New-Item -Path $StagingDir -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path $ScriptPath -Destination $StagedPath -Force -ErrorAction Stop
    } catch {
        Write-Host "ERROR staging script: $($_.Exception.Message)" -ForegroundColor Red
        Pause
        exit 1
    }

    Write-Host "Re-launching from local copy..." -ForegroundColor Cyan
    Write-Host ""

    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy','Bypass',
        '-File', "`"$StagedPath`""
    )
    exit 0
}

#endregion

#region --- Helper: pending-reboot detection ---------------------------------
# Checks all the usual "this box wants a reboot" signals. Returns an array of
# short string descriptions of what's pending. Empty array = nothing pending.
#
# These are the same flags Microsoft uses internally to decide whether to gate
# CBS operations. Hitting DISM with any of these set is the #1 cause of
# 0x800f0806 "The operation could not be completed due to pending operations".

function Test-PendingReboot {
    $signals = @()

    # Component Based Servicing - set when an update is staged for next boot
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $signals += 'CBS RebootPending'
    }

    # Windows Update - explicit reboot-required flag
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $signals += 'WindowsUpdate RebootRequired'
    }

    # Files queued for rename/delete at next boot (set by installers, hotfixes)
    $sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($sm -and $sm.PendingFileRenameOperations) {
        $signals += 'PendingFileRenameOperations'
    }

    # The big one - if pending.xml exists, CBS has an in-flight transaction
    if (Test-Path 'C:\Windows\WinSxS\pending.xml') {
        $signals += 'pending.xml exists in WinSxS'
    }

    # Pending computer rename (active != target)
    try {
        $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction Stop).ComputerName
        $target = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'      -Name ComputerName -ErrorAction Stop).ComputerName
        if ($active -and $target -and ($active -ne $target)) {
            $signals += "Computer rename pending ($active -> $target)"
        }
    } catch { }

    return $signals
}

#endregion

#region --- Initial prompts + state ------------------------------------------

# --- Pre-flight checks: run BEFORE any work that depends on these conditions ---
# Order matters:
#   1. Disk space        - hard fail, fastest check
#   2. Network           - needed for NTP, downloads, Windows Update
#   3. System clock      - needed for TLS/cert validation, date defaults below
#   4. Activation status - informational only
#   5. BitLocker         - decision point: image capture won't work if enabled
# Pending Windows feature/reboot changes are handled separately in Phase 0b.
# Skip the entire block on resume - already checked, machine is mid-run.
if (-not $ResumeAfterUpdate) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  PRE-FLIGHT CHECKS" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    # 1. Disk space (HARD FAIL on insufficient space) ------------------------
    Write-Host ""
    Write-Host "[Pre-flight 1/5] Disk free space check..." -ForegroundColor Green
    if (Get-Command Test-iDezignDiskSpace -ErrorAction SilentlyContinue) {
        $disk = Test-iDezignDiskSpace -DriveLetter 'C' -MinFreeGB 10
        if (-not $disk.OK) {
            Write-Host ""
            Write-Host "ABORTED: insufficient free space on C:" -ForegroundColor Red
            Write-Host "Free up space and re-run. Suggestions:" -ForegroundColor Yellow
            Write-Host "  - Empty Recycle Bin" -ForegroundColor Yellow
            Write-Host "  - Settings -> System -> Storage -> Temporary files" -ForegroundColor Yellow
            Write-Host "  - Remove old user profiles" -ForegroundColor Yellow
            Write-Host "  - Run cleanmgr /sageset:99 then cleanmgr /sagerun:99" -ForegroundColor Yellow
            Pause
            exit 1
        }
    } else {
        Write-Host "  (Test-iDezignDiskSpace not available - skipping. Module may be out of date.)" -ForegroundColor DarkYellow
    }

    # 2. Network connectivity (WARN if no internet) --------------------------
    Write-Host ""
    Write-Host "[Pre-flight 2/5] Network connectivity check..." -ForegroundColor Green
    $netResult = $null
    if (Get-Command Test-iDezignNetwork -ErrorAction SilentlyContinue) {
        $netResult = Test-iDezignNetwork
        if (-not $netResult.OK) {
            Write-Host ""
            $answer = Read-Host "No internet detected. Most phases will fail. Continue anyway? (Y/N)"
            if ($answer -notmatch '^(y|yes)$') {
                Write-Host "Aborted." -ForegroundColor Yellow
                exit 1
            }
            Write-Host "  Continuing without internet - expect download/update failures." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  (Test-iDezignNetwork not available - skipping. Module may be out of date.)" -ForegroundColor DarkYellow
    }

    # 3. System clock sync (HARD WARN if year is wrong) ----------------------
    Write-Host ""
    Write-Host "[Pre-flight 3/5] System clock check..." -ForegroundColor Green
    if (Get-Command Sync-SystemTime -ErrorAction SilentlyContinue) {
        $clockOK = Sync-SystemTime
        if (-not $clockOK) {
            Write-Host ""
            $answer = Read-Host "Clock looks wrong. Continue anyway? Downloads and Windows Update may fail. (Y/N)"
            if ($answer -notmatch '^(y|yes)$') {
                Write-Host "Aborted. Fix the clock manually (Settings -> Time & language) and re-run." -ForegroundColor Yellow
                exit 1
            }
        }
    } else {
        Write-Host "  (Sync-SystemTime not available - skipping. Module may be out of date.)" -ForegroundColor DarkYellow
    }

    # 4. Activation status (informational ONLY - never blocks) ----------------
    Write-Host ""
    Write-Host "[Pre-flight 4/5] Windows activation status..." -ForegroundColor Green
    if (Get-Command Get-iDezignActivationStatus -ErrorAction SilentlyContinue) {
        $act = Get-iDezignActivationStatus
        # Just informational - if unactivated, log it but continue.
        # User probably knows; this is just for the record.
    } else {
        Write-Host "  (Get-iDezignActivationStatus not available - skipping.)" -ForegroundColor DarkYellow
    }

    # 4b. Windows version (informational) - shown right after activation -------
    Write-Host ""
    Write-Host "[Pre-flight] Windows version..." -ForegroundColor Green
    try {
        $osv = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $disp = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
        $verLabel = if ($disp) { "$($osv.Caption) $disp (build $($osv.BuildNumber))" }
                    else        { "$($osv.Caption) (build $($osv.BuildNumber))" }
        Write-Host "  $verLabel" -ForegroundColor Gray
    } catch {
        Write-Host "  (could not read Windows version: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }

    # 5. BitLocker status (DECISION POINT for image capture) -----------------
    Write-Host ""
    Write-Host "[Pre-flight 5/5] BitLocker status..." -ForegroundColor Green
    if (Get-Command Test-iDezignBitLocker -ErrorAction SilentlyContinue) {
        $bl = Test-iDezignBitLocker -DriveLetter 'C'
        if ($bl.IsEncrypted) {
            Write-Host ""
            Write-Host "WARNING: BitLocker is active on C:." -ForegroundColor Yellow
            Write-Host "  - If you plan to capture this as an image: SUSPEND or DISABLE BL first." -ForegroundColor Yellow
            Write-Host "    (manage-bde -off C: , or Settings -> System -> Device encryption)" -ForegroundColor Yellow
            Write-Host "  - If this is a deployed workstation, you can usually continue, but" -ForegroundColor Yellow
            Write-Host "    have the BL recovery key handy before the final reboot." -ForegroundColor Yellow
            Write-Host ""
            $answer = Read-Host "Continue with BitLocker enabled? (Y/N)"
            if ($answer -notmatch '^(y|yes)$') {
                Write-Host "Aborted. Suspend BitLocker and re-run." -ForegroundColor Yellow
                exit 1
            }
        }
    } else {
        Write-Host "  (Test-iDezignBitLocker not available - skipping.)" -ForegroundColor DarkYellow
    }

    Write-Host ""
    Write-Host "Pre-flight checks complete." -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

# Today's date in European format - regenerated every script launch.
# Now safe to use because the clock was sync'd above.
$today               = Get-Date -Format 'dd-MM-yy'
$DefaultComputerName = $today                 # e.g. "14-05-26"
$DefaultUserName     = "Clean $today"         # e.g. "Clean 14-05-26"

$CurrentUser = $env:USERNAME

if (-not $ResumeAfterUpdate) {

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  iDezign Cleanup Utility  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
    Write-Host "  Version: $ScriptVersion$(if(Get-Command Get-iDezignCommonVersion -EA SilentlyContinue){"  |  module: $(Get-iDezignCommonVersion)"})" -ForegroundColor DarkGray
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Current computer name : $env:COMPUTERNAME"
    Write-Host "  Current user account  : $CurrentUser"
    Write-Host ""
    Write-Host "  Phases:"
    Write-Host "    0. Windows Update loop  (may reboot 1-4 times automatically)"
    Write-Host "    1. Install + config     (Apps/Power/OpenShl/Net/Scan/Excl/OneDrive - optional)"
    Write-Host "    2. Cleanup              (temp, Windows.old, event logs, DISM, etc.)"
    Write-Host "    3. Ensure REPAIR admin account exists (always runs)"
    Write-Host "    4. Rename user account  (optional)"
    Write-Host "    5. Rename computer      (optional)"
    Write-Host "    6. Final reboot"
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -notmatch '^(y|yes)$') {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }

    # --- Install Chrome ---
    Write-Host ""
    $answer = Read-Host "Install Google Chrome? (Y/N)"
    $doInstallChrome    = $answer -match '^(y|yes)$'
    $doSetChromeDefault = $false
    if ($doInstallChrome) {
        $answer = Read-Host "  Also set Chrome as default browser for NEW user profiles? (Y/N)"
        $doSetChromeDefault = $answer -match '^(y|yes)$'
    }

    # --- Install Claude Desktop ---
    Write-Host ""
    $answer = Read-Host "Install Claude Desktop? (Y/N)"
    $doInstallClaude = $answer -match '^(y|yes)$'

    # --- Download (NOT install) Malwarebytes to Downloads folder ---
    # Stages the installer for the technician to run manually after imaging.
    # We don't install it during cleanup because:
    #  (a) MWB asks the user for a license/trial selection
    #  (b) Running fresh MWB on an offline pre-image box would update sigs anyway
    #  (c) Better to install it post-deploy when the box has its final identity
    Write-Host ""
    $answer = Read-Host "Download Malwarebytes installer to Downloads folder (no install)? (Y/N)"
    $doDownloadMWB = $answer -match '^(y|yes)$'

    # --- Install iDezign-branded TeamViewer Host ---
    # The custom-branded URL get.teamviewer.com/idezign serves an EXE that
    # already has Eric's account/branding baked in. /S = silent install.
    # We install (not just download) because TV needs to be running on every
    # imaged machine so Eric has remote access. Unlike MWB, no license prompt.
    Write-Host ""
    $answer = Read-Host "Install iDezign-branded TeamViewer Host (from get.teamviewer.com/idezign)? (Y/N)"
    $doInstallTV = $answer -match '^(y|yes)$'

    # --- Power settings ---
    # Default workstation/server tuning: never sleep, never spin down disk,
    # display off after 1 hour, hibernation disabled (reclaims hiberfil.sys).
    # Critical for Dentrix/SQL workstations - SQL Server is intolerant of
    # disks spinning down mid-transaction. Server OS gets this regardless of
    # laptop chassis (servers should never sleep). Laptops are auto-skipped
    # at apply time since users want battery-saving on portables.
    Write-Host ""
    $answer = Read-Host "Configure POWER settings (HDD never, display 1hr, no sleep/hibernate)? (Y/N)"
    $doConfigurePower = $answer -match '^(y|yes)$'

    # --- Install Open-Shell (classic Start Menu replacement) ---
    # Open-Shell brings back a Windows 7-style Start Menu - useful for older
    # users who never adjusted to the Win11 redesign. We use the Ninite
    # installer at ninite.com/openshell because Ninite installers run silently
    # by default (no flags needed) and are always up-to-date. Alternative
    # source: GitHub releases (Open-Shell/Open-Shell-Menu) if Ninite is down.
    Write-Host ""
    $answer = Read-Host "Install Open-Shell (classic Start Menu via Ninite)? (Y/N)"
    $doInstallOpenShell = $answer -match '^(y|yes)$'
    $doApplyOpenShellDefaults = $false
    if ($doInstallOpenShell) {
        # Apply iDezign baseline Open-Shell settings (Win7-style menu, Aero skin)
        # via registry. Writes to .DEFAULT hive (affects new user profiles) and
        # HKCU (for current user verification). Existing users keep their settings.
        $answer = Read-Host "  Apply iDezign default settings (Win7-style menu)? (Y/N)"
        $doApplyOpenShellDefaults = $answer -match '^(y|yes)$'
    }

    # --- Set network profile to Private + enable sharing/discovery ---
    # Fresh installs default networks to Public, which blocks SMB/file sharing,
    # network discovery, RDP inbound, and Dentrix multi-workstation features.
    # Setting Private enables all of that. We ALSO enable File/Print Sharing
    # and Network Discovery firewall rules for the Private profile, otherwise
    # just flipping the category isn't enough - the firewall still blocks.
    # Domain-joined networks are skipped automatically (their category is set
    # by AD, not us).
    Write-Host ""
    $answer = Read-Host "Set network profiles to PRIVATE + enable file sharing/discovery? (Y/N)"
    $doSetNetworkPrivate = $answer -match '^(y|yes)$'

    # --- Microsoft Defender scan ---
    # Three options:
    #   Q = Quick scan (3-5 min) - checks active malware locations only
    #   F = Full scan (30 min - 4 hours) - every file, including archives
    #   S = Skip   (or just press Enter)
    # Quick is usually fine for fresh-image prep where the disk is empty.
    # Full is for hand-me-down workstations where you don't know the history.
    # Default is Skip - hit Enter to bypass when iterating on other phases.
    Write-Host ""
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

    # --- Defender exclusions for Dentrix/SQL ---
    # Dental practice workstations run Dentrix which uses SQL Server. Defender
    # scanning the live SQL database files (.mdf/.ldf) during transactions
    # slows everything to a crawl and occasionally corrupts the DB. Microsoft's
    # documented best practice is to exclude SQL data directories from real-time
    # scanning. We add the standard Dentrix paths + SQL Server paths + the SQL
    # service processes. Exclusions are added even if Dentrix isn't installed
    # yet - they'll activate when it gets installed later (e.g. post-imaging).
    Write-Host ""
    $answer = Read-Host "Add Defender exclusions for Dentrix/SQL paths (dental workstations)? (Y/N)"
    $doDentrixExclusions = $answer -match '^(y|yes)$'

    # --- Strip Microsoft consumer integrations (OneDrive nuke + related) ---
    # Aggressive removal of consumer-grade Microsoft integrations that cause
    # support headaches on dental practice workstations:
    #   * OneDrive: uninstall + block reinstall + un-redirect Documents/Desktop/Pictures
    #   * Teams personal version (chat icon next to Start in Win11)
    #   * "Get more out of Windows" suggestions/nags
    #   * Windows Backup nag (just OneDrive sync rebranded)
    # User can pick which parts to do. OneDrive is the main event; others are
    # sub-opt-ins if they pick OneDrive YES.
    Write-Host ""
    $answer = Read-Host "Nuke OneDrive entirely (uninstall + block reinstall + restore Documents/Desktop)? (Y/N)"
    $doNukeOneDrive = $answer -match '^(y|yes)$'
    $doStripTeamsPersonal = $false
    $doStripMSnags        = $false
    if ($doNukeOneDrive) {
        $answer = Read-Host "  Also remove Teams personal version chat icon? (Y/N)"
        $doStripTeamsPersonal = $answer -match '^(y|yes)$'
        $answer = Read-Host "  Also disable 'Get more out of Windows' nags + Windows Backup prompts? (Y/N)"
        $doStripMSnags = $answer -match '^(y|yes)$'
    }

    # --- Computer rename ---
    Write-Host ""
    $answer = Read-Host "Rename this COMPUTER? (Y/N)"
    $doRenameComputer = $answer -match '^(y|yes)$'
    $newComputerName  = ''
    if ($doRenameComputer) {
        $typed = Read-Host "  New computer name [Enter = '$DefaultComputerName']"
        if ([string]::IsNullOrWhiteSpace($typed)) { $newComputerName = $DefaultComputerName }
        else                                      { $newComputerName = $typed.Trim() }
    }

    # --- User rename ---
    Write-Host ""
    $answer = Read-Host "Rename current USER ACCOUNT '$CurrentUser'? (Y/N)"
    $doRenameUser = $answer -match '^(y|yes)$'
    $newUserName  = ''
    if ($doRenameUser) {
        $typed = Read-Host "  New user name [Enter = '$DefaultUserName']"
        if ([string]::IsNullOrWhiteSpace($typed)) { $newUserName = $DefaultUserName }
        else                                      { $newUserName = $typed.Trim() }
    }

    # --- Persist state ---
    # PendingRebootRetries tracks how many "extra" reboots we've done after the
    # main update loop just to clear pending operations. Capped to prevent
    # infinite loops on a wedged machine.
    $state = [PSCustomObject]@{
        DoInstallChrome          = [bool]$doInstallChrome
        DoSetChromeDefault       = [bool]$doSetChromeDefault
        DoInstallClaude          = [bool]$doInstallClaude
        DoDownloadMWB            = [bool]$doDownloadMWB
        DoInstallTV              = [bool]$doInstallTV
        DoConfigurePower         = [bool]$doConfigurePower
        DoInstallOpenShell       = [bool]$doInstallOpenShell
        DoApplyOpenShellDefaults = [bool]$doApplyOpenShellDefaults
        DoSetNetworkPrivate      = [bool]$doSetNetworkPrivate
        ScanType                 = [string]$scanType
        DoDentrixExclusions      = [bool]$doDentrixExclusions
        DoNukeOneDrive           = [bool]$doNukeOneDrive
        DoStripTeamsPersonal     = [bool]$doStripTeamsPersonal
        DoStripMSnags            = [bool]$doStripMSnags
        DoRenameComputer         = [bool]$doRenameComputer
        NewComputerName          = $newComputerName
        DoRenameUser             = [bool]$doRenameUser
        NewUserName              = $newUserName
        OriginalUser             = $CurrentUser
        PendingRebootRetries     = 0
        Created                  = (Get-Date -Format 'o')
    }
    $state | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8

    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    $chromeSummary = if ($doInstallChrome) {
        if ($doSetChromeDefault) { 'YES (+ set default)' } else { 'YES' }
    } else { 'NO' }
    $openShellSummary = if ($doInstallOpenShell) {
        if ($doApplyOpenShellDefaults) { 'YES (+ iDezign defaults)' } else { 'YES (default config)' }
    } else { 'NO' }
    $scanSummary = switch ($scanType) {
        'Quick' { 'YES - Quick scan (3-5 min)' }
        'Full'  { 'YES - Full scan (30min-4hr)' }
        default { 'NO' }
    }
    Write-Host ("  Install Chrome  : " + $chromeSummary)
    Write-Host ("  Install Claude  : " + ($(if($doInstallClaude){'YES'}else{'NO'})))
    Write-Host ("  Install TV Host : " + ($(if($doInstallTV){'YES (iDezign branded)'}else{'NO'})))
    Write-Host ("  Download MWB    : " + ($(if($doDownloadMWB){'YES (to ~\Downloads)'}else{'NO'})))
    Write-Host ("  Install OpenShl : " + $openShellSummary)
    Write-Host ("  Power settings  : " + ($(if($doConfigurePower){'YES (HDD never / display 1hr / no sleep/hibernate)'}else{'NO'})))
    Write-Host ("  Net + Sharing   : " + ($(if($doSetNetworkPrivate){'YES (Private + File/Print + Discovery)'}else{'NO'})))
    Write-Host ("  Defender scan   : " + $scanSummary)
    Write-Host ("  Dentrix excl.   : " + ($(if($doDentrixExclusions){'YES (Dentrix + SQL paths)'}else{'NO'})))
    # OneDrive nuke summary with sub-option indicators
    $odSummary = if ($doNukeOneDrive) {
        $extras = @()
        if ($doStripTeamsPersonal) { $extras += 'Teams' }
        if ($doStripMSnags)        { $extras += 'nags' }
        if ($extras.Count -gt 0)   { "YES (+ $($extras -join '/'))" } else { 'YES' }
    } else { 'NO' }
    Write-Host ("  Nuke OneDrive   : " + $odSummary)
    Write-Host ("  REPAIR account  : ENSURE EXISTS (always)")
    Write-Host ("  Rename computer : " + ($(if($doRenameComputer){"YES -> $newComputerName"}else{'NO'})))
    Write-Host ("  Rename user     : " + ($(if($doRenameUser){"YES -> $newUserName"}else{'NO'})))
    Write-Host ""
    Start-Sleep -Seconds 2

} else {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  iDezign Cleanup Utility - resuming after update reboot" -ForegroundColor Cyan
    Write-Host "  Version: $ScriptVersion$(if(Get-Command Get-iDezignCommonVersion -EA SilentlyContinue){"  |  module: $(Get-iDezignCommonVersion)"})" -ForegroundColor DarkGray
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Start-Sleep -Seconds 5

    if (Test-Path $StateFile) {
        try {
            $state = Get-Content -Path $StateFile -Raw | ConvertFrom-Json
            $doInstallChrome    = [bool]$state.DoInstallChrome
            $doSetChromeDefault = [bool]$state.DoSetChromeDefault
            $doInstallClaude    = [bool]$state.DoInstallClaude
            $doDownloadMWB      = [bool]$state.DoDownloadMWB
            $doInstallTV        = [bool]$state.DoInstallTV
            $doConfigurePower   = [bool]$state.DoConfigurePower
            $doInstallOpenShell = [bool]$state.DoInstallOpenShell
            $doApplyOpenShellDefaults = [bool]$state.DoApplyOpenShellDefaults
            $doSetNetworkPrivate = [bool]$state.DoSetNetworkPrivate
            # ScanType is the new field. Fall back to DoFullScan for older state files.
            if ($null -ne $state.ScanType -and $state.ScanType -ne '') {
                $scanType = [string]$state.ScanType
            } elseif ($state.DoFullScan) {
                $scanType = 'Full'   # old state file with the bool field
            } else {
                $scanType = 'None'
            }
            $doDentrixExclusions = [bool]$state.DoDentrixExclusions
            $doNukeOneDrive       = [bool]$state.DoNukeOneDrive
            $doStripTeamsPersonal = [bool]$state.DoStripTeamsPersonal
            $doStripMSnags        = [bool]$state.DoStripMSnags
            $doRenameComputer   = [bool]$state.DoRenameComputer
            $newComputerName    = [string]$state.NewComputerName
            $doRenameUser       = [bool]$state.DoRenameUser
            $newUserName        = [string]$state.NewUserName

            # Handle older state files that don't have these fields yet.
            # Each Add-Member is idempotent if the field already exists with -Force.
            if ($null -eq $state.PendingRebootRetries) {
                $state | Add-Member -NotePropertyName 'PendingRebootRetries' -NotePropertyValue 0 -Force
            }
            if ($null -eq $state.DoDownloadMWB) {
                $state | Add-Member -NotePropertyName 'DoDownloadMWB' -NotePropertyValue $false -Force
            }
            if ($null -eq $state.DoInstallTV) {
                $state | Add-Member -NotePropertyName 'DoInstallTV' -NotePropertyValue $false -Force
            }
            if ($null -eq $state.DoConfigurePower) {
                $state | Add-Member -NotePropertyName 'DoConfigurePower' -NotePropertyValue $false -Force
            }
            if ($null -eq $state.DoInstallOpenShell) {
                $state | Add-Member -NotePropertyName 'DoInstallOpenShell' -NotePropertyValue $false -Force
            }
            if ($null -eq $state.DoApplyOpenShellDefaults) {
                $state | Add-Member -NotePropertyName 'DoApplyOpenShellDefaults' -NotePropertyValue $false -Force
            }
            if ($null -eq $state.DoSetNetworkPrivate) {
                $state | Add-Member -NotePropertyName 'DoSetNetworkPrivate' -NotePropertyValue $false -Force
            }
            if ($null -eq $state.ScanType) {
                $state | Add-Member -NotePropertyName 'ScanType' -NotePropertyValue $scanType -Force
            }
            if ($null -eq $state.DoDentrixExclusions) {
                $state | Add-Member -NotePropertyName 'DoDentrixExclusions' -NotePropertyValue $false -Force
            }
            if ($null -eq $state.DoNukeOneDrive) {
                $state | Add-Member -NotePropertyName 'DoNukeOneDrive' -NotePropertyValue $false -Force
            }
            if ($null -eq $state.DoStripTeamsPersonal) {
                $state | Add-Member -NotePropertyName 'DoStripTeamsPersonal' -NotePropertyValue $false -Force
            }
            if ($null -eq $state.DoStripMSnags) {
                $state | Add-Member -NotePropertyName 'DoStripMSnags' -NotePropertyValue $false -Force
            }

            Write-Host "Loaded saved state from $StateFile." -ForegroundColor DarkGray
        } catch {
            Write-Host "WARNING: could not parse $StateFile - optional phases will be skipped." -ForegroundColor Yellow
            $doInstallChrome = $false; $doSetChromeDefault = $false
            $doInstallClaude = $false; $doDownloadMWB = $false; $doInstallTV = $false
            $doConfigurePower = $false
            $doInstallOpenShell = $false; $doApplyOpenShellDefaults = $false
            $doSetNetworkPrivate = $false; $scanType = 'None'; $doDentrixExclusions = $false
            $doNukeOneDrive = $false; $doStripTeamsPersonal = $false; $doStripMSnags = $false
            $doRenameComputer = $false; $doRenameUser = $false
        }
    } else {
        Write-Host "WARNING: state file not found - optional phases will be skipped." -ForegroundColor Yellow
        $doInstallChrome = $false; $doSetChromeDefault = $false
        $doInstallClaude = $false; $doDownloadMWB = $false; $doInstallTV = $false
        $doConfigurePower = $false
        $doInstallOpenShell = $false; $doApplyOpenShellDefaults = $false
        $doSetNetworkPrivate = $false; $scanType = 'None'; $doDentrixExclusions = $false
        $doNukeOneDrive = $false; $doStripTeamsPersonal = $false; $doStripMSnags = $false
        $doRenameComputer = $false; $doRenameUser = $false
    }
}

# Helper to write current $state back to disk after any field change
function Save-State {
    if ($script:state) {
        $script:state | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding UTF8
    }
}

#endregion

#region --- Server detection -------------------------------------------------
# Detect Windows Server SKU and set behavior flags used throughout the rest
# of the script. The big yellow warning runs before any destructive action.

$ServerInfo = $null
if (Get-Command Get-ServerOSDetails -ErrorAction SilentlyContinue) {
    $ServerInfo = Get-ServerOSDetails
} else {
    # Module not loaded - quick local fallback
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

if ($IsServer) {
    $disabledOnServer = @(
        'Claude Desktop install (MSIX not supported on Server)',
        'Event log clearing (preserves audit trail - HIPAA/security)',
        'VSS shadow copy deletion (preserves Veeam/WSB backups)',
        'DISM /resetbase (preserves update rollback capability)',
        'cleanmgr.exe (not installed on Server SKUs)'
    )
    $gatedOnServer = @(
        'Computer rename (requires CONFIRM if domain-joined)',
        'REPAIR local account creation (asked Y/N, default NO)'
    )
    if ($IsDC) {
        $disabledOnServer += 'REPAIR local account (DCs have no local accounts)'
        $disabledOnServer += 'User rename (DCs use domain accounts)'
    }

    if (Get-Command Show-ServerWarning -ErrorAction SilentlyContinue) {
        Show-ServerWarning -ServerInfo $ServerInfo -ToolName 'Cleanup Utility' `
                           -Disabled $disabledOnServer -Gated $gatedOnServer
    } else {
        Write-Host "" -ForegroundColor Yellow
        Write-Host "  *** WINDOWS SERVER DETECTED - server-safe mode active ***" -ForegroundColor Yellow
        Write-Host ""
    }
}

#endregion

#region --- Start transcript -------------------------------------------------
# Captures everything written to host (including auto-resume sessions after
# update reboots) to a transcript file in the staging dir. Each invocation -
# including post-reboot resumes - gets its own timestamped log.
# Using the module helper if available, otherwise falls back to direct call.

if (Get-Command Start-iDezignTranscript -ErrorAction SilentlyContinue) {
    $transcriptPath = Start-iDezignTranscript -Directory $StagingDir -Prefix 'cleanup_transcript'
    if ($transcriptPath) {
        Write-Host "Transcript logging to: $transcriptPath" -ForegroundColor DarkGray
    }
} else {
    # Fallback if module is missing
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $transcriptPath = Join-Path $StagingDir "cleanup_transcript_$stamp.log"
    try {
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
        Start-Transcript -Path $transcriptPath -Force -ErrorAction Stop | Out-Null
        Write-Host "Transcript logging to: $transcriptPath" -ForegroundColor DarkGray
    } catch {
        Write-Host "(could not start transcript: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

#endregion

#region --- 0. Windows Update loop -------------------------------------------

Write-Host "`n[Phase 0] Windows Update loop..." -ForegroundColor Green

$needModule = -not (Get-Module -ListAvailable -Name PSWindowsUpdate)
if ($needModule) {
    Write-Host "  Installing PSWindowsUpdate module from PSGallery..." -ForegroundColor DarkGray
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction SilentlyContinue -Verbose:$false | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module -Name PSWindowsUpdate -Force -SkipPublisherCheck -Scope AllUsers -ErrorAction Stop -Verbose:$false
        Write-Host "  PSWindowsUpdate installed." -ForegroundColor DarkGray
    } catch {
        Write-Host "  ERROR installing PSWindowsUpdate: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Skipping update phase. Run Windows Update manually then re-run this script." -ForegroundColor Yellow
        $skipUpdates = $true
    }
}

Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue -Verbose:$false

$RunOnceKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$RunOnceName = 'iDezign_Cleanup_Resume'

function Set-ResumeRunOnce {
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -ResumeAfterUpdate"
    New-ItemProperty -Path $RunOnceKey -Name $RunOnceName -Value $cmd -PropertyType String -Force | Out-Null
    Write-Host "  RunOnce registered - script will resume after next login." -ForegroundColor DarkGray
}

function Clear-ResumeRunOnce {
    if (Get-ItemProperty -Path $RunOnceKey -Name $RunOnceName -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceName -ErrorAction SilentlyContinue
        Write-Host "  RunOnce cleared." -ForegroundColor DarkGray
    }
}

if (-not $skipUpdates) {

    $maxPasses = 6
    $pass      = 0

    do {
        $pass++
        Write-Host "`n  Update pass #$pass - scanning for available updates..." -ForegroundColor Cyan

        try {
            $updates = Get-WindowsUpdate -MicrosoftUpdate -ErrorAction Stop
        } catch {
            Write-Host "  Get-WindowsUpdate failed: $($_.Exception.Message)" -ForegroundColor Red
            $updates = @()
        }

        if (-not $updates -or $updates.Count -eq 0) {
            Write-Host "  No pending updates. Update phase complete." -ForegroundColor Green
            break
        }

        Write-Host "  Found $($updates.Count) update(s):" -ForegroundColor Cyan
        $updates | ForEach-Object {
            $sizeMB = if ($_.Size) { " ($([math]::Round($_.Size/1MB,0)) MB)" } else { '' }
            Write-Host "    - $($_.Title)$sizeMB" -ForegroundColor DarkGray
        }
        Write-Host ""

        # --- Install with LIVE progress ---------------------------------------
        # Previous versions ran the install inside a background job piped to
        # Out-Null, giving zero feedback for up to 60 minutes - looked frozen.
        #
        # New approach: run Install-WindowsUpdate in a background job that writes
        # per-update status to a temp progress file. The main thread tails that
        # file every few seconds, so the tech sees real-time download/install
        # progress AND an elapsed-time heartbeat. Still bounded by a 60-min
        # timeout so a wedged download can't hang forever.
        $progressFile = Join-Path $env:TEMP "idz_wu_progress_$pass.txt"
        if (Test-Path $progressFile) { Remove-Item $progressFile -Force -ErrorAction SilentlyContinue }

        $installJob = Start-Job -Name "idz_wu_$pass" -ScriptBlock {
            param($ProgressFile)
            Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue -Verbose:$false
            try {
                # Stream each update result object as it completes. PSWindowsUpdate
                # emits one object per update as it moves through Download/Install,
                # so piping to ForEach lets us log each status transition live.
                Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Confirm:$false -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $line = "{0} | {1} | {2}" -f $_.Status, $_.KB, $_.Title
                        Add-Content -Path $ProgressFile -Value $line -ErrorAction SilentlyContinue
                    }
                Add-Content -Path $ProgressFile -Value "__DONE__" -ErrorAction SilentlyContinue
            } catch {
                Add-Content -Path $ProgressFile -Value "__ERROR__ $($_.Exception.Message)" -ErrorAction SilentlyContinue
            }
        } -ArgumentList $progressFile

        # Poll the job + progress file, showing live feedback.
        $installStart   = Get-Date
        $timeoutMin     = 60
        $lastLineCount  = 0
        $lastHeartbeat  = Get-Date
        $installTimedOut = $false
        $installError    = $null

        Write-Host "  Installing updates (live progress below)..." -ForegroundColor Cyan
        Write-Host "  This can take a while for large cumulative updates - that's normal." -ForegroundColor DarkGray

        while ($installJob.State -eq 'Running') {
            Start-Sleep -Seconds 3

            # Tail any new lines from the progress file
            if (Test-Path $progressFile) {
                $allLines = @(Get-Content $progressFile -ErrorAction SilentlyContinue)
                if ($allLines.Count -gt $lastLineCount) {
                    $newLines = $allLines[$lastLineCount..($allLines.Count - 1)]
                    foreach ($l in $newLines) {
                        if ($l -eq '__DONE__') { continue }
                        if ($l -like '__ERROR__*') { $installError = $l -replace '__ERROR__ ',''; continue }
                        # Color the status word: Installed=green, Downloaded=cyan, Failed=red
                        $parts = $l -split ' \| ', 3
                        $status = $parts[0]
                        $color = switch -Wildcard ($status) {
                            'Installed*'  { 'Green' }
                            'Downloaded*' { 'Cyan' }
                            'Failed*'     { 'Red' }
                            default       { 'DarkGray' }
                        }
                        Write-Host "    [$status] $($parts[2])" -ForegroundColor $color
                    }
                    $lastLineCount = $allLines.Count
                    $lastHeartbeat = Get-Date
                }
            }

            # Heartbeat every 30s if no new progress lines, so it never looks hung
            $elapsed = (Get-Date) - $installStart
            if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge 30) {
                $elapsedStr = '{0:mm\:ss}' -f $elapsed
                Write-Host "    ...still working (elapsed $elapsedStr) - downloading/installing in background" -ForegroundColor DarkGray
                $lastHeartbeat = Get-Date
            }

            # Timeout guard
            if ($elapsed.TotalMinutes -ge $timeoutMin) {
                $installTimedOut = $true
                Write-Host "  WARNING: Install exceeded $timeoutMin min - stopping this pass." -ForegroundColor Red
                Stop-Job  -Job $installJob -ErrorAction SilentlyContinue
                break
            }
        }

        # Drain any final lines + clean up the job
        if (-not $installTimedOut -and (Test-Path $progressFile)) {
            $allLines = @(Get-Content $progressFile -ErrorAction SilentlyContinue)
            if ($allLines.Count -gt $lastLineCount) {
                $newLines = $allLines[$lastLineCount..($allLines.Count - 1)]
                foreach ($l in $newLines) {
                    if ($l -eq '__DONE__' -or $l -like '__ERROR__*') {
                        if ($l -like '__ERROR__*') { $installError = $l -replace '__ERROR__ ','' }
                        continue
                    }
                    $parts = $l -split ' \| ', 3
                    Write-Host "    [$($parts[0])] $($parts[2])" -ForegroundColor DarkGray
                }
            }
        }
        Remove-Job -Job $installJob -Force -ErrorAction SilentlyContinue
        if (Test-Path $progressFile) { Remove-Item $progressFile -Force -ErrorAction SilentlyContinue }

        $totalElapsed = '{0:mm\:ss}' -f ((Get-Date) - $installStart)
        if ($installTimedOut) {
            Write-Host "  Install pass timed out after $totalElapsed. Skipping remaining passes." -ForegroundColor Red
            break
        } elseif ($installError) {
            Write-Host "  Install pass finished with errors after $totalElapsed : $installError" -ForegroundColor Yellow
        } else {
            Write-Host "  Install pass complete in $totalElapsed." -ForegroundColor Green
        }

        $needsReboot = $false
        try { $needsReboot = (Get-WURebootStatus -Silent) } catch { $needsReboot = $false }

        if ($needsReboot) {
            Write-Host "`n  Reboot required to continue Windows Update loop." -ForegroundColor Yellow
            Set-ResumeRunOnce  # RunOnce is registered EITHER way - so script resumes whenever reboot happens

            $rebooted = $false
            if (Get-Command Invoke-RebootChoice -ErrorAction SilentlyContinue) {
                $rebooted = Invoke-RebootChoice `
                    -Reason "Windows Update pass $pass complete; continuing after reboot" `
                    -CountdownSeconds 30 `
                    -DeferMessage "Script will auto-resume when you reboot manually (RunOnce is set)."
            } else {
                # Module not loaded - fall back to old auto-reboot behavior
                Write-Host "  Rebooting in 30 seconds. Log back in to auto-resume." -ForegroundColor Yellow
                shutdown /r /t 30 /c "Windows Update pass $pass complete. Rebooting to continue."
                $rebooted = $true
            }

            if (-not $rebooted) {
                Write-Host "  Cleanup paused. Reboot manually whenever you're ready - the script" -ForegroundColor Yellow
                Write-Host "  will continue automatically on your next login." -ForegroundColor Yellow
            }
            exit 0
        } else {
            Write-Host "  No reboot needed - looping to check for more updates." -ForegroundColor DarkGray
        }

    } while ($pass -lt $maxPasses)

    if ($pass -ge $maxPasses) {
        Write-Host "  Hit max pass limit ($maxPasses). Continuing anyway - check Windows Update manually after imaging." -ForegroundColor Yellow
    }
}

#endregion

#region --- 0b. Post-update pending-reboot check -----------------------------
# Even after Get-WURebootStatus says "no reboot needed", cumulative updates
# sometimes leave pending CBS operations behind. If we hit DISM /resetbase
# in Phase 2 while those are pending, we get error 0x800f0806. So: check
# explicitly, reboot once if anything is pending, then come back and continue.

Write-Host "`n[Phase 0b] Checking for pending operations before cleanup..." -ForegroundColor Green

$pendingSignals = Test-PendingReboot

if ($pendingSignals.Count -gt 0) {
    Write-Host "  Pending operations detected:" -ForegroundColor Yellow
    $pendingSignals | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkYellow }

    $retries = 0
    if ($state -and ($null -ne $state.PendingRebootRetries)) {
        $retries = [int]$state.PendingRebootRetries
    }

    if ($retries -lt 2) {
        $newCount = $retries + 1
        Write-Host "  Reboot needed to clear pending operations (extra reboot $newCount of 2)..." -ForegroundColor Yellow

        # Bump retry counter and save before reboot
        $state.PendingRebootRetries = $newCount
        Save-State

        Set-ResumeRunOnce

        $rebooted = $false
        if (Get-Command Invoke-RebootChoice -ErrorAction SilentlyContinue) {
            $rebooted = Invoke-RebootChoice `
                -Reason "Pending Windows operations need to clear before DISM cleanup" `
                -CountdownSeconds 30 `
                -DeferMessage "Script will auto-resume when you reboot manually (RunOnce is set)."
        } else {
            Write-Host "  Rebooting in 30 seconds. Log back in to auto-resume." -ForegroundColor Yellow
            shutdown /r /t 30 /c "Clearing pending operations before cleanup phase."
            $rebooted = $true
        }

        if (-not $rebooted) {
            Write-Host "  Cleanup paused. Reboot manually when ready - script resumes on next login." -ForegroundColor Yellow
        }
        exit 0
    } else {
        Write-Host "  Already retried $retries times - continuing without resetbase." -ForegroundColor Red
        Write-Host "  DISM /resetbase will be skipped to avoid 0x800f0806." -ForegroundColor DarkYellow
        # Flag this in state so Phase 2 knows to take it easy on DISM
        if ($null -eq $state.SkipResetBase) {
            $state | Add-Member -NotePropertyName 'SkipResetBase' -NotePropertyValue $true -Force
        } else {
            $state.SkipResetBase = $true
        }
        Save-State
    }
} else {
    Write-Host "  No pending operations - safe to proceed with cleanup." -ForegroundColor DarkGray
}

# We're past the update loop entirely now - no more auto-resumes needed.
Clear-ResumeRunOnce

#endregion

#region --- 1. Install software (optional) -----------------------------------

$OriginalProgressPref = $ProgressPreference

function Get-RemoteFile {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $OutFile,
        [string] $DisplayName = 'file'
    )
    Write-Host "  Downloading $DisplayName..." -ForegroundColor DarkGray
    Write-Host "    from: $Url" -ForegroundColor DarkGray
    Write-Host "    to  : $OutFile" -ForegroundColor DarkGray

    $script:ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
        $sizeMB = [math]::Round((Get-Item $OutFile).Length / 1MB, 1)
        Write-Host "  Downloaded ${DisplayName}: $sizeMB MB" -ForegroundColor DarkGray
        return $true
    } catch {
        Write-Host "  ERROR downloading $DisplayName : $($_.Exception.Message)" -ForegroundColor Red
        return $false
    } finally {
        $script:ProgressPreference = $OriginalProgressPref
    }
}

# --- 1a. Google Chrome ---
if ($doInstallChrome) {
    Write-Host "`n[Phase 1a] Installing Google Chrome..." -ForegroundColor Green
    $chromeUrl = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
    $chromeMsi = Join-Path $StagingDir 'chrome_enterprise64.msi'

    if (Get-RemoteFile -Url $chromeUrl -OutFile $chromeMsi -DisplayName 'Chrome Enterprise MSI') {
        # 10-min cap - if msiexec hangs (network, MSI lock, etc.) we move on.
        $exit = $null
        if (Get-Command Start-ProcessWithTimeout -ErrorAction SilentlyContinue) {
            $exit = Start-ProcessWithTimeout -FilePath 'msiexec.exe' `
                       -ArgumentList @("/i `"$chromeMsi`"", '/qn', '/norestart') `
                       -TimeoutMinutes 10 -Label 'Chrome MSI installer'
        } else {
            try {
                $p = Start-Process -FilePath 'msiexec.exe' `
                    -ArgumentList "/i `"$chromeMsi`" /qn /norestart" `
                    -Wait -PassThru
                $exit = $p.ExitCode
            } catch {
                Write-Host "  ERROR running Chrome installer: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        if ($exit -eq 0) {
            Write-Host "  Chrome installed successfully." -ForegroundColor DarkGray
        } elseif ($exit -eq -1) {
            Write-Host "  Chrome install TIMED OUT (>10 min) - manual install may be needed." -ForegroundColor Red
        } elseif ($null -ne $exit) {
            Write-Host "  Chrome installer returned exit code $exit." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "`n[Phase 1a] Chrome install: SKIPPED." -ForegroundColor DarkGray
}

# --- 1b. Set Chrome as default for new users (DISM Default App Associations) ---
if ($doSetChromeDefault) {
    Write-Host "`n[Phase 1b] Setting Chrome as default for NEW user profiles..." -ForegroundColor Green

    $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<DefaultAssociations>
  <Association Identifier=".htm"   ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier=".html"  ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier=".shtml" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier=".xht"   ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier=".xhtml" ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier=".webp"  ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier="http"   ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier="https"  ProgId="ChromeHTML" ApplicationName="Google Chrome" />
  <Association Identifier="ftp"    ProgId="ChromeHTML" ApplicationName="Google Chrome" />
</DefaultAssociations>
'@

    $xmlPath = Join-Path $StagingDir 'DefaultAssociations.xml'
    try {
        $xml | Set-Content -Path $xmlPath -Encoding UTF8 -ErrorAction Stop
        & dism.exe /Online /Import-DefaultAppAssociations:"$xmlPath" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  DISM import OK - new user profiles will get Chrome as default." -ForegroundColor DarkGray
            Write-Host "  NOTE: existing profiles (incl. this account) unchanged - by design." -ForegroundColor DarkYellow
        } else {
            Write-Host "  DISM returned exit code $LASTEXITCODE. Check that Chrome was actually installed." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  ERROR setting default associations: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "`n[Phase 1b] Chrome default browser: SKIPPED." -ForegroundColor DarkGray
}

# --- 1c. Claude Desktop ---
if ($doInstallClaude -and $IsServer) {
    Write-Host "`n[Phase 1c] Claude Desktop install: SKIPPED on Windows Server." -ForegroundColor Yellow
    Write-Host "  Claude Desktop is an MSIX package that requires UWP runtime" -ForegroundColor DarkGray
    Write-Host "  components not present on Windows Server SKUs." -ForegroundColor DarkGray
} elseif ($doInstallClaude) {
    Write-Host "`n[Phase 1c] Installing Claude Desktop..." -ForegroundColor Green

    Write-Host "  Enabling VirtualMachinePlatform feature (needed for Cowork)..." -ForegroundColor DarkGray
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Host "  (non-fatal) Could not enable VirtualMachinePlatform: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    $claudeUrl  = 'https://claude.ai/api/desktop/win32/x64/msix/latest/redirect'
    $claudeMsix = Join-Path $StagingDir 'Claude.msix'

    if (Get-RemoteFile -Url $claudeUrl -OutFile $claudeMsix -DisplayName 'Claude Desktop MSIX (x64)') {
        try {
            Add-AppxProvisionedPackage -Online -PackagePath $claudeMsix -SkipLicense -Regions 'all' -ErrorAction Stop | Out-Null
            Write-Host "  Claude Desktop installed (machine-wide provisioning)." -ForegroundColor DarkGray
        } catch {
            Write-Host "  ERROR installing Claude Desktop: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  You can install manually post-image with:" -ForegroundColor Yellow
            Write-Host "    Add-AppxProvisionedPackage -Online -PackagePath `"$claudeMsix`" -SkipLicense -Regions all" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "`n[Phase 1c] Claude Desktop install: SKIPPED." -ForegroundColor DarkGray
}

# --- 1d. Malwarebytes installer download (NO install) ---
# Stages the latest MWB installer in the user's Downloads folder so the
# technician can run it manually after deployment. Intentionally NOT
# installed during cleanup - see prompt-time comment for rationale.
if ($doDownloadMWB) {
    Write-Host "`n[Phase 1d] Downloading Malwarebytes installer to Downloads..." -ForegroundColor Green

    # Resolve user's Downloads folder properly (handles redirected/OneDrive Downloads)
    $downloadsDir = $null
    try {
        # The official KNOWNFOLDERID-based lookup
        $downloadsDir = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
    } catch { }
    if (-not $downloadsDir -or -not (Test-Path $downloadsDir)) {
        $downloadsDir = Join-Path $env:USERPROFILE 'Downloads'
        if (-not (Test-Path $downloadsDir)) {
            New-Item -Path $downloadsDir -ItemType Directory -Force | Out-Null
        }
    }

    # Official latest-installer URL (Malwarebytes maintains this redirect)
    $mwbUrl  = 'https://downloads.malwarebytes.com/file/mb-windows'
    $mwbFile = Join-Path $downloadsDir 'MBSetup.exe'

    Write-Host "  Destination: $mwbFile" -ForegroundColor DarkGray

    # Use the timeout-aware downloader if available, with a 10-min cap.
    $downloaded = $false
    if (Get-Command Invoke-WithJobTimeout -ErrorAction SilentlyContinue) {
        $job = Invoke-WithJobTimeout -TimeoutMinutes 10 -Label 'Malwarebytes download' `
                                     -ArgumentList @($mwbUrl, $mwbFile) -ScriptBlock {
            param($u, $o)
            $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Uri $u -OutFile $o -UseBasicParsing -ErrorAction Stop
                return $true
            } catch {
                return @{ Error = $_.Exception.Message }
            }
        }
        if ($job -is [bool] -and $job -eq $true) { $downloaded = $true }
        elseif ($job -is [hashtable] -and $job.Error) {
            Write-Host "  Download failed: $($job.Error)" -ForegroundColor Red
        } else {
            Write-Host "  Download timed out or failed without specific error." -ForegroundColor Red
        }
    } else {
        # Fallback - no timeout helper available
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $mwbUrl -OutFile $mwbFile -UseBasicParsing -ErrorAction Stop
            $downloaded = $true
        } catch {
            Write-Host "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    if ($downloaded -and (Test-Path $mwbFile)) {
        $sizeMB = [math]::Round((Get-Item $mwbFile).Length / 1MB, 1)
        Write-Host "  Downloaded: $mwbFile ($sizeMB MB)" -ForegroundColor Green
        Write-Host "  Technician should run this manually after deployment." -ForegroundColor DarkGray
    }
} else {
    Write-Host "`n[Phase 1d] Malwarebytes download: SKIPPED." -ForegroundColor DarkGray
}

# --- 1e. TeamViewer iDezign-branded Host (silent install) ---
# Downloads from get.teamviewer.com/idezign and runs with /S for silent install.
# Server-aware: TV Host runs fine on Server SKUs (unlike Claude Desktop MSIX),
# so no server gate here.
if ($doInstallTV) {
    Write-Host "`n[Phase 1e] Installing iDezign-branded TeamViewer Host..." -ForegroundColor Green

    $tvUrl  = 'https://get.teamviewer.com/idezign'
    $tvExe  = Join-Path $StagingDir 'TeamViewer_Host_iDezign.exe'

    Write-Host "  Source: $tvUrl" -ForegroundColor DarkGray
    Write-Host "  Local : $tvExe" -ForegroundColor DarkGray

    # Use job timeout helper if available - 10 min for download.
    $downloaded = $false
    if (Get-Command Invoke-WithJobTimeout -ErrorAction SilentlyContinue) {
        $jobResult = Invoke-WithJobTimeout -TimeoutMinutes 10 -Label 'TeamViewer download' `
                                            -ArgumentList @($tvUrl, $tvExe) -ScriptBlock {
            param($u, $o)
            $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Uri $u -OutFile $o -UseBasicParsing -ErrorAction Stop
                return $true
            } catch {
                return @{ Error = $_.Exception.Message }
            }
        }
        if ($jobResult -is [bool] -and $jobResult -eq $true) { $downloaded = $true }
        elseif ($jobResult -is [hashtable] -and $jobResult.Error) {
            Write-Host "  Download failed: $($jobResult.Error)" -ForegroundColor Red
        } else {
            Write-Host "  Download timed out or failed." -ForegroundColor Red
        }
    } else {
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $tvUrl -OutFile $tvExe -UseBasicParsing -ErrorAction Stop
            $downloaded = $true
        } catch {
            Write-Host "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    if ($downloaded -and (Test-Path $tvExe)) {
        $sizeMB = [math]::Round((Get-Item $tvExe).Length / 1MB, 1)
        Write-Host "  Downloaded: $sizeMB MB" -ForegroundColor DarkGray

        # Silent install. TeamViewer Custom Host installers use /S (NSIS).
        Write-Host "  Running silent install (timeout 10 min)..." -ForegroundColor DarkGray
        if (Get-Command Start-ProcessWithTimeout -ErrorAction SilentlyContinue) {
            $rc = Start-ProcessWithTimeout -FilePath $tvExe -ArgumentList @('/S') `
                    -TimeoutMinutes 10 -Label 'TeamViewer Host installer'
            if ($rc -eq 0) {
                Write-Host "  TeamViewer Host installed successfully." -ForegroundColor Green
            } elseif ($rc -eq -1) {
                Write-Host "  TeamViewer install TIMED OUT (>10 min)." -ForegroundColor Red
            } else {
                Write-Host "  TeamViewer installer returned exit code $rc." -ForegroundColor Yellow
                Write-Host "  Some custom host builds return non-zero on success - check by running" -ForegroundColor DarkGray
                Write-Host "  'Get-Service TeamViewer' or by looking for the system tray icon." -ForegroundColor DarkGray
            }
        } else {
            try {
                $p = Start-Process -FilePath $tvExe -ArgumentList '/S' -Wait -PassThru
                Write-Host "  Installer exit code: $($p.ExitCode)" -ForegroundColor DarkGray
            } catch {
                Write-Host "  ERROR running installer: $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        # Quick verify
        Start-Sleep -Seconds 3
        $tvSvc = Get-Service -Name 'TeamViewer' -ErrorAction SilentlyContinue
        if ($tvSvc) {
            Write-Host "  Verification: TeamViewer service state = $($tvSvc.Status)" -ForegroundColor DarkGray
        } else {
            Write-Host "  Warning: TeamViewer service not found after install. May need a reboot to register." -ForegroundColor DarkYellow
        }
    }
} else {
    Write-Host "`n[Phase 1e] TeamViewer install: SKIPPED." -ForegroundColor DarkGray
}

# --- 1f. Configure power settings (workstation/server tuning) ---
# Critical for Dentrix/SQL workstations - SQL Server doesn't recover gracefully
# when the disk spins down or the OS sleeps mid-transaction. We turn off all
# auto-sleep behaviors while leaving display sleep at 1 hour (saves the monitor,
# no functional impact).
#
# Laptop detection: we look at Win32_SystemEnclosure.ChassisTypes. If this is
# portable hardware, the user almost certainly wants battery-saving defaults
# and we skip - regardless of $doConfigurePower preference. Servers always
# get the workstation treatment regardless of chassis (rare edge case where
# someone runs Server OS on a laptop for portable lab work - still want servers
# to never sleep).
if ($doConfigurePower) {
    Write-Host "`n[Phase 1f] Configuring power settings..." -ForegroundColor Green

    $isLaptop = $false
    try {
        $enclosure = Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop
        # Chassis type codes from DMTF/SMBIOS spec:
        #   9 = Laptop, 10 = Notebook, 11 = Hand Held, 14 = Sub Notebook
        #   30 = Tablet, 31 = Convertible, 32 = Detachable
        # Treat any of these as "portable - keep battery saving".
        $portableTypes = @(9, 10, 11, 14, 30, 31, 32)
        foreach ($t in $enclosure.ChassisTypes) {
            if ($portableTypes -contains [int]$t) { $isLaptop = $true; break }
        }
    } catch {
        Write-Host "  (could not query chassis type - assuming desktop/tower)" -ForegroundColor DarkGray
    }

    # Server override - always apply, never skip for "laptop" chassis
    if ($isLaptop -and -not $IsServer) {
        Write-Host "  Portable chassis detected - SKIPPING power configuration." -ForegroundColor DarkYellow
        Write-Host "  (Laptops/tablets typically want battery-saving defaults left in place.)" -ForegroundColor DarkGray
        Write-Host "  Apply power settings manually via Settings -> System -> Power if needed." -ForegroundColor DarkGray
    } else {
        try {
            $currentScheme = (powercfg /getactivescheme | Out-String).Trim()
            Write-Host "  Active power scheme: $currentScheme" -ForegroundColor DarkGray

            # Hard drive: never spin down. Critical for SQL/Dentrix.
            powercfg /change disk-timeout-ac 0 2>&1 | Out-Null
            powercfg /change disk-timeout-dc 0 2>&1 | Out-Null
            Write-Host "  Hard drive          : NEVER spin down" -ForegroundColor DarkGray

            # Display: 60 minutes. Saves monitor lifetime, zero functional cost.
            powercfg /change monitor-timeout-ac 60 2>&1 | Out-Null
            powercfg /change monitor-timeout-dc 60 2>&1 | Out-Null
            Write-Host "  Display             : off after 60 minutes" -ForegroundColor DarkGray

            # Sleep: never. Workstations stay responsive for remote work,
            # overnight backups, scheduled tasks, RDP sessions.
            powercfg /change standby-timeout-ac 0 2>&1 | Out-Null
            powercfg /change standby-timeout-dc 0 2>&1 | Out-Null
            Write-Host "  Sleep               : NEVER" -ForegroundColor DarkGray

            # Hibernate timeout: never. Setting separate from the feature toggle below.
            powercfg /change hibernate-timeout-ac 0 2>&1 | Out-Null
            powercfg /change hibernate-timeout-dc 0 2>&1 | Out-Null
            Write-Host "  Hibernate timeout   : NEVER" -ForegroundColor DarkGray

            # Disable hibernation entirely. Removes hiberfil.sys (~75% of RAM
            # size, so 12 GB on a 16 GB machine) and also disables Fast Startup.
            # On always-on workstations and servers, Fast Startup isn't useful
            # and creates more problems than it solves (e.g. driver state
            # bleeding across "shutdowns" that aren't real shutdowns).
            powercfg /hibernate off 2>&1 | Out-Null
            Write-Host "  Hibernation feature : DISABLED (frees hiberfil.sys space, also disables Fast Startup)" -ForegroundColor DarkGray

            # Verify by re-reading the settings - this catches the rare case
            # where powercfg silently fails on a managed/GPO-controlled scheme.
            try {
                $verifyOutput = powercfg /q SCHEME_CURRENT SUB_DISK | Select-String 'Current AC Power Setting Index' | Select-Object -First 1
                Write-Host "  $verifyOutput" -ForegroundColor DarkGray
            } catch { }

            Write-Host "  Power configuration complete." -ForegroundColor DarkGray
        } catch {
            Write-Host "  ERROR configuring power: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
} else {
    Write-Host "`n[Phase 1f] Power configuration: SKIPPED (per your choice)." -ForegroundColor DarkGray
}

# --- 1g. Open-Shell (classic Start Menu via Ninite) ---
# Ninite installer URL pattern: ninite.com/<app>/ninite.exe. The installer
# is a per-product wrapper that always pulls the latest version. Free
# Ninite shows a small progress GUI but requires zero clicks - effectively
# silent for our purposes. We hide the PowerShell window via WindowStyle.
if ($doInstallOpenShell) {
    Write-Host "`n[Phase 1g] Installing Open-Shell (via Ninite)..." -ForegroundColor Green

    $niniteUrl = 'https://ninite.com/openshell/ninite.exe'
    $niniteExe = Join-Path $StagingDir 'Ninite_OpenShell.exe'

    if (Get-RemoteFile -Url $niniteUrl -OutFile $niniteExe -DisplayName 'Ninite Open-Shell installer') {
        try {
            # Ninite free installer: no command-line args needed. Just runs and
            # installs silently with a progress GUI. -Wait so we know when it's
            # done. WindowStyle Hidden suppresses the small Ninite window.
            $rc = Start-ProcessWithTimeout `
                    -FilePath $niniteExe `
                    -ArgumentList '' `
                    -TimeoutMinutes 10 -Label 'Ninite Open-Shell installer'

            if ($rc -eq 'TIMEOUT') {
                Write-Host "  Ninite installer TIMED OUT (>10 min). It may still finish in background." -ForegroundColor Red
            } elseif ($rc -eq 0) {
                Write-Host "  Open-Shell installed successfully." -ForegroundColor DarkGray
            } else {
                Write-Host "  Ninite installer returned exit code $rc." -ForegroundColor Yellow
                Write-Host "  Verify via: Get-Item 'C:\Program Files\Open-Shell'" -ForegroundColor DarkGray
            }

            # Verify by looking for the Open-Shell install directory
            $osPaths = @(
                'C:\Program Files\Open-Shell',
                'C:\Program Files (x86)\Open-Shell'
            )
            $found = $osPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($found) {
                Write-Host "  Verification: install found at $found" -ForegroundColor DarkGray
            } else {
                Write-Host "  Warning: Open-Shell directory not found after install. May have failed." -ForegroundColor DarkYellow
            }

            # --- Apply iDezign baseline Open-Shell defaults ---
            # Best-effort registry writes for Win7-style menu + Aero skin.
            # Writes to:
            #   - HKEY_USERS\.DEFAULT (template for new user profiles)
            #   - HKCU (current user, so the tech can verify by clicking Start)
            # If registry paths are slightly off for this Open-Shell version,
            # vanilla Open-Shell still works - we just don't get the styling.
            if ($doApplyOpenShellDefaults) {
                Write-Host "  Applying iDezign default Open-Shell settings..." -ForegroundColor DarkGray
                $osRegPaths = @(
                    'Registry::HKEY_USERS\.DEFAULT\Software\IvoSoft\ClassicStartMenu\Settings',
                    'HKCU:\Software\IvoSoft\ClassicStartMenu\Settings'
                )
                foreach ($regPath in $osRegPaths) {
                    try {
                        if (-not (Test-Path $regPath)) {
                            New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
                        }
                        # MenuStyle DWORD: 0=Classic, 1=Two columns, 2=Windows 7 style
                        Set-ItemProperty -Path $regPath -Name 'MenuStyle' -Value 2 -Type DWord -ErrorAction Stop
                        Set-ItemProperty -Path $regPath -Name 'SkinW7'    -Value 'Windows Aero' -Type String -ErrorAction Stop
                        Write-Host "    Applied to: $regPath" -ForegroundColor DarkGray
                    } catch {
                        Write-Host "    Could not write to $regPath - $($_.Exception.Message)" -ForegroundColor DarkYellow
                    }
                }
                Write-Host "  Defaults applied. New users get Win7-style menu; current user takes effect after Open-Shell restart." -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "  ERROR running Ninite installer: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
} else {
    Write-Host "`n[Phase 1g] Open-Shell install: SKIPPED." -ForegroundColor DarkGray
}

# --- 1h. Set network profile to Private ---
# Walks all active NetConnectionProfile entries and changes Public -> Private.
# Skips DomainAuthenticated profiles (those are controlled by AD/GPO and
# can't be manually changed without breaking domain membership detection).
if ($doSetNetworkPrivate) {
    Write-Host "`n[Phase 1h] Setting network profiles to Private..." -ForegroundColor Green

    try {
        $profiles = Get-NetConnectionProfile -ErrorAction Stop
        if (-not $profiles) {
            Write-Host "  No active network profiles found - skipping." -ForegroundColor DarkYellow
        } else {
            foreach ($p in $profiles) {
                $name = $p.Name
                $cat  = $p.NetworkCategory
                Write-Host "  Found profile: '$name' (currently $cat)" -ForegroundColor DarkGray

                if ($cat -eq 'DomainAuthenticated') {
                    Write-Host "    -> Domain-authenticated, leaving as-is (controlled by AD)." -ForegroundColor DarkGray
                } elseif ($cat -eq 'Private') {
                    Write-Host "    -> Already Private, no change needed." -ForegroundColor DarkGray
                } else {
                    try {
                        Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
                        Write-Host "    -> Changed to Private." -ForegroundColor DarkGray
                    } catch {
                        Write-Host "    -> ERROR changing profile: $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }
        }

        # --- Enable File/Print Sharing + Network Discovery for Private profile ---
        # Setting NetworkCategory=Private alone is not enough. The firewall has
        # separate rule groups for these features, and they're often disabled by
        # default even on Private networks (especially on newer Win11 builds).
        # Without these, network shares from this PC are invisible to other
        # workstations, which breaks Dentrix multi-workstation setups and
        # general office file-sharing scenarios.
        try {
            Set-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -Enabled True -Profile Private -ErrorAction Stop
            Write-Host "  File and Printer Sharing : ENABLED for Private profile." -ForegroundColor DarkGray
        } catch {
            Write-Host "  Could not enable File/Print Sharing: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }

        try {
            Set-NetFirewallRule -DisplayGroup 'Network Discovery' -Enabled True -Profile Private -ErrorAction Stop
            Write-Host "  Network Discovery        : ENABLED for Private profile." -ForegroundColor DarkGray
        } catch {
            Write-Host "  Could not enable Network Discovery: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }

        # Also start the Function Discovery services that Network Discovery needs
        # to actually publish/discover hosts. These are sometimes set to Manual
        # and not started, even with the firewall rules enabled.
        $fdServices = @('FDResPub','fdPHost','SSDPSRV','upnphost')
        foreach ($svcName in $fdServices) {
            try {
                $svc = Get-Service -Name $svcName -ErrorAction Stop
                if ($svc.StartType -eq 'Disabled') {
                    Set-Service -Name $svcName -StartupType Manual -ErrorAction SilentlyContinue
                }
                if ($svc.Status -ne 'Running') {
                    Start-Service -Name $svcName -ErrorAction SilentlyContinue
                }
            } catch { }
        }
        Write-Host "  Discovery services       : ensured running (FDResPub, fdPHost, SSDPSRV, upnphost)." -ForegroundColor DarkGray
    } catch {
        Write-Host "  ERROR enumerating network profiles: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "`n[Phase 1h] Network profile change: SKIPPED." -ForegroundColor DarkGray
}

# --- 1i. Microsoft Defender scan (Quick / Full / Skip) ---
# Configurable scan type set during initial prompts:
#   $scanType = 'Quick' (~3-5 min)  - active malware locations only
#   $scanType = 'Full'  (30 min - 4 hr) - every file including archives
#   $scanType = 'None'  - skip entirely
# We use Start-MpScan in a background job + poll status every 60 sec so the
# user sees progress and the script doesn't appear hung. Signatures are
# refreshed first - no point scanning with stale definitions. Threats found
# during this scan are reported at the end AND written to a timestamped log
# file in the staging directory for record-keeping.
if ($scanType -ne 'None') {
    Write-Host "`n[Phase 1i] Running Microsoft Defender $($scanType.ToLower()) scan..." -ForegroundColor Green

    # Set up the scan log file path. Created before scan starts so even errors
    # get logged. Timestamp ensures multiple runs don't overwrite each other.
    $scanLogFile = Join-Path $StagingDir ("scan_results_$(Get-Date -Format 'yyyy-MM-dd_HHmm').txt")

    # Helper: write to both console and the log file. Wrapped in a function so
    # both work consistently across the phase.
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
        Write-ScanLog "If a 3rd-party AV is managing protection, skipping scan." 'DarkYellow'
    } else {
        try {
            # 1. Update signatures first
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

            Write-Host "  Full scan log saved to: $scanLogFile" -ForegroundColor Cyan
        } catch {
            Write-ScanLog "ERROR during scan phase: $($_.Exception.Message)" 'Red'
        }
    }
} else {
    Write-Host "`n[Phase 1i] Defender scan: SKIPPED." -ForegroundColor DarkGray
}

# --- 1j. Defender exclusions for Dentrix/SQL ---
# Adds path and process exclusions to Microsoft Defender so it doesn't
# real-time-scan SQL Server data files (.mdf/.ldf) or Dentrix runtime
# directories. This is Microsoft's documented best practice for SQL Server
# (https://learn.microsoft.com/sql/database-engine/configure-windows/configure-antivirus-software-to-work-with-sql-server).
# Without these exclusions, Dentrix can become noticeably slow during
# patient lookups, scheduling, and chart access, especially on practices
# with large patient databases.
#
# Paths are added even if the target doesn't exist yet - they'll activate
# once Dentrix/SQL gets installed (e.g. post-imaging deployment).
#
# Custom Dentrix paths (e.g. custom install location, mapped network share
# to a Dentrix server): edit $extraDentrixPaths below and re-run.
if ($doDentrixExclusions) {
    Write-Host "`n[Phase 1j] Adding Defender exclusions for Dentrix/SQL..." -ForegroundColor Green

    if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
        Write-Host "  Defender cmdlets not available - skipping." -ForegroundColor DarkYellow
    } else {
        # Standard Dentrix install/data paths
        $dentrixPaths = @(
            'C:\Program Files\Dentrix',
            'C:\Program Files (x86)\Dentrix',
            'C:\Dentrix',
            'C:\PDB',                  # Dentrix Practice Database directory
            'C:\DXOne'                 # Dentrix Image Server data
        )

        # Microsoft SQL Server runtime + default data directories
        $sqlPaths = @(
            'C:\Program Files\Microsoft SQL Server',
            'C:\Program Files (x86)\Microsoft SQL Server'
        )

        # Add any custom paths here (e.g. mapped drives, non-default installs)
        $extraDentrixPaths = @(
            # 'D:\DentrixData'
            # '\\DENTRIX-SRV\PDB'
        )

        $allPaths = $dentrixPaths + $sqlPaths + $extraDentrixPaths

        # SQL Server process exclusions - these are the active processes that
        # touch the .mdf/.ldf files during operation. Excluding the processes
        # is more efficient than path-based exclusion alone.
        $sqlProcesses = @(
            'sqlservr.exe',       # SQL Server database engine
            'sqlbrowser.exe',     # SQL Server Browser service
            'sqlwriter.exe',      # SQL Server VSS Writer (backups)
            'sqlceip.exe'         # SQL Server telemetry (usually fine to exclude)
        )

        # Add path exclusions
        Write-Host "  Adding path exclusions..." -ForegroundColor DarkGray
        foreach ($path in $allPaths) {
            try {
                Add-MpPreference -ExclusionPath $path -ErrorAction Stop
                Write-Host "    + $path" -ForegroundColor DarkGray
            } catch {
                Write-Host "    ! Could not exclude $path - $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }

        # Add process exclusions
        Write-Host "  Adding process exclusions..." -ForegroundColor DarkGray
        foreach ($proc in $sqlProcesses) {
            try {
                Add-MpPreference -ExclusionProcess $proc -ErrorAction Stop
                Write-Host "    + $proc" -ForegroundColor DarkGray
            } catch {
                Write-Host "    ! Could not exclude process $proc - $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }

        # Show current exclusion summary for verification
        try {
            $pref = Get-MpPreference -ErrorAction Stop
            Write-Host "  Verification - current exclusion counts:" -ForegroundColor DarkGray
            Write-Host "    Paths    : $($pref.ExclusionPath.Count)" -ForegroundColor DarkGray
            Write-Host "    Processes: $($pref.ExclusionProcess.Count)" -ForegroundColor DarkGray
        } catch { }
    }
} else {
    Write-Host "`n[Phase 1j] Dentrix/SQL exclusions: SKIPPED." -ForegroundColor DarkGray
}

# --- 1k. Strip Microsoft consumer integrations (OneDrive + Teams + nags) ---
# Three sub-phases driven by separate booleans. Main event is the OneDrive
# nuke - the others are bonus strips that go nicely with it.
#
# WARNING: This phase makes opinionated changes to consumer Windows defaults.
# It's intended for business / dental practice workstations where these
# integrations cause more support tickets than they solve. On a home PC or
# a user who actively uses OneDrive personally, this would be unwelcome.
#
# Reinstating OneDrive after this phase: remove the policy keys under
#   HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive
# then run OneDriveSetup.exe from %SYSTEMROOT%\SysWOW64 or download fresh.

if ($doNukeOneDrive) {
    Write-Host "`n[Phase 1k] Nuking OneDrive..." -ForegroundColor Green

    # Step 1: stop running OneDrive processes (per-session for all users)
    Write-Host "  Stopping OneDrive processes..." -ForegroundColor DarkGray
    Get-Process -Name 'OneDrive','FileCoAuth','OneDriveStandaloneUpdater' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    # taskkill is more aggressive and catches some edge cases where Get-Process
    # filters out processes from other user sessions
    & taskkill.exe /F /IM OneDrive.exe /T 2>&1 | Out-Null
    & taskkill.exe /F /IM FileCoAuth.exe /T 2>&1 | Out-Null

    # Step 2: un-redirect Documents/Desktop/Pictures BEFORE uninstalling
    # OneDrive. Order matters - if we uninstall first, the OneDrive folder
    # structure goes away and we lose track of where to move files FROM.
    # We do this for all real user profiles on the box (not Default/Public).
    Write-Host "  Un-redirecting known folders for all user profiles..." -ForegroundColor DarkGray

    $profiles = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
                Where-Object { -not $_.Special -and $_.LocalPath -like 'C:\Users\*' -and
                               $_.LocalPath -notlike '*\Default*' -and
                               $_.LocalPath -notlike '*\Public*' }

    foreach ($p in $profiles) {
        $userPath = $p.LocalPath
        $userName = Split-Path $userPath -Leaf
        $sid = $p.SID

        Write-Host "    Profile: $userName ($userPath)" -ForegroundColor DarkGray

        # Load the user's NTUSER.DAT hive if they're not logged in. We mount
        # under a unique key name so we don't collide with logged-in users.
        $hiveLoaded = $false
        $hiveKey = "HKU\TempHive_$($sid -replace '-','_')"
        $ntuser = Join-Path $userPath 'NTUSER.DAT'
        if (-not (Test-Path "Registry::HKEY_USERS\$sid")) {
            if (Test-Path $ntuser) {
                & reg.exe load $hiveKey $ntuser 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $hiveLoaded = $true
                    $sidPath = "Registry::HKEY_USERS\TempHive_$($sid -replace '-','_')"
                } else {
                    Write-Host "      Could not load NTUSER.DAT - skipping" -ForegroundColor DarkYellow
                    continue
                }
            } else {
                Write-Host "      No NTUSER.DAT found - skipping" -ForegroundColor DarkYellow
                continue
            }
        } else {
            $sidPath = "Registry::HKEY_USERS\$sid"
        }

        try {
            # The two registry locations Windows reads for shell folder paths
            $shellFolders     = "$sidPath\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
            $userShellFolders = "$sidPath\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"

            # Known folders we un-redirect. The PathValue is what Windows expects;
            # %USERPROFILE% gets expanded at access time. Each tuple:
            #   FolderName, ShellFoldersValueName, UserShellFoldersValueName, RawPath, ExpandedPath
            $folders = @(
                @{ Name='Documents'; Sv='Personal';   Uv='Personal';   Raw="$userPath\Documents"; Expand='%USERPROFILE%\Documents' },
                @{ Name='Desktop';   Sv='Desktop';    Uv='Desktop';    Raw="$userPath\Desktop";   Expand='%USERPROFILE%\Desktop'   },
                @{ Name='Pictures';  Sv='My Pictures';Uv='My Pictures';Raw="$userPath\Pictures";  Expand='%USERPROFILE%\Pictures'  }
            )

            foreach ($f in $folders) {
                # Check if currently redirected into OneDrive
                $current = $null
                try {
                    $current = (Get-ItemProperty -Path $shellFolders -Name $f.Sv -ErrorAction Stop).$($f.Sv)
                } catch { }

                $isRedirected = $current -and ($current -like '*OneDrive*')
                if ($isRedirected) {
                    Write-Host "      $($f.Name): redirected ($current) -> restoring" -ForegroundColor DarkGray

                    # Move files back from OneDrive folder to local folder, if
                    # destination doesn't already exist or is empty.
                    if (Test-Path $current) {
                        if (-not (Test-Path $f.Raw)) {
                            New-Item -Path $f.Raw -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                        }
                        try {
                            $items = Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue
                            if ($items) {
                                foreach ($item in $items) {
                                    $destPath = Join-Path $f.Raw $item.Name
                                    if (-not (Test-Path $destPath)) {
                                        Move-Item -LiteralPath $item.FullName -Destination $destPath -Force -ErrorAction SilentlyContinue
                                    }
                                }
                                Write-Host "        Moved files back to $($f.Raw)" -ForegroundColor DarkGray
                            }
                        } catch {
                            Write-Host "        File move had issues: $($_.Exception.Message)" -ForegroundColor DarkYellow
                        }
                    }

                    # Update both registry locations
                    try {
                        Set-ItemProperty -Path $shellFolders     -Name $f.Sv -Value $f.Raw    -ErrorAction Stop
                        Set-ItemProperty -Path $userShellFolders -Name $f.Uv -Value $f.Expand -Type ExpandString -ErrorAction Stop
                    } catch {
                        Write-Host "        Registry update failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
                    }
                } else {
                    Write-Host "      $($f.Name): not redirected, no change" -ForegroundColor DarkGray
                }
            }
        } catch {
            Write-Host "      ERROR processing profile: $($_.Exception.Message)" -ForegroundColor Red
        } finally {
            # Unload the hive if we loaded it
            if ($hiveLoaded) {
                [System.GC]::Collect()  # release any registry handles before unload
                Start-Sleep -Milliseconds 200
                & reg.exe unload $hiveKey 2>&1 | Out-Null
            }
        }
    }

    # Step 3: uninstall OneDrive. Win11 ships per-user installer under
    # %LOCALAPPDATA%, while older builds use per-machine in SysWOW64/System32.
    # We try all known locations.
    Write-Host "  Uninstalling OneDrive..." -ForegroundColor DarkGray
    $uninstallers = @(
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe",
        "$env:SystemRoot\System32\OneDriveSetup.exe"
    )
    # Also check each user profile for per-user installs
    foreach ($p in $profiles) {
        $userInstall = Join-Path $p.LocalPath 'AppData\Local\Microsoft\OneDrive\OneDriveSetup.exe'
        if (Test-Path $userInstall) { $uninstallers += $userInstall }
    }
    $uninstallers = $uninstallers | Where-Object { Test-Path $_ } | Select-Object -Unique

    foreach ($u in $uninstallers) {
        Write-Host "    Running: $u /uninstall /allusers" -ForegroundColor DarkGray
        try {
            $proc = Start-Process -FilePath $u -ArgumentList '/uninstall','/allusers' -Wait -PassThru -ErrorAction Stop
            if ($proc.ExitCode -ne 0) {
                Write-Host "      Returned exit code $($proc.ExitCode) - usually fine, OneDrive uninstaller is quirky" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "      Uninstall failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    # Step 4: scorched-earth cleanup of OneDrive leftover folders. These
    # persist after the uninstaller runs and clutter Explorer.
    Write-Host "  Removing leftover OneDrive folders..." -ForegroundColor DarkGray
    $cleanupPaths = @(
        "$env:LOCALAPPDATA\Microsoft\OneDrive",
        "$env:PROGRAMDATA\Microsoft OneDrive",
        "C:\OneDriveTemp"
    )
    foreach ($p in $profiles) {
        $cleanupPaths += "$($p.LocalPath)\AppData\Local\Microsoft\OneDrive"
        $cleanupPaths += "$($p.LocalPath)\OneDrive"
    }
    foreach ($cp in ($cleanupPaths | Select-Object -Unique)) {
        if (Test-Path $cp) {
            try {
                Remove-Item -Path $cp -Recurse -Force -ErrorAction Stop
                Write-Host "    removed: $cp" -ForegroundColor DarkGray
            } catch {
                Write-Host "    skipped (in use): $cp" -ForegroundColor DarkYellow
            }
        }
    }

    # Step 5: remove the OneDrive icon from the Explorer navigation pane.
    # Two CLSIDs cover both 32-bit and 64-bit views.
    Write-Host "  Removing OneDrive from Explorer sidebar..." -ForegroundColor DarkGray
    $clsids = @(
        'HKLM:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
        'HKLM:\SOFTWARE\Classes\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
    )
    foreach ($c in $clsids) {
        if (Test-Path $c) {
            try {
                Set-ItemProperty -Path $c -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -Type DWord -Force -ErrorAction Stop
                Write-Host "    hidden from sidebar: $c" -ForegroundColor DarkGray
            } catch { }
        }
    }

    # Step 6: block reinstallation via Group Policy registry keys.
    # These prevent OneDrive from being silently reinstalled by Windows Update
    # or by user-initiated install attempts. Documented at:
    # https://learn.microsoft.com/onedrive/use-group-policy
    Write-Host "  Blocking future OneDrive reinstall via policy..." -ForegroundColor DarkGray
    $onedrivePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
    try {
        if (-not (Test-Path $onedrivePolicy)) {
            New-Item -Path $onedrivePolicy -Force -ErrorAction Stop | Out-Null
        }
        # DisableFileSyncNGSC: disables OneDrive sync engine
        Set-ItemProperty -Path $onedrivePolicy -Name 'DisableFileSyncNGSC' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        # PreventNetworkTrafficPreUserSignIn: stops phone-home before login
        Set-ItemProperty -Path $onedrivePolicy -Name 'PreventNetworkTrafficPreUserSignIn' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "    Group Policy block applied." -ForegroundColor DarkGray
    } catch {
        Write-Host "    Could not write policy keys: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    # Step 7: remove OneDrive autostart for all users (Run key + scheduled task)
    Write-Host "  Removing OneDrive autostart..." -ForegroundColor DarkGray
    # Remove from each user's Run key (machine-wide HKLM Run too just in case)
    $runKeys = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($rk in $runKeys) {
        if (Test-Path $rk) {
            Remove-ItemProperty -Path $rk -Name 'OneDrive','OneDriveSetup' -ErrorAction SilentlyContinue
        }
    }
    # Scheduled tasks
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -like 'OneDrive*' -or $_.TaskName -like '*OneDrive*' } |
        ForEach-Object {
            try {
                Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction Stop
                Write-Host "    removed task: $($_.TaskName)" -ForegroundColor DarkGray
            } catch { }
        }

    Write-Host "  OneDrive nuke complete." -ForegroundColor Green
    Write-Host "  Users may need to sign out and back in to fully purge OneDrive Explorer integration." -ForegroundColor DarkYellow

    # --- Sub-phase: strip Teams personal version ---
    if ($doStripTeamsPersonal) {
        Write-Host "  Removing Teams personal version chat icon..." -ForegroundColor DarkGray
        # Hide the chat icon next to Start (per-machine policy)
        $teamsPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat'
        try {
            if (-not (Test-Path $teamsPolicy)) {
                New-Item -Path $teamsPolicy -Force -ErrorAction Stop | Out-Null
            }
            Set-ItemProperty -Path $teamsPolicy -Name 'ChatIcon' -Value 3 -Type DWord -Force -ErrorAction Stop
            Write-Host "    Teams chat icon hidden via policy." -ForegroundColor DarkGray
        } catch {
            Write-Host "    Could not set Teams chat policy: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }

        # Also uninstall the MicrosoftTeams MSIX provisioned package (personal)
        # NOT the work/school Teams (MSTeams). The personal package name is
        # 'MicrosoftTeams' - the work version is 'MSTeams'.
        try {
            $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                           Where-Object { $_.DisplayName -eq 'MicrosoftTeams' }
            if ($provisioned) {
                $provisioned | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
                Write-Host "    Provisioned MicrosoftTeams (personal) removed." -ForegroundColor DarkGray
            }
            Get-AppxPackage -AllUsers -Name 'MicrosoftTeams' -ErrorAction SilentlyContinue |
                Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
        } catch {
            Write-Host "    Teams package removal: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    # --- Sub-phase: disable "Get more out of Windows" nags ---
    if ($doStripMSnags) {
        Write-Host "  Disabling Microsoft consumer experience nags..." -ForegroundColor DarkGray

        # ContentDeliveryManager keys - these control suggested apps,
        # lock screen ads, "complete your setup" nags, etc. We apply to
        # .DEFAULT hive (new profiles) AND current user.
        $cdmTargets = @(
            'Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        )
        $cdmKeys = @{
            'SubscribedContent-310093Enabled' = 0   # "Get fun facts" lock screen tips
            'SubscribedContent-338388Enabled' = 0   # Start menu suggested apps
            'SubscribedContent-338389Enabled' = 0   # Settings app suggestions
            'SubscribedContent-353698Enabled' = 0   # Timeline suggestions
            'SilentInstalledAppsEnabled'      = 0   # Silent install of partner apps
            'RotatingLockScreenOverlayEnabled'= 0   # Lock screen overlay ads
            'SystemPaneSuggestionsEnabled'    = 0   # "Suggestions" in system pane
            'OemPreInstalledAppsEnabled'      = 0   # OEM-pushed apps
            'PreInstalledAppsEnabled'         = 0   # MS-pushed apps
            'SoftLandingEnabled'              = 0   # Windows tips popups
        }
        foreach ($t in $cdmTargets) {
            try {
                if (-not (Test-Path $t)) { New-Item -Path $t -Force -ErrorAction Stop | Out-Null }
                foreach ($k in $cdmKeys.Keys) {
                    Set-ItemProperty -Path $t -Name $k -Value $cdmKeys[$k] -Type DWord -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
        Write-Host "    Content Delivery Manager nags disabled." -ForegroundColor DarkGray

        # "Finish setting up your device" / OOBE post-install nag
        # (the one that prompts to enable OneDrive, link your phone, etc.)
        $userOOBE = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'
        try {
            if (-not (Test-Path $userOOBE)) { New-Item -Path $userOOBE -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $userOOBE -Name 'ScoobeSystemSettingEnabled' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Host "    'Finish setting up' OOBE nag disabled." -ForegroundColor DarkGray
        } catch { }

        # Windows Backup nag - this is the "Set up Windows Backup" prompt
        # introduced in Win11 23H2. Policy-disable via FeatureManagement.
        $featurePath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'
        try {
            if (-not (Test-Path $featurePath)) { New-Item -Path $featurePath -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $featurePath -Name 'HideRecommendedSection' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        } catch { }

        # Disable "Suggestions on Start" via Cloud Content policy (machine-wide)
        $cloudPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
        try {
            if (-not (Test-Path $cloudPolicy)) { New-Item -Path $cloudPolicy -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $cloudPolicy -Name 'DisableConsumerAccountStateContent' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $cloudPolicy -Name 'DisableWindowsConsumerFeatures'     -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $cloudPolicy -Name 'DisableCloudOptimizedContent'       -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Host "    Consumer features policy applied." -ForegroundColor DarkGray
        } catch { }
    }
} else {
    Write-Host "`n[Phase 1k] OneDrive nuke: SKIPPED." -ForegroundColor DarkGray
}

#endregion

#region --- 2. Cleanup --------------------------------------------------------

function Remove-PathSafe {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        try {
            Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue |
                Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            Write-Host "  cleaned : $Path" -ForegroundColor DarkGray
        } catch {
            Write-Host "  skipped : $Path  ($($_.Exception.Message))" -ForegroundColor DarkYellow
        }
    }
}

Write-Host "`n[Phase 2 - 1/8] Cleaning temp folders..." -ForegroundColor Green
Remove-PathSafe "$env:TEMP"
Remove-PathSafe "$env:LOCALAPPDATA\Temp"
Remove-PathSafe "C:\Windows\Temp"
Remove-PathSafe "C:\Windows\Prefetch"

Write-Host "`n[Phase 2 - 2/8] Clearing Windows Update download cache..." -ForegroundColor Green
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Stop-Service bits    -Force -ErrorAction SilentlyContinue
Remove-PathSafe "C:\Windows\SoftwareDistribution\Download"
Start-Service bits    -ErrorAction SilentlyContinue
Start-Service wuauserv -ErrorAction SilentlyContinue

Write-Host "`n[Phase 2 - 3/8] Clearing browser caches (Edge / Chrome if present)..." -ForegroundColor Green
$browserCachePaths = @(
    "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
    "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache",
    "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
    "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
    "$env:APPDATA\Mozilla\Firefox\Profiles"
)
foreach ($p in $browserCachePaths) { Remove-PathSafe $p }

Write-Host "`n[Phase 2 - 4/8] Recent items + thumbnail cache..." -ForegroundColor Green
Remove-PathSafe "$env:APPDATA\Microsoft\Windows\Recent"
Remove-PathSafe "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"

Write-Host "`n[Phase 2 - 5/8] Removing Windows.old (previous Windows install)..." -ForegroundColor Green
if (Test-Path "C:\Windows.old") {
    cmd /c "takeown /F C:\Windows.old /R /A /D Y >nul 2>&1"
    cmd /c "icacls C:\Windows.old /grant administrators:F /T /C /Q >nul 2>&1"
    Remove-Item "C:\Windows.old" -Force -Recurse -ErrorAction SilentlyContinue
    if (Test-Path "C:\Windows.old") {
        Write-Host "  Windows.old still present - try: cleanmgr /sageset:99 -> check 'Previous Windows installations'" -ForegroundColor DarkYellow
    } else {
        Write-Host "  Windows.old removed." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  no Windows.old folder found." -ForegroundColor DarkGray
}

Write-Host "`n[Phase 2 - 6/8] Clearing all event logs..." -ForegroundColor Green
if ($IsServer) {
    Write-Host "  SKIPPED on Windows Server - audit trail must be preserved." -ForegroundColor Yellow
    Write-Host "  (HIPAA, SOC, security forensics, etc. all depend on logs.)" -ForegroundColor DarkGray
} else {
    wevtutil el | ForEach-Object {
        wevtutil cl "$_" 2>$null
    }
}

Write-Host "`n[Phase 2 - 7/8] Deleting restore points / shadow copies..." -ForegroundColor Green
if ($IsServer) {
    Write-Host "  SKIPPED on Windows Server - VSS shadows back live backups." -ForegroundColor Yellow
    Write-Host "  (Veeam, Windows Server Backup, file-server previous-versions" -ForegroundColor DarkGray
    Write-Host "   all use VSS. Deleting could corrupt in-flight backup jobs.)" -ForegroundColor DarkGray
} else {
    # vssadmin can hang if the VSS service is wedged or storage is busy. Hard
    # 5-min cap, then move on. Shadow deletion is best-effort cleanup, not
    # critical to imaging.
    if (Get-Command Start-ProcessWithTimeout -ErrorAction SilentlyContinue) {
        $vssRc = Start-ProcessWithTimeout -FilePath 'vssadmin.exe' `
                    -ArgumentList @('delete','shadows','/all','/quiet') `
                    -TimeoutMinutes 5 -Label 'vssadmin delete shadows'
        if ($vssRc -eq -1) {
            Write-Host "  vssadmin TIMED OUT (>5 min) - skipped. Shadow copies may remain." -ForegroundColor DarkYellow
        }
    } else {
        cmd /c "vssadmin delete shadows /all /quiet" | Out-Null
    }
}

Write-Host "`n[Phase 2 - 8/8] DISM component cleanup..." -ForegroundColor Green
# Defensive sequence:
#   1. Check pending state ONE more time. If anything pending, skip resetbase.
#   2. Try /startcomponentcleanup /resetbase (the full deal - can be slow).
#   3. If it fails (any non-zero exit), fall back to plain /startcomponentcleanup.
#      That variant is more forgiving and almost always succeeds. We just
#      lose the ability to permanently shrink WinSxS - tradeoff for the
#      script not blowing up.

$skipResetBase = $false
if ($state -and $state.SkipResetBase) {
    Write-Host "  SkipResetBase flag set from earlier - using gentler cleanup." -ForegroundColor DarkYellow
    $skipResetBase = $true
}
if ($IsServer) {
    Write-Host "  Server detected - forcing skip of /resetbase to preserve rollback." -ForegroundColor Yellow
    $skipResetBase = $true
}

$pendingNow = Test-PendingReboot
if ($pendingNow.Count -gt 0) {
    Write-Host "  Pending operations STILL detected ($($pendingNow -join ', '))" -ForegroundColor Yellow
    Write-Host "  Will skip /resetbase to avoid 0x800f0806." -ForegroundColor DarkYellow
    $skipResetBase = $true
}

if ($skipResetBase) {
    Write-Host "  Running DISM /startcomponentcleanup (without /resetbase)..." -ForegroundColor DarkGray
    if (Get-Command Start-ProcessWithTimeout -ErrorAction SilentlyContinue) {
        # 20 min cap - generous; gentler cleanup is usually 2-5 min
        $rc = Start-ProcessWithTimeout -FilePath 'dism.exe' `
                -ArgumentList @('/online','/cleanup-image','/startcomponentcleanup') `
                -TimeoutMinutes 20 -Label 'DISM startcomponentcleanup'
    } else {
        & dism.exe /online /cleanup-image /startcomponentcleanup
        $rc = $LASTEXITCODE
    }
    if ($rc -eq -1) {
        Write-Host "  DISM TIMED OUT (>20 min). Continuing." -ForegroundColor Red
    } elseif ($rc -ne 0) {
        Write-Host "  DISM still returned $rc - skipping. WinSxS will be larger than ideal." -ForegroundColor DarkYellow
    } else {
        Write-Host "  DISM cleanup complete (no resetbase)." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  Running DISM /startcomponentcleanup /resetbase (this can take 5-15 minutes)..." -ForegroundColor DarkGray
    if (Get-Command Start-ProcessWithTimeout -ErrorAction SilentlyContinue) {
        # 25 min cap - resetbase legitimately takes 5-15 min on most boxes
        $rc = Start-ProcessWithTimeout -FilePath 'dism.exe' `
                -ArgumentList @('/online','/cleanup-image','/startcomponentcleanup','/resetbase') `
                -TimeoutMinutes 25 -Label 'DISM resetbase'
    } else {
        & dism.exe /online /cleanup-image /startcomponentcleanup /resetbase
        $rc = $LASTEXITCODE
    }
    if ($rc -eq 0) {
        Write-Host "  DISM /resetbase complete." -ForegroundColor DarkGray
    } else {
        if ($rc -eq -1) {
            Write-Host "  /resetbase TIMED OUT - falling back to /startcomponentcleanup alone..." -ForegroundColor DarkYellow
        } else {
            Write-Host "  /resetbase failed with exit code $rc - falling back to /startcomponentcleanup alone..." -ForegroundColor DarkYellow
        }
        if (Get-Command Start-ProcessWithTimeout -ErrorAction SilentlyContinue) {
            $rc2 = Start-ProcessWithTimeout -FilePath 'dism.exe' `
                    -ArgumentList @('/online','/cleanup-image','/startcomponentcleanup') `
                    -TimeoutMinutes 20 -Label 'DISM startcomponentcleanup (fallback)'
        } else {
            & dism.exe /online /cleanup-image /startcomponentcleanup
            $rc2 = $LASTEXITCODE
        }
        if ($rc2 -eq -1) {
            Write-Host "  Fallback DISM also TIMED OUT. Skipping." -ForegroundColor Red
        } elseif ($rc2 -ne 0) {
            Write-Host "  Fallback also returned $rc2 - skipping. Check C:\Windows\Logs\DISM\dism.log" -ForegroundColor DarkYellow
        } else {
            Write-Host "  Fallback /startcomponentcleanup succeeded." -ForegroundColor DarkGray
        }
    }
}

Write-Host "`n[+] Emptying Recycle Bin..." -ForegroundColor Green
Clear-RecycleBin -Force -ErrorAction SilentlyContinue

Write-Host "`n[+] Native disk cleanup (replaces cleanmgr.exe)..." -ForegroundColor Green
# cleanmgr.exe hangs unreliably even with /sagerun:64 and /verylowdisk - its dialog
# loses focus when the desktop is clicked, and it sometimes never exits. We do the
# same cleanup work in pure PowerShell so it (a) never hangs, (b) works on Server
# SKUs where cleanmgr isn't installed, (c) shows exactly what's being removed.
#
# Targets the same locations cleanmgr's "VolumeCaches" registry keys point at,
# minus what Phase 2 already cleaned.

$nativeCleanupTargets = @(
    # Memory dumps - cleanmgr's "Memory Dump Files"
    'C:\Windows\Memory.dmp',
    'C:\Windows\Minidump\*',

    # Old chkdsk recovered fragments - cleanmgr's "Old ChkDsk Files"
    'C:\found.000\*',
    'C:\found.001\*',
    'C:\found.002\*',

    # Upgrade artifacts - cleanmgr's "Temporary Setup Files" + "Upgrade Discarded"
    'C:\$Windows.~BT',
    'C:\$Windows.~LS',
    'C:\$Windows.~Q',
    'C:\$WINDOWS.~WS',

    # Windows Error Reporting archive + queue - cleanmgr's "WER" entries
    'C:\ProgramData\Microsoft\Windows\WER\ReportArchive\*',
    'C:\ProgramData\Microsoft\Windows\WER\ReportQueue\*',
    'C:\ProgramData\Microsoft\Windows\WER\Temp\*',

    # IE/Edge legacy cache - cleanmgr's "Internet Cache Files"
    "$env:LOCALAPPDATA\Microsoft\Windows\INetCache\*",

    # Specific thumbnail cache files - cleanmgr's "Thumbnail Cache"
    "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db",
    "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db",

    # Setup logs (Panther) - cleanmgr's "Setup Log Files". Skip if recent
    # install - those logs are still useful for ~30 days post-install.
    # Logs older than 30 days are safe to remove.
    # Handled separately below.

    # ActiveX/downloaded program files - cleanmgr's "Downloaded Program Files"
    'C:\Windows\Downloaded Program Files\*',

    # Delivery Optimization files - cleanmgr's "Delivery Optimization Files"
    'C:\Windows\SoftwareDistribution\DeliveryOptimization\Cache\*',

    # Office Click-to-Run cache leftovers
    "$env:LOCALAPPDATA\Microsoft\Office\OTele\*"
)

$nativeCleanupCount = 0
$nativeCleanupBytes = 0

foreach ($target in $nativeCleanupTargets) {
    if (Test-Path -LiteralPath $target -ErrorAction SilentlyContinue) {
        try {
            # Sum sizes before delete for the user-facing summary
            $items = Get-ChildItem -Path $target -Force -Recurse -ErrorAction SilentlyContinue
            if ($items) {
                $bytes = ($items | Where-Object { -not $_.PSIsContainer } |
                          Measure-Object Length -Sum -ErrorAction SilentlyContinue).Sum
                if ($bytes) { $nativeCleanupBytes += $bytes }
            }
            Remove-Item -Path $target -Force -Recurse -ErrorAction SilentlyContinue
            $nativeCleanupCount++
            Write-Host "  cleaned : $target" -ForegroundColor DarkGray
        } catch {
            Write-Host "  skipped : $target  ($($_.Exception.Message))" -ForegroundColor DarkYellow
        }
    }
}

# Setup logs older than 30 days only - we don't want to nuke logs from
# yesterday's troubleshooting session.
if (Test-Path 'C:\Windows\Panther') {
    try {
        $cutoff = (Get-Date).AddDays(-30)
        $oldLogs = Get-ChildItem 'C:\Windows\Panther' -File -Recurse -ErrorAction SilentlyContinue |
                   Where-Object { $_.LastWriteTime -lt $cutoff }
        if ($oldLogs) {
            $oldBytes = ($oldLogs | Measure-Object Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($oldBytes) { $nativeCleanupBytes += $oldBytes }
            $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Host "  cleaned : C:\Windows\Panther (logs older than 30 days, $($oldLogs.Count) files)" -ForegroundColor DarkGray
            $nativeCleanupCount++
        }
    } catch { }
}

$mbFreed = [math]::Round($nativeCleanupBytes / 1MB, 1)
Write-Host "  Cleaned $nativeCleanupCount location(s), approx $mbFreed MB freed." -ForegroundColor DarkGray
Write-Host "  (cleanmgr.exe intentionally not run - PowerShell-native cleanup is more reliable.)" -ForegroundColor DarkGray

#endregion

#region --- 2c. Imaging-prep tweaks (always-run, added v2.5) ------------------
# Self-contained, failure-tolerant prep applied on every cleanup run. No prompts,
# no persisted state - standard prep for a machine being handed to an end user.
# Each step is wrapped so one failure never blocks the rest.

Write-Host "`n[Phase 2c] Imaging-prep tweaks..." -ForegroundColor Green

# --- 2c-1: Turn off Windows notifications (current user) ----------------------
Write-Host "  [2c-1] Disabling Windows notifications + suggestion nags..." -ForegroundColor DarkGray
try {
    $pnRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
    New-Item -Path $pnRoot -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $pnRoot -Name 'ToastEnabled' -Type DWord -Value 0 -Force -ErrorAction SilentlyContinue

    $explPol = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
    New-Item -Path $explPol -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $explPol -Name 'DisableNotificationCenter' -Type DWord -Value 1 -Force -ErrorAction SilentlyContinue

    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    New-Item -Path $cdm -Force -ErrorAction SilentlyContinue | Out-Null
    foreach ($v in 'SubscribedContent-310093Enabled','SubscribedContent-338389Enabled','SystemPaneSuggestionsEnabled','ScoobeSystemSettingEnabled') {
        Set-ItemProperty -Path $cdm -Name $v -Type DWord -Value 0 -Force -ErrorAction SilentlyContinue
    }
    Write-Host "    Notifications + suggestion nags disabled (current user)." -ForegroundColor DarkGray
} catch {
    Write-Host "    (notifications step issue: $($_.Exception.Message))" -ForegroundColor DarkYellow
}

# --- 2c-2: Network adapters -> DHCP (report any static config FIRST) ----------
Write-Host "  [2c-2] Setting network adapters to DHCP..." -ForegroundColor DarkGray
try {
    $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
    if (-not $adapters) { Write-Host "    (no active physical adapters found.)" -ForegroundColor DarkGray }
    foreach ($ad in $adapters) {
        $ipif = Get-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if (-not $ipif) { continue }
        if ($ipif.Dhcp -eq 'Disabled') {
            # STATIC - record the existing config loudly before changing anything
            $ips = Get-NetIPAddress  -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $gw  = (Get-NetRoute -InterfaceIndex $ad.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
            $dns = (Get-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses -join ', '
            Write-Host "    *** STATIC IP on '$($ad.Name)' - RECORDING before switch to DHCP ***" -ForegroundColor Yellow
            foreach ($ip in $ips) { Write-Host ("      IP/Mask : {0}/{1}" -f $ip.IPAddress, $ip.PrefixLength) -ForegroundColor Yellow }
            Write-Host ("      Gateway : {0}" -f $gw)  -ForegroundColor Yellow
            Write-Host ("      DNS     : {0}" -f $dns) -ForegroundColor Yellow

            Set-NetIPInterface       -InterfaceIndex $ad.ifIndex -Dhcp Enabled -ErrorAction SilentlyContinue
            Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
            Write-Host "      -> '$($ad.Name)' switched to DHCP." -ForegroundColor DarkGray
        } else {
            Write-Host "    '$($ad.Name)' already on DHCP - no change." -ForegroundColor DarkGray
        }
    }
} catch {
    Write-Host "    (DHCP step issue: $($_.Exception.Message))" -ForegroundColor DarkYellow
}

# --- 2c-3: Remove Microsoft Teams (consumer + new work/school + machine-wide) -
Write-Host "  [2c-3] Removing Microsoft Teams app(s)..." -ForegroundColor DarkGray
try {
    # Hide the Win11 chat icon (per-machine policy)
    $chatPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat'
    New-Item -Path $chatPol -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $chatPol -Name 'ChatIcon' -Type DWord -Value 3 -Force -ErrorAction SilentlyContinue

    foreach ($pkg in 'MicrosoftTeams','MSTeams') {
        Get-AppxPackage -AllUsers -Name $pkg -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue }
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq $pkg } |
            ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue } | Out-Null
    }

    # Classic "Teams Machine-Wide Installer" (MSI)
    $twKeys = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                               'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
              Where-Object { $_.DisplayName -like 'Teams Machine-Wide Installer*' }
    foreach ($t in $twKeys) {
        if ($t.UninstallString -match '\{[0-9A-Fa-f\-]+\}') {
            $guid = $Matches[0]
            Start-Process msiexec.exe -ArgumentList "/x $guid /qn /norestart" -Wait -ErrorAction SilentlyContinue
        }
    }
    Write-Host "    Teams (consumer + work/school + machine-wide) removal attempted." -ForegroundColor DarkGray
} catch {
    Write-Host "    (Teams removal issue: $($_.Exception.Message))" -ForegroundColor DarkYellow
}

# --- 2c-4: Chrome bookmark bar ON + iDezign.ai bookmark (current user) --------
# Edits the current user's Default Chrome profile so the bookmark bar shows and
# carries an iDezign.ai shortcut. Non-fatal if Chrome isn't installed / no profile.
# Chrome recomputes the Bookmarks checksum on next launch, so we drop the stale
# checksum after editing rather than trying to recompute the MD5 ourselves.
Write-Host "  [2c-4] Chrome bookmark bar + iDezign.ai bookmark..." -ForegroundColor DarkGray
try {
    $chromeUserData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
    $profileDir     = Join-Path $chromeUserData 'Default'
    if (Test-Path $chromeUserData) {
        if (-not (Test-Path $profileDir)) { New-Item -Path $profileDir -ItemType Directory -Force | Out-Null }

        # (a) Show the bookmark bar on all tabs (Preferences)
        $prefPath = Join-Path $profileDir 'Preferences'
        if (Test-Path $prefPath) {
            $pref = Get-Content -Raw -LiteralPath $prefPath | ConvertFrom-Json
        } else {
            $pref = [PSCustomObject]@{}
        }
        if (-not $pref.bookmark_bar) { $pref | Add-Member -NotePropertyName 'bookmark_bar' -NotePropertyValue ([PSCustomObject]@{}) -Force }
        $pref.bookmark_bar | Add-Member -NotePropertyName 'show_on_all_tabs' -NotePropertyValue $true -Force
        ($pref | ConvertTo-Json -Depth 100 -Compress) | Set-Content -LiteralPath $prefPath -Encoding UTF8

        # (b) Add an iDezign.ai bookmark to the bookmark bar (Bookmarks file)
        $bmPath = Join-Path $profileDir 'Bookmarks'
        if (Test-Path $bmPath) {
            $bm = Get-Content -Raw -LiteralPath $bmPath | ConvertFrom-Json
        } else {
            $bm = [PSCustomObject]@{
                roots = [PSCustomObject]@{
                    bookmark_bar = [PSCustomObject]@{ children = @(); name = 'Bookmarks bar'; type = 'folder' }
                    other        = [PSCustomObject]@{ children = @(); name = 'Other bookmarks'; type = 'folder' }
                    synced       = [PSCustomObject]@{ children = @(); name = 'Mobile bookmarks'; type = 'folder' }
                }
                version = 1
            }
        }
        $bar = $bm.roots.bookmark_bar
        if (-not $bar.children) { $bar | Add-Member -NotePropertyName 'children' -NotePropertyValue @() -Force }
        $already = @($bar.children | Where-Object { $_.url -like '*idezign.ai*' }).Count -gt 0
        if (-not $already) {
            $node = [PSCustomObject]@{ name = 'iDezign.ai'; type = 'url'; url = 'https://idezign.ai/' }
            $bar.children = @($bar.children) + $node
        }
        ($bm | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $bmPath -Encoding UTF8
        # Drop the stale top-level checksum so Chrome accepts the edited file
        $raw = Get-Content -Raw -LiteralPath $bmPath
        $raw = $raw -replace '("checksum"\s*:\s*")[0-9a-fA-F]*(")', '${1}${2}'
        Set-Content -LiteralPath $bmPath -Value $raw -Encoding UTF8

        Write-Host "    Bookmark bar enabled + iDezign.ai bookmark ensured (current user)." -ForegroundColor DarkGray
    } else {
        Write-Host "    (Chrome user-data folder not found - skipping.)" -ForegroundColor DarkGray
    }
} catch {
    Write-Host "    (Chrome bookmark step issue: $($_.Exception.Message))" -ForegroundColor DarkYellow
}

#endregion

#region --- 3. Ensure REPAIR admin account exists (always runs) --------------
# Standard service/repair account for technician access on imaged machines.
# Password is hardcoded - treat this script as a secret accordingly.
#
# Server behavior:
#   - DC: skip entirely (DCs have no local accounts)
#   - Member server: ASK Y/N (local admin accounts on servers bypass AD
#                    access control and create a different security calculus
#                    than on workstations - defer to operator judgment)

Write-Host "`n[Phase 3] Ensuring REPAIR admin account exists..." -ForegroundColor Green

$doRepair = $true

if ($IsDC) {
    Write-Host "  SKIPPED - this is a Domain Controller." -ForegroundColor Yellow
    Write-Host "  DCs do not have local accounts. Manage REPAIR access via AD instead." -ForegroundColor DarkGray
    $doRepair = $false
} elseif ($IsServer) {
    Write-Host "  Server detected. The REPAIR account stores a known password" -ForegroundColor Yellow
    Write-Host "  in the script. On a server (especially one with PHI/sensitive" -ForegroundColor Yellow
    Write-Host "  data), this bypasses domain-based access control." -ForegroundColor Yellow
    Write-Host ""
    $answer = Read-Host "  Create the local REPAIR account on this server anyway? (Y/N)  [default N]"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host "  REPAIR account creation skipped (operator chose N)." -ForegroundColor Yellow
        $doRepair = $false
    }
}

if ($doRepair) {

$repairName = 'REPAIR'
$repairPwd  = 'achtung'

# Look up the local Administrators group by well-known SID so this works
# regardless of system language (e.g. "Administradores" on Spanish Windows).
$adminGroupName = $null
try {
    $adminGroupName = (Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop).Name
} catch {
    Write-Host "  Could not resolve Administrators group by SID, falling back to 'Administrators'." -ForegroundColor DarkYellow
    $adminGroupName = 'Administrators'
}

# 3a. Ensure REPAIR exists AND always reset its password to the standard value.
# Per policy: the password is reset on EVERY run so a known-good credential is
# guaranteed on every imaged/serviced machine - even if the account already
# existed with a forgotten or drifted password.
$securePwd  = ConvertTo-SecureString $repairPwd -AsPlainText -Force
$repairUser = Get-LocalUser -Name $repairName -ErrorAction SilentlyContinue
if ($repairUser) {
    Write-Host "  REPAIR account exists - resetting password to standard value." -ForegroundColor DarkGray
    try {
        Set-LocalUser -Name $repairName -Password $securePwd -ErrorAction Stop
        # Re-assert the never-expire flags too, in case they drifted.
        Set-LocalUser -Name $repairName -PasswordNeverExpires $true -ErrorAction SilentlyContinue
        Set-LocalUser -Name $repairName -AccountNeverExpires       -ErrorAction SilentlyContinue
        Write-Host "  REPAIR password reset (never expires re-asserted)." -ForegroundColor DarkGray
    } catch {
        Write-Host "  ERROR resetting REPAIR password: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host "  REPAIR account not found - creating..." -ForegroundColor DarkGray
    try {
        New-LocalUser -Name $repairName `
                      -Password $securePwd `
                      -FullName $repairName `
                      -Description 'Service/repair admin account' `
                      -PasswordNeverExpires `
                      -AccountNeverExpires `
                      -ErrorAction Stop | Out-Null
        Write-Host "  REPAIR account created (password set, never expires)." -ForegroundColor DarkGray
    } catch {
        Write-Host "  ERROR creating REPAIR account: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 3b. Make sure REPAIR is in Administrators
try {
    $isAdmin = Get-LocalGroupMember -Group $adminGroupName -ErrorAction Stop |
               Where-Object { $_.Name -like "*\$repairName" -or $_.Name -eq $repairName }

    if ($isAdmin) {
        Write-Host "  REPAIR already in $adminGroupName group." -ForegroundColor DarkGray
    } else {
        Add-LocalGroupMember -Group $adminGroupName -Member $repairName -ErrorAction Stop
        Write-Host "  REPAIR added to $adminGroupName group." -ForegroundColor DarkGray
    }
} catch {
    Write-Host "  ERROR managing $adminGroupName group: $($_.Exception.Message)" -ForegroundColor Red
}

} # end of "if ($doRepair)"

#endregion

#region --- 4. Rename the user account (optional) ----------------------------

if ($doRenameUser) {
    Write-Host "`n[Phase 4] Renaming user account '$CurrentUser' -> '$newUserName'..." -ForegroundColor Green

    if ($IsDC) {
        Write-Host "  SKIPPED - this is a Domain Controller." -ForegroundColor Yellow
        Write-Host "  DCs use domain accounts only. Rename via AD Users & Computers." -ForegroundColor DarkGray
    }
    # Sanity check: don't try to rename the REPAIR account, even if somehow they match.
    elseif ($CurrentUser -eq 'REPAIR') {
        Write-Host "  Refusing to rename - current user IS the REPAIR account. Skipping." -ForegroundColor Yellow
    } else {
        try {
            Rename-LocalUser -Name $CurrentUser -NewName $newUserName -ErrorAction Stop
            Set-LocalUser   -Name $newUserName  -FullName $newUserName -ErrorAction SilentlyContinue
            Write-Host "  account renamed." -ForegroundColor DarkGray
            Write-Host "  NOTE: profile folder is still C:\Users\$CurrentUser (Windows doesn't rename it)." -ForegroundColor DarkYellow
        } catch {
            Write-Host "  ERROR renaming account: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  If this is a Microsoft Account-backed login, rename via Settings -> Accounts." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "`n[Phase 4] User rename: SKIPPED (per your choice)." -ForegroundColor DarkGray
}

#endregion

#region --- 5. Rename the computer (optional) --------------------------------

if ($doRenameComputer) {
    Write-Host "`n[Phase 5] Renaming computer '$env:COMPUTERNAME' -> '$newComputerName'..." -ForegroundColor Green

    # Server + domain-joined = high risk. Breaks AD trust, Kerberos SPNs,
    # certificates bound to hostname, GPO assignments, SQL connection strings,
    # etc. Require an explicit typed confirmation - not just Y.
    $proceedRename = $true
    if ($IsServer -and $ServerInfo.IsDomainJoined) {
        Write-Host ""
        Write-Host "  WARNING: This is a DOMAIN-JOINED SERVER." -ForegroundColor Yellow
        Write-Host "  Renaming will:" -ForegroundColor Yellow
        Write-Host "    - Break AD trust until re-joined" -ForegroundColor Yellow
        Write-Host "    - Invalidate Kerberos SPNs (SQL/IIS/SMB)" -ForegroundColor Yellow
        Write-Host "    - Break any cert bound to current hostname" -ForegroundColor Yellow
        Write-Host "    - Likely require manual cleanup in AD Users & Computers" -ForegroundColor Yellow
        Write-Host ""
        $typed = Read-Host "  Type 'CONFIRM' (all caps) to proceed, or anything else to skip"
        if ($typed -ne 'CONFIRM') {
            Write-Host "  Rename skipped (confirmation not typed)." -ForegroundColor Yellow
            $proceedRename = $false
        }
    }

    if ($proceedRename) {
        try {
            Rename-Computer -NewName $newComputerName -Force -ErrorAction Stop
            Write-Host "  computer renamed (takes effect on reboot)." -ForegroundColor DarkGray
        } catch {
            Write-Host "  ERROR renaming computer: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
} else {
    Write-Host "`n[Phase 5] Computer rename: SKIPPED (per your choice)." -ForegroundColor DarkGray
}

#endregion

#region --- 6. Wrap up + reboot ----------------------------------------------

if (Test-Path $StateFile) {
    Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  iDezign Cleanup Utility - all phases complete." -ForegroundColor Cyan
if ($doRenameComputer -or $doRenameUser -or $doInstallClaude) {
    Write-Host "  A reboot is required for renames / feature changes to take effect." -ForegroundColor Cyan
}
Write-Host ""
Write-Host "  REMINDER: before capturing your image, delete the staging dir:" -ForegroundColor Yellow
Write-Host "    Remove-Item C:\iDezign_Cleanup_Utility -Recurse -Force" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Stop transcript before the user-facing reboot prompt so the log file is
# closed and flushed even if the user takes a long time to answer.
try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }

if (Get-Command Invoke-RebootChoice -ErrorAction SilentlyContinue) {
    $reasonParts = @()
    if ($doRenameComputer) { $reasonParts += 'computer rename' }
    if ($doRenameUser)     { $reasonParts += 'user rename' }
    if ($doInstallClaude)  { $reasonParts += 'Claude install' }
    $reason = if ($reasonParts) { "Apply: $($reasonParts -join ', ')" } else { 'Finalize cleanup' }

    $rebooted = Invoke-RebootChoice `
        -Reason $reason `
        -CountdownSeconds 30 `
        -DeferMessage "Reboot manually before capturing the image. Also delete C:\iDezign_Cleanup_Utility first."

    if (-not $rebooted) {
        Write-Host "Reboot skipped. Remember to restart before capturing your image." -ForegroundColor Yellow
        Write-Host "And don't forget to delete C:\iDezign_Cleanup_Utility before capture." -ForegroundColor Yellow
    }
} else {
    # Fallback - module missing
    $reboot = Read-Host "Reboot now? (Y/N)"
    if ($reboot -match '^(y|yes)$') {
        Write-Host "Rebooting in 30 seconds. Save anything important..." -ForegroundColor Yellow
        shutdown /r /t 30 /c "iDezign Cleanup Utility complete. Rebooting."
    } else {
        Write-Host "Reboot skipped. Remember to restart before capturing your image." -ForegroundColor Yellow
        Write-Host "And don't forget to delete C:\iDezign_Cleanup_Utility before capture." -ForegroundColor Yellow
    }
}

#endregion
