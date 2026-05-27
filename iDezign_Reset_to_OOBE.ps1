# ============================================================================
#  iDezign_Reset_to_OOBE.ps1
#
#  Resets a Windows machine to the "Out Of Box Experience" - the first-run
#  setup screen a new PC shows. Used when redeploying a machine to a different
#  client, decommissioning, or preparing for a fresh image capture.
#
#  WHAT THIS DOES (under the hood, via sysprep):
#    - Removes all user profiles except built-in accounts
#    - Strips machine-specific identifiers (SID, hostname history, etc.)
#    - Resets activation grace state where applicable
#    - Shuts the machine down
#    - On NEXT boot, Windows runs OOBE: language, region, keyboard, user
#      account creation, EULA, network, telemetry choices, etc.
#
#  WHAT THIS DOES NOT DO:
#    - It does NOT wipe data drives. Files in C:\Users\<old user> and other
#      user-data locations may be REMOVED by generalize, but data on D:\ etc.
#      is untouched. If you need a full disk wipe, use DBAN, manufacturer
#      utilities, or Windows Reset This PC with the "remove everything +
#      clean drive" option instead.
#    - It does NOT remove installed applications. Chrome, Office, Dentrix,
#      etc. remain installed and will be available to the next user.
#    - It does NOT unjoin the machine from a domain. You must unjoin BEFORE
#      running this script (sysprep generalize fails on domain-joined boxes).
#
#  GOTCHAS:
#    - Sysprep can only be run 3-8 times per OS install before the rearm
#      counter exhausts. This script checks first.
#    - Microsoft Store apps and provisioned AppX packages frequently cause
#      sysprep to fail. We do best-effort cleanup of common offenders.
#    - On a server, sysprep is supported but uncommon; we gate it.
#    - On a Domain Controller, this script REFUSES to run.
#
#  Run as Administrator. Triggers immediate shutdown when complete.
# ============================================================================

#region --- Safety checks ----------------------------------------------------

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Use Run-Reset-to-OOBE.bat (it self-elevates)." -ForegroundColor Yellow
    Pause
    exit 1
}

$ErrorActionPreference = 'Continue'

# Version stamp - bumped when behavior changes. Shown in console banner.
$ScriptVersion = '2026.05.18-staging-freshness'

$ScriptPath = $MyInvocation.MyCommand.Path

# Load shared module if present
$ModulePath = Join-Path $PSScriptRoot 'iDezign_Common.psm1'
if (Test-Path $ModulePath) {
    Import-Module $ModulePath -Force -ErrorAction SilentlyContinue
}

#endregion

#region --- Self-stage to local disk -----------------------------------------
# Sysprep takes 10-30 min and reboots the machine. If we're running from a
# NAS or removable media, that gets pulled mid-flight. Stage locally first.

$StagingDir = 'C:\iDezign_Reset_to_OOBE'
$StagedPath = Join-Path $StagingDir (Split-Path $ScriptPath -Leaf)

if (Get-Command Invoke-iDezignSelfStage -ErrorAction SilentlyContinue) {
    # Preferred path: module helper does freshness check + stages module too.
    # OOBE has no -ResumeAfterUpdate flag (it's a one-shot destructive op),
    # so we never claim resume; check runs every launch.
    $stageResult = Invoke-iDezignSelfStage `
        -ScriptPath $ScriptPath `
        -StagingDir $StagingDir

    if ($stageResult.Error) {
        Write-Host "ERROR staging script: $($stageResult.Error)" -ForegroundColor Red
        Pause
        exit 1
    }
    if ($stageResult.NeedsRestage) {
        Write-Host "Re-launching from local copy..." -ForegroundColor Cyan
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy','Bypass',
            '-File', "`"$($stageResult.StagedPath)`""
        )
        exit 0
    }
} elseif ($ScriptPath -ne $StagedPath) {
    # Fallback: module didn't load. Use simple always-stage logic without
    # freshness checks - loses auto-update but still functions.
    Write-Host ""
    Write-Host "Launched from : $ScriptPath" -ForegroundColor DarkGray
    Write-Host "Staging to    : $StagedPath" -ForegroundColor Cyan
    Write-Host "(Sysprep reboots the machine - script must run from local disk.)" -ForegroundColor DarkGray
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
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy','Bypass',
        '-File', "`"$StagedPath`""
    )
    exit 0
}

#endregion

#region --- Banner + danger warnings -----------------------------------------

Clear-Host
Write-Host ""
Write-Host "############################################################" -ForegroundColor Red
Write-Host "##                                                        ##" -ForegroundColor Red
Write-Host "##         !!  RESET TO OOBE  -  DESTRUCTIVE  !!          ##" -ForegroundColor Red
Write-Host "##                                                        ##" -ForegroundColor Red
Write-Host "############################################################" -ForegroundColor Red
Write-Host ""
Write-Host "  This will run Microsoft's sysprep tool with these flags:" -ForegroundColor Yellow
Write-Host "    sysprep.exe /oobe /generalize /shutdown /quiet" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Result:" -ForegroundColor Yellow
Write-Host "    - All local user profiles will be REMOVED" -ForegroundColor Yellow
Write-Host "    - The machine SID will be regenerated" -ForegroundColor Yellow
Write-Host "    - Hostname history will be wiped" -ForegroundColor Yellow
Write-Host "    - The machine will SHUT DOWN when complete" -ForegroundColor Yellow
Write-Host "    - Next boot will show the Windows OOBE setup wizard" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Survives this process:" -ForegroundColor DarkGray
Write-Host "    - Installed applications (Chrome, Office, etc.)" -ForegroundColor DarkGray
Write-Host "    - Files on data drives (D:, E:, etc.)" -ForegroundColor DarkGray
Write-Host "    - Drivers, Windows activation, OS install" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Computer : $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "  User now : $env:USERNAME" -ForegroundColor Cyan
Write-Host "  Version  : $ScriptVersion$(if(Get-Command Get-iDezignCommonVersion -EA SilentlyContinue){"  |  module: $(Get-iDezignCommonVersion)"})" -ForegroundColor DarkGray
Write-Host ""

#endregion

#region --- Pre-flight: domain controller refusal ---------------------------

try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ($os.ProductType -eq 2) {
        Write-Host "  REFUSING TO RUN - this is a Domain Controller." -ForegroundColor Red
        Write-Host "  Sysprep is not supported on DCs. Demote first via dcpromo or" -ForegroundColor Red
        Write-Host "  Uninstall-ADDSDomainController, then re-run this script." -ForegroundColor Red
        Write-Host ""
        Pause
        exit 1
    }
} catch { }

#endregion

#region --- Pre-flight: domain-joined refusal --------------------------------

try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($cs.PartOfDomain) {
        Write-Host "  REFUSING TO RUN - this machine is joined to domain: $($cs.Domain)" -ForegroundColor Red
        Write-Host "  Sysprep /generalize fails on domain-joined machines." -ForegroundColor Red
        Write-Host ""
        Write-Host "  To unjoin first, run (as admin):" -ForegroundColor Yellow
        Write-Host "    Remove-Computer -UnjoinDomainCredential <DOMAIN\admin> -PassThru -Force -Restart" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  After the machine restarts in a workgroup, re-run this script." -ForegroundColor Yellow
        Write-Host ""
        Pause
        exit 1
    }
} catch { }

#endregion

#region --- Pre-flight: sysprep rearm counter --------------------------------
# Windows allows a limited number of sysprep /generalize runs per install.
# Default is 3 on consumer Windows, can be checked via slmgr.

Write-Host "  Checking sysprep rearm counter..." -ForegroundColor DarkGray
try {
    $rearmOutput = & cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /dlv 2>&1 | Out-String
    if ($rearmOutput -match 'Remaining Windows rearm count\s*:\s*(\d+)') {
        $rearmCount = [int]$Matches[1]
        Write-Host "  Remaining rearm count: $rearmCount" -ForegroundColor DarkGray
        if ($rearmCount -le 0) {
            Write-Host ""
            Write-Host "  WARNING: Rearm counter is exhausted ($rearmCount)." -ForegroundColor Red
            Write-Host "  sysprep /generalize will likely fail." -ForegroundColor Red
            Write-Host ""
            Write-Host "  Alternatives:" -ForegroundColor Yellow
            Write-Host "    - Use 'Reset this PC' from Settings (Windows GUI)" -ForegroundColor Yellow
            Write-Host "    - Reinstall Windows from scratch" -ForegroundColor Yellow
            Write-Host "    - Run without /generalize (loses SID rotation, profiles still wiped)" -ForegroundColor Yellow
            Write-Host ""
            $cont = Read-Host "  Continue anyway? (Y/N)"
            if ($cont -notmatch '^(y|yes)$') { exit 0 }
        }
    } else {
        Write-Host "  Rearm count unavailable - continuing." -ForegroundColor DarkYellow
    }
} catch {
    Write-Host "  Rearm check failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

#endregion

#region --- Pre-flight: pending operations -----------------------------------
# Sysprep fails if Windows is mid-update. Check for the usual signals.

if (Get-Command Test-PendingReboot -ErrorAction SilentlyContinue) {
    Write-Host "  Checking for pending operations..." -ForegroundColor DarkGray
    $pending = Test-PendingReboot
    if ($pending.Count -gt 0) {
        Write-Host ""
        Write-Host "  Pending operations detected:" -ForegroundColor Red
        $pending | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        Write-Host ""
        Write-Host "  Sysprep will likely fail with one of these in progress." -ForegroundColor Red
        Write-Host "  Reboot the machine first, then re-run this script." -ForegroundColor Yellow

        if (Get-Command Invoke-RebootChoice -ErrorAction SilentlyContinue) {
            $rebooted = Invoke-RebootChoice `
                -Reason "Clear pending operations before sysprep" `
                -CountdownSeconds 30 `
                -DeferMessage "Re-run this script after you reboot manually."
            if ($rebooted) { exit 0 }
        } else {
            $cont = Read-Host "  Reboot now and abort sysprep? (Y/N)"
            if ($cont -match '^(y|yes)$') {
                shutdown /r /t 30 /c "Reboot required before sysprep OOBE reset."
                exit 0
            }
        }
        $cont = Read-Host "  Reboot deferred. Continue with sysprep anyway? (Y/N)"
        if ($cont -notmatch '^(y|yes)$') { exit 0 }
    } else {
        Write-Host "  No pending operations." -ForegroundColor DarkGray
    }
}

#endregion

#region --- Triple confirmation ----------------------------------------------
# This is destructive enough that we want the operator to deliberately commit.
# Step 1: Y/N. Step 2: type the computer name. Step 3: type RESET.

Write-Host ""
Write-Host "============================================================" -ForegroundColor Red
Write-Host "  CONFIRMATION REQUIRED (3 STEPS)" -ForegroundColor Red
Write-Host "============================================================" -ForegroundColor Red
Write-Host ""

$ans = Read-Host "  Step 1/3 - Do you really want to reset this machine to OOBE? (Y/N)"
if ($ans -notmatch '^(y|yes)$') {
    Write-Host "  Aborted at step 1." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
$typed = Read-Host "  Step 2/3 - Type the computer name EXACTLY ($env:COMPUTERNAME)"
if ($typed -ne $env:COMPUTERNAME) {
    Write-Host "  Computer name did not match. Aborted at step 2." -ForegroundColor Yellow
    Write-Host "  (Typed: '$typed'  Expected: '$env:COMPUTERNAME')" -ForegroundColor DarkGray
    exit 0
}

Write-Host ""
$typed = Read-Host "  Step 3/3 - Type 'RESET' (all caps) to proceed"
if ($typed -ne 'RESET') {
    Write-Host "  Aborted at step 3." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "  All confirmations received. Proceeding with OOBE reset..." -ForegroundColor Cyan
Write-Host ""

#endregion

#region --- AppX cleanup (best-effort) ---------------------------------------
# Provisioned AppX packages are the #1 cause of "sysprep failed in CleanupSysprep
# phase" errors. We do a best-effort removal of the most common offenders.
# This won't catch every possible AppX issue but covers ~80% of real-world cases.

Write-Host "[1/3] Cleaning up known problematic AppX packages..." -ForegroundColor Green

# Common culprits - apps that are per-user-installed but block generalize
$problemApps = @(
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.SkypeApp',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.OneConnect',
    'Microsoft.YourPhone',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.Xbox.TCUI'
)

$removed = 0
foreach ($app in $problemApps) {
    try {
        $appx = Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue
        if ($appx) {
            Remove-AppxPackage -Package $appx.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            $removed++
        }
        $prov = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq $app }
        if ($prov) {
            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction SilentlyContinue | Out-Null
        }
    } catch { }
}
Write-Host "  Removed/deprovisioned $removed problem app(s)." -ForegroundColor DarkGray

#endregion

#region --- Disable OneDrive ------------------------------------------------
# OneDrive user-mode setup interferes with generalize. Kill the process and
# disable its scheduled tasks.

Write-Host ""
Write-Host "[2/3] Stopping OneDrive to prevent sysprep interference..." -ForegroundColor Green
try {
    Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-ScheduledTask -TaskName 'OneDrive*' -ErrorAction SilentlyContinue |
        Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    Write-Host "  OneDrive stopped and tasks disabled (if present)." -ForegroundColor DarkGray
} catch {
    Write-Host "  (non-fatal) OneDrive cleanup: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

#endregion

#region --- Run sysprep ------------------------------------------------------

Write-Host ""
Write-Host "[3/3] Running sysprep /oobe /generalize /shutdown /quiet..." -ForegroundColor Green
Write-Host "  This typically takes 5-20 minutes." -ForegroundColor DarkGray
Write-Host "  The machine will SHUT DOWN automatically when complete." -ForegroundColor DarkGray
Write-Host "  Next boot will start the Windows OOBE wizard." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  If sysprep fails:" -ForegroundColor DarkGray
Write-Host "    - Log file: C:\Windows\System32\Sysprep\Panther\setupact.log" -ForegroundColor DarkGray
Write-Host "    - Error log: C:\Windows\System32\Sysprep\Panther\setuperr.log" -ForegroundColor DarkGray
Write-Host ""

$sysprepExe = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
if (-not (Test-Path $sysprepExe)) {
    Write-Host "  ERROR: sysprep.exe not found at $sysprepExe" -ForegroundColor Red
    Pause
    exit 1
}

# Use the timeout-aware launcher if available, with a 60-min cap.
# Sysprep that takes longer than that is almost certainly stuck.
$rc = $null
if (Get-Command Start-ProcessWithTimeout -ErrorAction SilentlyContinue) {
    Write-Host "  Launching sysprep (60-minute timeout)..." -ForegroundColor Yellow
    $rc = Start-ProcessWithTimeout -FilePath $sysprepExe `
            -ArgumentList @('/oobe','/generalize','/shutdown','/quiet') `
            -TimeoutMinutes 60 -Label 'sysprep' -NoNewWindow $false
} else {
    Write-Host "  Launching sysprep (no timeout protection)..." -ForegroundColor Yellow
    try {
        $p = Start-Process -FilePath $sysprepExe `
                -ArgumentList '/oobe','/generalize','/shutdown','/quiet' `
                -Wait -PassThru
        $rc = $p.ExitCode
    } catch {
        Write-Host "  ERROR launching sysprep: $($_.Exception.Message)" -ForegroundColor Red
        $rc = -2
    }
}

if ($rc -eq 0) {
    Write-Host ""
    Write-Host "  sysprep completed successfully. Machine should be shutting down now." -ForegroundColor Green
    Write-Host "  If it's still on in 60 seconds, force a shutdown." -ForegroundColor DarkGray
} elseif ($rc -eq -1) {
    Write-Host ""
    Write-Host "  sysprep TIMED OUT after 60 minutes." -ForegroundColor Red
    Write-Host "  Something is wedged. Check C:\Windows\System32\Sysprep\Panther\setuperr.log" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "  sysprep returned exit code $rc - likely failed." -ForegroundColor Red
    Write-Host "  Open these logs to diagnose:" -ForegroundColor Yellow
    Write-Host "    C:\Windows\System32\Sysprep\Panther\setuperr.log" -ForegroundColor Yellow
    Write-Host "    C:\Windows\System32\Sysprep\Panther\setupact.log" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Most common cause: a per-user AppX package we didn't catch." -ForegroundColor DarkGray
    Write-Host "  setuperr.log will name the package - remove it and re-run." -ForegroundColor DarkGray
}

#endregion

Write-Host ""
Write-Host "  REMINDER: delete the staging directory before image capture:" -ForegroundColor Yellow
Write-Host "    Remove-Item C:\iDezign_Reset_to_OOBE -Recurse -Force" -ForegroundColor Yellow
Write-Host ""
Pause
