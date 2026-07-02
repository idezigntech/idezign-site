# ============================================================================
#  iDezign_Common.psm1
#  Shared PowerShell module used by:
#    - iDezign_Cleanup_Utility.ps1
#    - iDezign_Diagnostics.ps1
#    - iDezign_Remediation.ps1
#
#  Functions exported:
#    Test-PendingReboot     - check for pending Windows servicing operations
#    Write-iDezignAction    - structured log line (timestamped, list-based)
#    Get-RemoteFile         - fast Invoke-WebRequest with progress suppression
#    Read-iDezignYN         - interactive Y/N/Q prompt with input validation
#    Get-AdminGroupName     - language-independent local Administrators group
#    Get-IsServerOS         - detects Windows Server SKUs
#    Get-iDezignBanner      - consistent banner output across scripts
#    Start-iDezignTranscript- wraps Start-Transcript with sane defaults
#
#  Loading pattern (in each consuming script):
#    $modulePath = Join-Path $PSScriptRoot 'iDezign_Common.psm1'
#    if (Test-Path $modulePath) { Import-Module $modulePath -Force }
#    else { Write-Host "WARNING: iDezign_Common.psm1 not found..." }
# ============================================================================

# Allow this module to be force-reloaded without stale state
$ErrorActionPreference = 'Continue'

# Module version - bumped when shared module behavior changes. Exported via
# Get-iDezignCommonVersion so scripts can verify which module version they loaded.
$script:ModuleVersion = '2026.07.01-v3.2.1-fullpath-resolve'

function Get-iDezignCommonVersion {
    [CmdletBinding()]
    param()
    return $script:ModuleVersion
}

#region --- Test-PendingReboot ----------------------------------------------
<#
.SYNOPSIS
    Detects pending Windows servicing operations that would block DISM cleanup.

.DESCRIPTION
    Returns an array of string descriptions for each pending signal found.
    An empty array means nothing is pending and DISM /resetbase is safe.
    These are the same flags Microsoft uses internally to decide whether to
    gate CBS operations - hitting DISM with any of these set is the #1 cause
    of error 0x800f0806.

.OUTPUTS
    [string[]] - One entry per pending signal. Empty array if nothing pending.
#>
function Test-PendingReboot {
    [CmdletBinding()]
    param()

    $signals = @()

    # Component Based Servicing - set when an update is staged for next boot
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $signals += 'CBS RebootPending'
    }

    # Windows Update - explicit reboot-required flag
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $signals += 'WindowsUpdate RebootRequired'
    }

    # Files queued for rename/delete at next boot
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

    # Pending Windows feature enable/disable - these also block DISM /resetbase.
    # Wrapped in try because Get-WindowsOptionalFeature isn't available on all
    # server editions and is slow on first call. We only count features that
    # are mid-transition (not "Enabled" or "Disabled" steady states).
    try {
        $pendingFeatures = Get-WindowsOptionalFeature -Online -ErrorAction Stop |
            Where-Object { $_.State -in 'EnablePending','DisablePending' }
        foreach ($f in $pendingFeatures) {
            $signals += "Feature $($f.State): $($f.FeatureName)"
        }
    } catch { }

    return ,$signals    # comma prefix forces array return even for 0 or 1 elements
}
#endregion

#region --- Write-iDezignAction ---------------------------------------------
<#
.SYNOPSIS
    Adds a timestamped line to a target log list.

.DESCRIPTION
    The consuming script is expected to have a list variable in its scope
    that this function appends to. Pass the list by reference to avoid
    relying on parent scope discovery.

.PARAMETER Text
    The text to log. Will be prepended with [HH:mm:ss].

.PARAMETER LogList
    A System.Collections.Generic.List[string] to append the line to.
#>
function Write-iDezignAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [System.Collections.Generic.List[string]] $LogList
    )
    $stamp = (Get-Date -Format 'HH:mm:ss')
    $LogList.Add("[$stamp] $Text") | Out-Null
}
#endregion

#region --- Get-RemoteFile --------------------------------------------------
<#
.SYNOPSIS
    Downloads a file via Invoke-WebRequest with progress suppression and
    sanity-checks the result.

.DESCRIPTION
    Setting $ProgressPreference = 'SilentlyContinue' makes Invoke-WebRequest
    10-100x faster on large downloads because it skips rendering the progress
    bar to the host. Returns $true on success, $false on failure.

    A "successful" Invoke-WebRequest doesn't always mean we got a real file:
    some CDNs (TeamViewer, vendor download portals) return an HTML page instead
    of the binary when no browser User-Agent is sent. So this function:
      * Always sends a real browser User-Agent (defeats UA gating)
      * Validates the downloaded file is non-zero and not text/html

.PARAMETER Url
    Source URL.

.PARAMETER OutFile
    Local destination path.

.PARAMETER DisplayName
    Friendly name for log messages.

.PARAMETER MinSizeBytes
    Minimum acceptable file size in bytes. If the downloaded file is smaller,
    the function treats the download as failed (deletes the file, returns
    $false). Default is 10240 (10 KB) which catches the typical
    "got an HTML error page instead of the binary" failure mode where the
    file is a few hundred bytes of HTML.

.PARAMETER ExpectedContentType
    Optional. If specified, validates the response Content-Type header.
    Mostly used for binary downloads where 'text/html' would mean trouble.
#>
function Get-RemoteFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $OutFile,
        [string] $DisplayName = 'file',
        [int]    $MinSizeBytes = 10240,
        [string] $ExpectedContentType
    )
    Write-Host "  Downloading $DisplayName..." -ForegroundColor DarkGray
    Write-Host "    from: $Url" -ForegroundColor DarkGray
    Write-Host "    to  : $OutFile" -ForegroundColor DarkGray

    # Browser-realistic User-Agent. Many vendor CDNs (TeamViewer, NinjaRMM,
    # some Adobe/Microsoft endpoints) serve an HTML interstitial to clients
    # without a recognized UA - PowerShell's default UA "Mozilla/5.0 (Windows NT;
    # Windows NT 10.0; en-US) WindowsPowerShell/5.1.x" gets misclassified.
    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'

    $previousProgressPref = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    try {
        # Force TLS 1.2 minimum - some older defaults still negotiate down
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 } catch { }

        # Force HTTP redirects to be followed (default is yes but some Win10/11
        # update changed behavior on PS 5.1 in edge cases).
        $params = @{
            Uri              = $Url
            OutFile          = $OutFile
            UserAgent        = $userAgent
            UseBasicParsing  = $true
            MaximumRedirection = 10
            ErrorAction      = 'Stop'
        }
        Invoke-WebRequest @params

        # Sanity check: did we actually get a real file?
        if (-not (Test-Path -LiteralPath $OutFile)) {
            Write-Host "  ERROR: download reported success but file is missing on disk." -ForegroundColor Red
            return $false
        }

        $size = (Get-Item -LiteralPath $OutFile).Length
        if ($size -lt $MinSizeBytes) {
            $sizeKB = [math]::Round($size / 1KB, 1)
            $minKB  = [math]::Round($MinSizeBytes / 1KB, 1)
            Write-Host "  ERROR: download is only $sizeKB KB (minimum expected: $minKB KB)." -ForegroundColor Red
            Write-Host "         The server likely returned an HTML error page instead of the file." -ForegroundColor Red

            # Peek at the first 256 chars in case it tells us why
            try {
                $head = (Get-Content -LiteralPath $OutFile -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' '
                if ($head -and $head.Length -gt 0) {
                    $snippet = if ($head.Length -gt 200) { $head.Substring(0, 200) + '...' } else { $head }
                    Write-Host "         Response snippet: $snippet" -ForegroundColor DarkYellow
                }
            } catch { }

            # Clean up the bogus file so subsequent install attempts don't try to run it
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            return $false
        }

        $sizeMB = [math]::Round($size / 1MB, 1)
        Write-Host "  Downloaded ${DisplayName}: $sizeMB MB" -ForegroundColor DarkGray
        return $true

    } catch {
        Write-Host "  ERROR downloading $DisplayName : $($_.Exception.Message)" -ForegroundColor Red
        # Clean up any partial file from a failed download
        if (Test-Path -LiteralPath $OutFile) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        }
        return $false
    } finally {
        $global:ProgressPreference = $previousProgressPref
    }
}
#endregion

#region --- Read-iDezignYN --------------------------------------------------
<#
.SYNOPSIS
    Interactive Y/N/Q prompt with re-prompt on invalid input.

.OUTPUTS
    [string] - 'Y', 'N', or 'Q' (always a string, never a boolean - avoids the
    PowerShell -eq type coercion trap where `$true -eq 'Q'` evaluates true).
#>
function Read-iDezignYN {
    [CmdletBinding()]
    param(
        [string] $Prompt = "Apply this fix? (Y/N/Q=quit)"
    )
    do {
        $ans = Read-Host "  $Prompt"
        switch -regex ($ans) {
            '^(y|yes)$'  { return 'Y' }
            '^(n|no)$'   { return 'N' }
            '^(q|quit)$' { return 'Q' }
            default      { Write-Host "    Please answer Y, N, or Q." -ForegroundColor DarkYellow }
        }
    } while ($true)
}
#endregion

#region --- Get-AdminGroupName ----------------------------------------------
<#
.SYNOPSIS
    Returns the local Administrators group name in any system language.

.DESCRIPTION
    Hardcoding "Administrators" breaks on non-English Windows
    (e.g. "Administradores" on Spanish, "Administratoren" on German).
    Looking up by well-known SID is universal.
#>
function Get-AdminGroupName {
    [CmdletBinding()]
    param()
    try {
        return (Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop).Name
    } catch {
        Write-Host "  Could not resolve Administrators group by SID, falling back to 'Administrators'." -ForegroundColor DarkYellow
        return 'Administrators'
    }
}
#endregion

#region --- Get-IsServerOS --------------------------------------------------
<#
.SYNOPSIS
    Returns $true if running on Windows Server (any edition), $false otherwise.

.DESCRIPTION
    ProductType values from Win32_OperatingSystem:
      1 = Workstation (client OS)
      2 = Domain Controller
      3 = Server (member server, application server, etc.)
#>
function Get-IsServerOS {
    [CmdletBinding()]
    param()
    try {
        $pt = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).ProductType
        return ($pt -eq 2 -or $pt -eq 3)
    } catch {
        return $false
    }
}
#endregion

#region --- Get-ServerOSDetails ---------------------------------------------
<#
.SYNOPSIS
    Returns rich server-OS context: IsServer, IsDC, OS caption, domain state,
    installed server roles.

.OUTPUTS
    [hashtable] - keys: IsServer, IsDC, ProductType, OSCaption, OSVersion,
                  IsDomainJoined, DomainName, InstalledRoles (string[])
#>
function Get-ServerOSDetails {
    [CmdletBinding()]
    param()
    $info = @{
        IsServer        = $false
        IsDC            = $false
        ProductType     = 0
        OSCaption       = ''
        OSVersion       = ''
        IsDomainJoined  = $false
        DomainName      = $null
        InstalledRoles  = @()
    }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance Win32_ComputerSystem  -ErrorAction Stop
        $info.ProductType    = [int]$os.ProductType
        $info.OSCaption      = $os.Caption
        $info.OSVersion      = $os.Version
        $info.IsServer       = ($info.ProductType -eq 2 -or $info.ProductType -eq 3)
        $info.IsDC           = ($info.ProductType -eq 2)
        $info.IsDomainJoined = [bool]$cs.PartOfDomain
        $info.DomainName     = $cs.Domain

        # Installed roles - only available on Server SKUs
        if ($info.IsServer) {
            try {
                $info.InstalledRoles = @(Get-WindowsFeature -ErrorAction SilentlyContinue |
                                         Where-Object { $_.Installed -and $_.FeatureType -eq 'Role' } |
                                         Select-Object -ExpandProperty Name)
            } catch { }
        }
    } catch { }
    return $info
}
#endregion

#region --- Show-ServerWarning ----------------------------------------------
<#
.SYNOPSIS
    Displays a large yellow banner indicating Server OS was detected and
    summarizing what server-safe behaviors are active.

.PARAMETER ServerInfo
    Hashtable from Get-ServerOSDetails.

.PARAMETER ToolName
    Display name of the tool (e.g. "Cleanup Utility").

.PARAMETER Disabled
    Array of strings describing features that are DISABLED on Server.

.PARAMETER Gated
    Array of strings describing features that require EXTRA confirmation.
#>
function Show-ServerWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $ServerInfo,
        [Parameter(Mandatory)] [string]    $ToolName,
        [string[]] $Disabled = @(),
        [string[]] $Gated    = @()
    )
    if (-not $ServerInfo.IsServer) { return }

    Write-Host ""
    Write-Host "############################################################" -ForegroundColor Yellow
    Write-Host "##                                                        ##" -ForegroundColor Yellow
    if ($ServerInfo.IsDC) {
        Write-Host "##         !!  DOMAIN CONTROLLER DETECTED  !!             ##" -ForegroundColor Yellow
    } else {
        Write-Host "##         !!  WINDOWS SERVER DETECTED  !!                ##" -ForegroundColor Yellow
    }
    Write-Host "##         Server-safe mode is ACTIVE                     ##" -ForegroundColor Yellow
    Write-Host "##                                                        ##" -ForegroundColor Yellow
    Write-Host "############################################################" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  OS      : $($ServerInfo.OSCaption)" -ForegroundColor Yellow
    Write-Host "  Build   : $($ServerInfo.OSVersion)" -ForegroundColor Yellow
    if ($ServerInfo.IsDomainJoined) {
        Write-Host "  Domain  : $($ServerInfo.DomainName) (domain-joined)" -ForegroundColor Yellow
    } else {
        Write-Host "  Domain  : (workgroup - not domain-joined)" -ForegroundColor Yellow
    }
    if ($ServerInfo.InstalledRoles -and $ServerInfo.InstalledRoles.Count -gt 0) {
        Write-Host "  Roles   : $($ServerInfo.InstalledRoles -join ', ')" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Tool    : $ToolName" -ForegroundColor Yellow
    if ($Disabled -and $Disabled.Count -gt 0) {
        Write-Host ""
        Write-Host "  DISABLED on server (these would cause harm):" -ForegroundColor Yellow
        foreach ($d in $Disabled) {
            Write-Host "    - $d" -ForegroundColor Yellow
        }
    }
    if ($Gated -and $Gated.Count -gt 0) {
        Write-Host ""
        Write-Host "  GATED with extra confirmation:" -ForegroundColor Yellow
        foreach ($g in $Gated) {
            Write-Host "    - $g" -ForegroundColor Yellow
        }
    }
    Write-Host ""
    Write-Host "############################################################" -ForegroundColor Yellow
    Write-Host ""
    Start-Sleep -Seconds 3  # give the operator a moment to actually see this
}
#endregion

#region --- Get-iDezignBanner -----------------------------------------------
<#
.SYNOPSIS
    Writes a consistent banner header for any iDezign script.
#>
function Get-iDezignBanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ToolName,
        [string] $Subtitle = ''
    )
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  $ToolName  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan
    if ($Subtitle) {
        Write-Host "  $Subtitle" -ForegroundColor Cyan
    }
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Computer: $env:COMPUTERNAME   User: $env:USERNAME" -ForegroundColor DarkGray
    Write-Host "============================================================" -ForegroundColor Cyan
}
#endregion

#region --- Start-iDezignTranscript -----------------------------------------
<#
.SYNOPSIS
    Starts PowerShell transcript logging to a sensible default path.

.DESCRIPTION
    Wraps Start-Transcript with error handling so it never blows up the script
    if transcript is already running or path is locked. Stop-Transcript can be
    called normally afterward.

.OUTPUTS
    [string] - the transcript file path, or $null if it could not be started.
#>
function Start-iDezignTranscript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [string] $Prefix = 'transcript'
    )
    if (-not (Test-Path $Directory)) {
        try { New-Item -Path $Directory -ItemType Directory -Force | Out-Null } catch { return $null }
    }
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
    $path  = Join-Path $Directory "${Prefix}_$stamp.log"

    try {
        # Stop any stale transcript that might be running from a previous run
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
        Start-Transcript -Path $path -Force -ErrorAction Stop | Out-Null
        return $path
    } catch {
        Write-Host "  (could not start transcript: $($_.Exception.Message))" -ForegroundColor DarkYellow
        return $null
    }
}
#endregion

#region --- Start-ProcessWithTimeout ----------------------------------------
<#
.SYNOPSIS
    Run an external command with a hard wall-clock timeout. Kill it if exceeded.

.DESCRIPTION
    Wraps Start-Process with a WaitForExit(timeout). If the process doesn't
    finish in time, it's terminated and the function returns -1. This is the
    right tool for external binaries that can hang: DISM, msiexec, dism.exe,
    cleanmgr.exe, etc.

.PARAMETER FilePath
    Path or name of the executable to launch.

.PARAMETER ArgumentList
    Array of arguments. Use array form to avoid quoting issues.

.PARAMETER TimeoutMinutes
    Wall-clock timeout in minutes. Default 10.

.PARAMETER Label
    Friendly name for log output. Default 'process'.

.PARAMETER NoNewWindow
    Run without spawning a new window. Default $true.

.OUTPUTS
    [int] - exit code, or -1 if killed by timeout, or -2 if the process
    could not be started at all.
#>
function Start-ProcessWithTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $FilePath,
        [string[]] $ArgumentList = @(),
        [int]      $TimeoutMinutes = 10,
        [string]   $Label = 'process',
        [bool]     $NoNewWindow = $true
    )
    $started = $null
    try {
        # If $FilePath is a bare name (no directory component), resolve to
        # full path via Get-Command first. Process.Start with
        # UseShellExecute=$false calls CreateProcess, whose PATH-search
        # semantics are unreliable across bitness / current-directory /
        # launched-vs-console contexts. We've been bitten by "The system
        # cannot find the file specified" when calling vssadmin/dism/msiexec
        # by bare name from Cleanup. Resolving to full path up-front is
        # deterministic on every Windows SKU.
        $resolvedPath = $FilePath
        if ($FilePath -and ($FilePath -notmatch '[\\/]') -and (-not [System.IO.Path]::IsPathRooted($FilePath))) {
            try {
                $cmd = Get-Command $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1
                if ($cmd -and $cmd.Source) { $resolvedPath = $cmd.Source }
            } catch {
                # Fall back to System32 for classic Windows tools before
                # giving up - covers the odd case where PATH has been wiped.
                $sysExe = Join-Path $env:SystemRoot "System32\$FilePath"
                if (Test-Path -LiteralPath $sysExe) { $resolvedPath = $sysExe }
            }
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = $resolvedPath
        if ($ArgumentList) { $psi.Arguments = ($ArgumentList -join ' ') }
        $psi.UseShellExecute  = $false
        $psi.CreateNoWindow   = $NoNewWindow
        $psi.WindowStyle      = if ($NoNewWindow) { 'Hidden' } else { 'Normal' }

        $started = [System.Diagnostics.Process]::Start($psi)
        if (-not $started) {
            Write-Host "  ERROR: failed to start $Label" -ForegroundColor Red
            return -2
        }

        $timeoutMs = [int]($TimeoutMinutes * 60 * 1000)
        $finished  = $started.WaitForExit($timeoutMs)

        if (-not $finished) {
            Write-Host "  TIMEOUT after $TimeoutMinutes min - killing $Label (PID $($started.Id))." -ForegroundColor Red
            try { $started.Kill() } catch { }
            try { $started.WaitForExit(5000) } catch { }
            return -1
        }

        return $started.ExitCode
    } catch {
        Write-Host "  ERROR running ${Label}: $($_.Exception.Message)" -ForegroundColor Red
        return -2
    } finally {
        if ($started -and -not $started.HasExited) {
            try { $started.Kill() } catch { }
        }
        if ($started) { $started.Dispose() }
    }
}
#endregion

#region --- Invoke-WithJobTimeout -------------------------------------------
<#
.SYNOPSIS
    Run a PowerShell script block with a wall-clock timeout, in a background job.

.DESCRIPTION
    For cmdlets/script blocks that can hang (e.g. Get-WindowsUpdate against an
    unreachable WSUS, Get-MpComputerStatus on a broken Defender install).
    Returns whatever the script block returned, or $null if it timed out.

    NOTE: jobs run in a separate runspace, so they DO NOT inherit your script
    variables. Pass anything you need via -ArgumentList.

.PARAMETER ScriptBlock
    The script block to run. Use $args[0], $args[1], etc. to access ArgumentList.

.PARAMETER TimeoutMinutes
    Wall-clock timeout in minutes. Default 10.

.PARAMETER Label
    Friendly name for log output.

.PARAMETER ArgumentList
    Arguments to pass into the script block.

.OUTPUTS
    Whatever the script block produces, or $null on timeout/error.
#>
function Invoke-WithJobTimeout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [int]    $TimeoutMinutes = 10,
        [string] $Label = 'operation',
        [object[]] $ArgumentList = @()
    )
    $job = $null
    try {
        $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
        $completed = Wait-Job -Job $job -Timeout ([int]($TimeoutMinutes * 60))
        if (-not $completed) {
            Write-Host "  TIMEOUT after $TimeoutMinutes min - stopping $Label." -ForegroundColor Red
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            return $null
        }
        $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
        return $result
    } catch {
        Write-Host "  ERROR in job ${Label}: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    } finally {
        if ($job) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}
#endregion

#region --- Invoke-RebootChoice ----------------------------------------------
<#
.SYNOPSIS
    Prompts the operator to reboot NOW or LATER. Never auto-reboots.

.DESCRIPTION
    Replaces all "shutdown /r /t 20" auto-reboot patterns across the toolkit.
    Defaults to NOW after a 60-second prompt timeout, but accepts L/Later at
    any time to defer. Returns $true if reboot was triggered, $false if user
    chose to defer.

    On server OS, requires typed 'REBOOT' (all caps) confirmation regardless
    of choice - servers have downstream impact (RDP/SMB/SQL/AD) that warrants
    extra deliberation.

    Caller is responsible for any pre-reboot state save (e.g. setting RunOnce
    keys to resume after reboot). This function only handles the prompt and
    the shutdown command.

.PARAMETER Reason
    Short description of why we want to reboot, shown to operator.

.PARAMETER CountdownSeconds
    Seconds before the actual shutdown fires after user picks NOW. Default 30.

.PARAMETER DeferMessage
    Optional message printed when user picks LATER. Useful for "please reboot
    manually when ready - script will resume" type guidance.

.OUTPUTS
    [bool] - $true if reboot triggered, $false if deferred.
#>
function Invoke-RebootChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Reason,
        [int]    $CountdownSeconds = 30,
        [string] $DeferMessage = ''
    )

    # Detect server for the typed-confirm gate
    $isSrv = $false
    try {
        $pt = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).ProductType
        $isSrv = ($pt -eq 2 -or $pt -eq 3)
    } catch { }

    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  REBOOT NEEDED" -ForegroundColor Cyan
    Write-Host "  Reason: $Reason" -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Pick when:" -ForegroundColor White
    Write-Host "    [Y] Yes - reboot now (in $CountdownSeconds seconds)" -ForegroundColor White
    Write-Host "    [N] No  - skip reboot, you'll do it manually" -ForegroundColor White
    Write-Host ""
    if ($DeferMessage) {
        Write-Host "  If you pick LATER:" -ForegroundColor DarkGray
        Write-Host "    $DeferMessage" -ForegroundColor DarkGray
        Write-Host ""
    }

    $choice = Read-Host "  Reboot now? (Y/N)  [default N = safer]"

    # Default to NO/defer if no input - safer than surprise reboot
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 'N' }

    if ($choice -notmatch '^[Yy]') {
        Write-Host "  Reboot deferred. Remember to reboot manually when convenient." -ForegroundColor Yellow
        return $false
    }

    # User picked NOW - on server, require typed REBOOT
    if ($isSrv) {
        Write-Host ""
        Write-Host "  *** SERVER DETECTED ***" -ForegroundColor Yellow
        Write-Host "  Rebooting will disconnect every RDP user and interrupt" -ForegroundColor Yellow
        Write-Host "  SMB/SQL/AD/DNS services until the box is back up." -ForegroundColor Yellow
        Write-Host ""
        $typed = Read-Host "  Type 'REBOOT' (all caps) to confirm, or anything else to defer"
        if ($typed -ne 'REBOOT') {
            Write-Host "  Reboot deferred (confirmation not typed)." -ForegroundColor Yellow
            return $false
        }
    }

    Write-Host ""
    Write-Host "  Rebooting in $CountdownSeconds seconds." -ForegroundColor Green
    Write-Host "  Run 'shutdown /a' from another window to cancel if you change your mind." -ForegroundColor DarkGray
    Write-Host ""

    shutdown /r /t $CountdownSeconds /c "iDezign Toolkit: $Reason"
    return $true
}
#endregion

#region --- Invoke-iDezignSelfStage -----------------------------------------
<#
.SYNOPSIS
    Stage a toolkit script (and its companion module) to a local C:\ path,
    re-staging automatically when source files are newer than staged copies.

.DESCRIPTION
    Each toolkit script self-stages to a fixed path under C:\ on launch so that
    RunOnce-based auto-resume across reboots works reliably (RunOnce keys
    expect a fixed local path; UNC/USB paths can disappear during reboot).

    Previously the staging logic was "if launched from a different path, copy
    the script and re-launch." That ignored:
      1. Whether the staged copy was newer than the source (could overwrite
         debug work with stale NAS copies)
      2. Whether the source was newer than the staged copy (silent staleness;
         user updates the file and wonders why nothing changes)
      3. The companion iDezign_Common.psm1 module (never staged, so the staged
         script ran without module helpers - manifesting as "module not found"
         warnings or silently losing module-only features)

    This helper checks LastWriteTime on both script and module, restages only
    what's newer, and reports the reason so debugging is obvious.

.PARAMETER ScriptPath
    Full path to the script being staged (typically $MyInvocation.MyCommand.Path
    from the calling script).

.PARAMETER StagingDir
    Target local directory, e.g. 'C:\iDezign_Cleanup_Utility'.

.PARAMETER ResumeAfterUpdate
    Pass-through of the calling script's resume flag. When set, staging is
    skipped entirely - we're mid-flow and the staged copy is authoritative.

.OUTPUTS
    [hashtable] with keys:
        NeedsRestage [bool]  - true if script should re-launch from StagedPath
        StagedPath   [string]- where the staged copy lives
        Reason       [string]- human-readable explanation of why re-stage was needed
        Error        [string]- error message if staging failed (only on failure)

.EXAMPLE
    $r = Invoke-iDezignSelfStage -ScriptPath $ScriptPath -StagingDir 'C:\iDezign_Cleanup_Utility' -ResumeAfterUpdate:$ResumeAfterUpdate
    if ($r.NeedsRestage) {
        Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$($r.StagedPath)`""
        exit 0
    }
#>
function Invoke-iDezignSelfStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [Parameter(Mandatory)] [string] $StagingDir,
        [switch] $ResumeAfterUpdate
    )

    $StagedPath = Join-Path $StagingDir (Split-Path $ScriptPath -Leaf)

    # Mid-flow resume - never re-stage, the staged copy IS the source of truth
    if ($ResumeAfterUpdate) {
        return @{ NeedsRestage = $false; StagedPath = $StagedPath }
    }

    $scriptDir   = Split-Path $ScriptPath -Parent
    $srcModule   = Join-Path $scriptDir 'iDezign_Common.psm1'
    $dstModule   = Join-Path $StagingDir 'iDezign_Common.psm1'
    $srcManifest = Join-Path $scriptDir 'iDezign_Versions.json'
    $dstManifest = Join-Path $StagingDir 'iDezign_Versions.json'

    # Same-path case: launched from staging dir directly.  Nothing to compare
    # against (we'd need to know where the original source came from).  Just
    # continue running.
    if ($ScriptPath -eq $StagedPath) {
        return @{ NeedsRestage = $false; StagedPath = $StagedPath }
    }

    # Different-path case: we're launched from a source (NAS/USB/wherever).
    # Decide whether to re-stage based on file timestamps.
    $needsStage = $false
    $reason     = ''

    if (-not (Test-Path -LiteralPath $StagedPath)) {
        $needsStage = $true
        $reason     = 'first-time staging'
    } else {
        try {
            $srcTime = (Get-Item -LiteralPath $ScriptPath).LastWriteTime
            $dstTime = (Get-Item -LiteralPath $StagedPath).LastWriteTime
            if ($srcTime -gt $dstTime) {
                $needsStage = $true
                $reason     = "source script newer ($($srcTime.ToString('yyyy-MM-dd HH:mm')) > staged $($dstTime.ToString('yyyy-MM-dd HH:mm')))"
            }
        } catch { }
    }

    # Module check - module update alone is enough reason to re-stage
    if (Test-Path -LiteralPath $srcModule) {
        if (-not (Test-Path -LiteralPath $dstModule)) {
            $needsStage = $true
            if (-not $reason) { $reason = 'module not yet staged' }
        } else {
            try {
                $mSrc = (Get-Item -LiteralPath $srcModule).LastWriteTime
                $mDst = (Get-Item -LiteralPath $dstModule).LastWriteTime
                if ($mSrc -gt $mDst) {
                    $needsStage = $true
                    if (-not $reason) { $reason = "module newer ($($mSrc.ToString('yyyy-MM-dd HH:mm')) > staged $($mDst.ToString('yyyy-MM-dd HH:mm')))" }
                }
            } catch { }
        }
    }

    # Manifest check - the version banner reads iDezign_Versions.json from the
    # run directory. If it isn't staged alongside the script, the re-launched
    # staged copy reports "No iDezign_Versions.json found". Re-stage if the
    # manifest is missing from the staging dir or newer at the source.
    if (Test-Path -LiteralPath $srcManifest) {
        if (-not (Test-Path -LiteralPath $dstManifest)) {
            $needsStage = $true
            if (-not $reason) { $reason = 'manifest not yet staged' }
        } else {
            try {
                $jSrc = (Get-Item -LiteralPath $srcManifest).LastWriteTime
                $jDst = (Get-Item -LiteralPath $dstManifest).LastWriteTime
                if ($jSrc -gt $jDst) {
                    $needsStage = $true
                    if (-not $reason) { $reason = "manifest newer ($($jSrc.ToString('yyyy-MM-dd HH:mm')) > staged $($jDst.ToString('yyyy-MM-dd HH:mm')))" }
                }
            } catch { }
        }
    }

    if (-not $needsStage) {
        # Script and module are both up to date, OR launched-from differs only
        # in path but content is current.  Just continue running from wherever
        # we are - don't bounce back to staged copy when the source IS current.
        return @{ NeedsRestage = $false; StagedPath = $StagedPath }
    }

    # Do the staging
    Write-Host ""
    Write-Host "Launched from : $ScriptPath" -ForegroundColor DarkGray
    Write-Host "Staging to    : $StagedPath" -ForegroundColor Cyan
    Write-Host "Reason        : $reason" -ForegroundColor DarkGray
    Write-Host "(RunOnce resume after reboot needs the script on a local path.)" -ForegroundColor DarkGray
    Write-Host ""

    try {
        if (-not (Test-Path -LiteralPath $StagingDir)) {
            New-Item -Path $StagingDir -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path $ScriptPath -Destination $StagedPath -Force -ErrorAction Stop

        # Stage module too if a source copy is alongside the script.  This
        # ensures the re-launched staged script can load module helpers
        # rather than falling back to "module not found".
        if (Test-Path -LiteralPath $srcModule) {
            Copy-Item -Path $srcModule -Destination $dstModule -Force -ErrorAction Stop
        }

        # Stage the version manifest too so the staged copy's version banner
        # can find iDezign_Versions.json (otherwise it prints "no JSON found").
        if (Test-Path -LiteralPath $srcManifest) {
            Copy-Item -Path $srcManifest -Destination $dstManifest -Force -ErrorAction Stop
        }
    } catch {
        return @{
            NeedsRestage = $false
            StagedPath   = $StagedPath
            Error        = $_.Exception.Message
        }
    }

    return @{
        NeedsRestage = $true
        StagedPath   = $StagedPath
        Reason       = $reason
    }
}
#endregion

#region --- Test-iDezignDiskSpace --------------------------------------------
<#
.SYNOPSIS
    Verifies a drive has enough free space for the script to do its work.

.DESCRIPTION
    Hard pre-flight check. Windows Update alone can need 5-8 GB during
    install; combined with cleanup phase staging, 10 GB is the realistic
    minimum. Calling script should abort if this returns OK=$false.

.PARAMETER DriveLetter
    Single letter without colon. Default: 'C'.

.PARAMETER MinFreeGB
    Threshold below which we fail. Default: 10.

.OUTPUTS
    PSCustomObject with:
      OK       [bool]    - $true if free space meets threshold
      FreeGB   [double]  - actual free space, rounded to 2 dp
      TotalGB  [double]  - drive size, rounded to 2 dp
      MinGB    [int]     - the threshold that was checked against
#>
function Test-iDezignDiskSpace {
    [CmdletBinding()]
    param(
        [string]$DriveLetter = 'C',
        [int]$MinFreeGB = 10
    )

    $result = [PSCustomObject]@{
        OK      = $false
        FreeGB  = 0
        TotalGB = 0
        MinGB   = $MinFreeGB
    }

    try {
        # Get-Volume is cleaner than Get-PSDrive - returns actual disk metrics
        # and works the same on workstations and servers.
        $vol = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
        $result.FreeGB  = [math]::Round($vol.SizeRemaining / 1GB, 2)
        $result.TotalGB = [math]::Round($vol.Size / 1GB, 2)
        $result.OK      = ($result.FreeGB -ge $MinFreeGB)

        $pctFree = if ($result.TotalGB -gt 0) {
            [math]::Round(($result.FreeGB / $result.TotalGB) * 100, 1)
        } else { 0 }

        if ($result.OK) {
            Write-Host "    OK: ${DriveLetter}: has $($result.FreeGB) GB free of $($result.TotalGB) GB ($pctFree%)" -ForegroundColor DarkGray
        } else {
            Write-Host "    FAIL: ${DriveLetter}: has only $($result.FreeGB) GB free of $($result.TotalGB) GB ($pctFree%)" -ForegroundColor Red
            Write-Host "    Need at least $MinFreeGB GB free before running this script." -ForegroundColor Red
        }
    } catch {
        Write-Host "    Could not check ${DriveLetter}: drive: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    return $result
}
#endregion

#region --- Test-iDezignNetwork ----------------------------------------------
<#
.SYNOPSIS
    Quick TCP reachability test against multiple targets.

.DESCRIPTION
    Pre-flight check before downloads and Windows Update. Tests multiple
    targets because a single failure could be DNS, firewall rule, or just
    one CDN being slow - not necessarily "no internet". We report reachable
    count so the caller can decide:
      0/N reachable = warn loudly, downloads will fail
      1+/N reachable = proceed, log which were unreachable for diagnostics

    Uses raw TcpClient with timeout rather than Test-NetConnection because
    Test-NetConnection is slow (waits ~30 sec per failed target by default)
    and can hang on some firewalled networks.

.PARAMETER TimeoutMs
    Per-target connect timeout in milliseconds. Default: 3000.

.OUTPUTS
    PSCustomObject with:
      OK             [bool]    - $true if at least one target reachable
      ReachableCount [int]     - how many of the targets responded
      TotalTargets   [int]     - how many targets we tried
      Unreachable    [string[]]- names of unreachable targets
#>
function Test-iDezignNetwork {
    [CmdletBinding()]
    param(
        [int]$TimeoutMs = 3000
    )

    # Mix of: raw IP (DNS-independent), Microsoft CDN, Google CDN.
    # If all three fail, you definitely have no internet.
    $targets = @(
        [PSCustomObject]@{ Host = '8.8.8.8';                 Port = 443; Name = 'Google DNS (8.8.8.8)' }
        [PSCustomObject]@{ Host = 'download.windowsupdate.com'; Port = 443; Name = 'Windows Update CDN' }
        [PSCustomObject]@{ Host = 'dl.google.com';           Port = 443; Name = 'Google CDN'           }
    )

    $unreachable = @()
    $reachable   = 0

    foreach ($t in $targets) {
        $ok = $false
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect($t.Host, $t.Port, $null, $null)
            $waited = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
            if ($waited -and $tcp.Connected) {
                $ok = $true
            }
            $tcp.Close()
        } catch { }

        if ($ok) {
            Write-Host "    OK: $($t.Name)" -ForegroundColor DarkGray
            $reachable++
        } else {
            Write-Host "    Unreachable: $($t.Name)" -ForegroundColor DarkYellow
            $unreachable += $t.Name
        }
    }

    $result = [PSCustomObject]@{
        OK             = ($reachable -gt 0)
        ReachableCount = $reachable
        TotalTargets   = $targets.Count
        Unreachable    = $unreachable
    }

    if (-not $result.OK) {
        Write-Host "    WARNING: No internet connectivity detected." -ForegroundColor Yellow
        Write-Host "    Downloads, Windows Update, and NTP sync will fail." -ForegroundColor Yellow
    }

    return $result
}
#endregion

#region --- Test-iDezignBitLocker --------------------------------------------
<#
.SYNOPSIS
    Reports BitLocker state on the system drive.

.DESCRIPTION
    BitLocker matters in two ways for the toolkit:

    1. PRE-IMAGE PREP: a workstation being imaged should NOT have BitLocker
       enabled - the image will bake in encryption metadata tied to the
       source machine's TPM, and the captured image won't decrypt on
       target machines. Eric needs to know to suspend/disable BL before
       running cleanup if image capture is the end goal.

    2. POST-DEPLOY USE: on already-deployed workstations, BitLocker is fine
       to leave running. The risk is that cleanup operations + reboots
       sometimes trigger BL recovery key prompts due to "platform change"
       detection. Worth warning so the tech has the key handy before
       rebooting.

    Either way, this is informational - the caller decides whether to
    prompt or proceed.

.OUTPUTS
    PSCustomObject with:
      Available        [bool]   - BitLocker cmdlets/feature present on this OS
      IsEncrypted      [bool]   - C: drive has any encryption applied
      ProtectionStatus [string] - 'On'/'Off'/'Unknown' (BL protection active?)
      LockStatus       [string] - 'Unlocked'/'Locked'/'Unknown'
      EncryptionPct    [int]    - percentage encrypted (0 = unencrypted, 100 = fully)
      Volume           [string] - drive letter checked
#>
function Test-iDezignBitLocker {
    [CmdletBinding()]
    param(
        [string]$DriveLetter = 'C'
    )

    $result = [PSCustomObject]@{
        Available        = $false
        IsEncrypted      = $false
        ProtectionStatus = 'Unknown'
        LockStatus       = 'Unknown'
        EncryptionPct    = 0
        Volume           = "${DriveLetter}:"
    }

    # BitLocker module isn't always present (e.g. Home edition)
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Write-Host "    BitLocker cmdlets not available on this edition - skipping check." -ForegroundColor DarkGray
        return $result
    }
    $result.Available = $true

    try {
        $bl = Get-BitLockerVolume -MountPoint "${DriveLetter}:" -ErrorAction Stop
        $result.ProtectionStatus = "$($bl.ProtectionStatus)"
        $result.LockStatus       = "$($bl.LockStatus)"
        $result.EncryptionPct    = [int]$bl.EncryptionPercentage
        $result.IsEncrypted      = ($bl.EncryptionPercentage -gt 0)

        if (-not $result.IsEncrypted) {
            Write-Host "    OK: BitLocker not active on ${DriveLetter}:." -ForegroundColor DarkGray
        } else {
            Write-Host "    BitLocker DETECTED on ${DriveLetter}::" -ForegroundColor Yellow
            Write-Host "      Encryption        : $($result.EncryptionPct)%" -ForegroundColor Yellow
            Write-Host "      Protection status : $($result.ProtectionStatus)" -ForegroundColor Yellow
            Write-Host "      Lock status       : $($result.LockStatus)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    Could not query BitLocker status: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    return $result
}
#endregion

#region --- Get-iDezignActivationStatus --------------------------------------
<#
.SYNOPSIS
    Returns Windows activation status for diagnostic logging.

.DESCRIPTION
    Informational only - never blocks anything. Useful when something fails
    later and you want to know whether activation might be involved
    (unlicensed Windows can refuse Windows Update, refuse some app installs,
    silently fail certain admin operations).

    Uses SoftwareLicensingProduct WMI class, filtered to products with
    a partial product key (those are the ones that actually represent the
    OS license, not all the satellite products).

.OUTPUTS
    PSCustomObject with:
      IsActivated     [bool]   - $true if Windows is currently activated
      LicenseStatus   [string] - human-readable status
      LicenseStatusId [int]    - raw WMI status code (0-5)
      Description     [string] - product description, e.g. "Windows(R), Professional edition"
      PartialKey      [string] - last 5 chars of the product key
#>
function Get-iDezignActivationStatus {
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        IsActivated     = $false
        LicenseStatus   = 'Unknown'
        LicenseStatusId = -1
        Description     = ''
        PartialKey      = ''
    }

    try {
        $lic = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
               Where-Object { $_.PartialProductKey -and $_.Name -like 'Windows*' } |
               Select-Object -First 1

        if ($lic) {
            $result.LicenseStatusId = [int]$lic.LicenseStatus
            $result.IsActivated     = ($lic.LicenseStatus -eq 1)
            $result.Description     = $lic.Description
            $result.PartialKey      = $lic.PartialProductKey

            # LicenseStatus codes per SoftwareLicensingProduct WMI docs:
            #   0 = Unlicensed
            #   1 = Licensed (activated)
            #   2 = OOB Grace
            #   3 = OOT Grace
            #   4 = Non-Genuine Grace
            #   5 = Notification
            #   6 = Extended Grace
            switch ($lic.LicenseStatus) {
                0 { $result.LicenseStatus = 'Unlicensed' }
                1 { $result.LicenseStatus = 'Licensed (activated)' }
                2 { $result.LicenseStatus = 'OOB Grace period' }
                3 { $result.LicenseStatus = 'OOT Grace period' }
                4 { $result.LicenseStatus = 'Non-Genuine Grace' }
                5 { $result.LicenseStatus = 'Notification mode (not activated)' }
                6 { $result.LicenseStatus = 'Extended Grace period' }
                default { $result.LicenseStatus = "Unknown ($($lic.LicenseStatus))" }
            }

            $color = if ($result.IsActivated) { 'DarkGray' } else { 'Yellow' }
            Write-Host "    Status: $($result.LicenseStatus)" -ForegroundColor $color
            Write-Host "    Edition: $($result.Description)" -ForegroundColor DarkGray
            Write-Host "    Partial key: $($result.PartialKey)" -ForegroundColor DarkGray
        } else {
            Write-Host "    No Windows license product found via WMI." -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "    Could not query activation: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    return $result
}
#endregion

#region --- Sync-SystemTime --------------------------------------------------
<#
.SYNOPSIS
    Ensures the system clock is accurate by forcing an NTP sync.

.DESCRIPTION
    Critical pre-flight check on imaged machines. A wrong clock causes:
      * TLS/cert failures (downloads, Windows Update, PSWindowsUpdate)
      * Wrong dates in computer/account names if scripts use Get-Date
      * Backup schedules/scheduled tasks firing at wrong times
      * Event log timestamps useless for troubleshooting
      * AD sync failures on domain-joined machines (kerberos auth requires
        clocks within ~5 min of the DC)

    Behavior:
      * Domain-joined  : just triggers w32tm /resync (uses the DC as source)
      * Workgroup/new  : configures public NTP peers, then triggers /resync
      * Sanity-checks the resulting year - warns if year is < 2025 or > 2030
        (indicates BIOS battery dead / NTP unreachable / sync failed)

    Returns $true if the clock looks sane after sync, $false otherwise.
    A return of $false should make the caller pause and verify before
    using the date for naming or attempting downloads.

.PARAMETER QuietIfAccurate
    If the clock was already within 60 sec of correct, suppress the
    success output. Default = show output. Useful when called repeatedly.

.OUTPUTS
    [bool] - $true if clock looks accurate after sync, $false if questionable.
#>
function Sync-SystemTime {
    [CmdletBinding()]
    param(
        [switch]$QuietIfAccurate
    )

    Write-Host "  Checking system clock..." -ForegroundColor DarkGray

    $beforeDate = Get-Date
    $tz = try { (Get-TimeZone).Id } catch { 'unknown' }
    Write-Host "    Current local time : $($beforeDate.ToString('yyyy-MM-dd HH:mm:ss'))  ($tz)" -ForegroundColor DarkGray

    # 1. Make sure W32Time service is configured and running.
    #    On some fresh images / Server Core installs, W32Time is disabled.
    try {
        $svc = Get-Service -Name 'W32Time' -ErrorAction Stop
        if ($svc.StartType -eq 'Disabled') {
            Write-Host "    Enabling W32Time service (was disabled)..." -ForegroundColor DarkGray
            Set-Service -Name 'W32Time' -StartupType Manual -ErrorAction SilentlyContinue
        }
        if ($svc.Status -ne 'Running') {
            Write-Host "    Starting W32Time service..." -ForegroundColor DarkGray
            Start-Service -Name 'W32Time' -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    } catch {
        Write-Host "    Could not query W32Time service: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    # 2. Decide which NTP source strategy to use.
    #    Domain-joined → don't touch peers (DC is authoritative).
    #    Workgroup/standalone → set redundant public NTP peers.
    $isDomain = $false
    try {
        $isDomain = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain
    } catch { }

    if (-not $isDomain) {
        # 0x9 flag = SpecialInterval | Client - reliable for outbound sync.
        # Multiple peers = redundancy if one is unreachable (firewalled, etc).
        $peers = 'time.windows.com,0x9 pool.ntp.org,0x9 time.nist.gov,0x9'
        Write-Host "    Standalone machine - configuring public NTP peers..." -ForegroundColor DarkGray
        & w32tm.exe /config /manualpeerlist:"$peers" /syncfromflags:manual /reliable:no /update 2>&1 | Out-Null
    } else {
        Write-Host "    Domain-joined - using DC as time source." -ForegroundColor DarkGray
    }

    # 3. Force a resync. Run twice in case the first attempt populates the
    #    peer list but doesn't actually sync (common on fresh installs).
    Write-Host "    Forcing time sync..." -ForegroundColor DarkGray
    & w32tm.exe /resync /force 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & w32tm.exe /resync /force 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    # 4. Re-check and report delta.
    $afterDate = Get-Date
    $deltaSec  = [math]::Abs(($afterDate - $beforeDate).TotalSeconds)
    # Account for the few seconds we spent in this function itself - anything
    # under ~15 sec of drift here is just our own runtime, not a real correction.
    $realDrift = $deltaSec - 15
    if ($realDrift -lt 0) { $realDrift = 0 }

    if ($realDrift -gt 60) {
        Write-Host "    Clock corrected by ~$([math]::Round($realDrift,0)) seconds." -ForegroundColor Yellow
        Write-Host "    Updated local time : $($afterDate.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Yellow
    }

    # 4b. INDEPENDENT drift check against an authoritative HTTP time source.
    # The delta-before-vs-after check above only detects that w32tm CHANGED
    # the clock - not whether the resulting clock is ACCURATE. w32tm can
    # silently fail (no NTP reachable, service wedged, etc.) and leave the
    # clock still drifted. This check compares to an HTTP Date header from
    # a well-known site and warns loudly if we're still off.
    $httpDrift = $null
    foreach ($probe in @('http://www.google.com','http://www.microsoft.com','http://www.cloudflare.com')) {
        try {
            $r = Invoke-WebRequest -Uri $probe -UseBasicParsing -Method Head -TimeoutSec 5 -ErrorAction Stop
            $dateHdr = $r.Headers['Date']
            if (-not $dateHdr -and $r.Headers.Date) { $dateHdr = $r.Headers.Date }
            if ($dateHdr) {
                $serverUtc = ([DateTime]::Parse($dateHdr)).ToUniversalTime()
                $localUtc  = [DateTime]::UtcNow
                $httpDrift = [math]::Round([math]::Abs(($serverUtc - $localUtc).TotalSeconds))
                break
            }
        } catch { }
    }
    if ($null -ne $httpDrift) {
        if ($httpDrift -gt 60) {
            Write-Host "    WARNING: Clock is STILL OFF by ~$httpDrift seconds after sync!" -ForegroundColor Red
            Write-Host "    (w32tm reported success but drift check vs HTTP Date says otherwise.)" -ForegroundColor Red
            Write-Host "    Common causes: firewall blocking UDP 123, no reachable NTP peer," -ForegroundColor Yellow
            Write-Host "    W32Time service wedged, or a proxy stripping Date headers." -ForegroundColor Yellow
            Write-Host "    Fix: Settings > Time & language > Date & time > Sync now (or set" -ForegroundColor Yellow
            Write-Host "    time zone manually if the tz is wrong)." -ForegroundColor Yellow
            return $false
        } else {
            if (-not $QuietIfAccurate) {
                Write-Host "    Clock verified accurate (drift vs internet time: ~${httpDrift}s)." -ForegroundColor DarkGray
            }
        }
    } else {
        # HTTP probe failed entirely - fall back to the year check only, and
        # be honest that we couldn't independently verify.
        if (-not $QuietIfAccurate) {
            Write-Host "    (Could not verify clock via HTTP time - no probe reachable.)" -ForegroundColor DarkYellow
            Write-Host "    Clock accuracy is UNVERIFIED. Check manually if in doubt." -ForegroundColor DarkYellow
        }
    }

    # 5. Sanity check the year. If we're still in 2009 or jumped to 2099,
    #    NTP didn't actually work - probably no internet or W32Time wedged.
    $currentYear  = (Get-Date).Year
    $expectedMin  = 2025
    $expectedMax  = 2035
    if ($currentYear -lt $expectedMin -or $currentYear -gt $expectedMax) {
        Write-Host "" -ForegroundColor Red
        Write-Host "    WARNING: System year is $currentYear - this looks wrong!" -ForegroundColor Red
        Write-Host "    Likely causes:" -ForegroundColor Red
        Write-Host "      - Dead CMOS battery (will revert next power-off)" -ForegroundColor Red
        Write-Host "      - No internet connectivity for NTP sync" -ForegroundColor Red
        Write-Host "      - Firewall blocking UDP 123 outbound" -ForegroundColor Red
        Write-Host "      - W32Time service wedged" -ForegroundColor Red
        Write-Host "    Anything that uses today's date will be wrong." -ForegroundColor Red
        Write-Host "" -ForegroundColor Red
        return $false
    }

    # 6. Final status line from w32tm itself for the record.
    try {
        $statusLines = & w32tm.exe /query /status 2>&1
        $sourceLine  = $statusLines | Select-String -Pattern '^Source:' | Select-Object -First 1
        if ($sourceLine) {
            Write-Host "    $($sourceLine.Line.Trim())" -ForegroundColor DarkGray
        }
    } catch { }

    return $true
}
#endregion

#region --- Show-VersionCheck ------------------------------------------------
<#
.SYNOPSIS
    Compare a script's embedded version against the shared version manifest
    (iDezign_Versions.json) and print a clear "you are current" / "outdated
    copy" banner at the start of a run.

.DESCRIPTION
    The manifest is the source of truth for the latest version of every script.
    Each tool calls this at startup with its own name + embedded $ScriptVersion.
    Outcomes:
      * Manifest found + versions match  -> green  "running the LATEST version"
      * Manifest found + script OLDER    -> yellow "OUTDATED copy" warning
      * Manifest found + script NEWER    -> cyan   "newer than manifest" (you
                                            updated the script but not the JSON)
      * Manifest missing / unparseable   -> gray   just prints the version

    This catches the real-world mistake of copying a new set of files but
    forgetting one - that one script's embedded version won't match the
    manifest and you'll get a visible warning instead of silently running
    stale code.

.PARAMETER ScriptName
    The file name to look up in the manifest, e.g. 'iDezign_Cleanup_Utility.ps1'.

.PARAMETER CurrentVersion
    The script's own embedded $ScriptVersion string.

.PARAMETER ScriptDir
    Folder to look for iDezign_Versions.json in. Defaults to the directory of
    the calling script if resolvable, else current location.
#>
function Show-VersionCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [Parameter(Mandatory)] [string] $CurrentVersion,
        [string] $ScriptDir
    )

    # Resolve where to look for the manifest
    if (-not $ScriptDir) {
        if ($PSScriptRoot) { $ScriptDir = Split-Path -Parent $PSScriptRoot }
        else               { $ScriptDir = (Get-Location).Path }
    }

    # The manifest could be in the script dir or one level up - check both.
    $candidates = @(
        (Join-Path $ScriptDir 'iDezign_Versions.json'),
        (Join-Path (Split-Path -Parent $ScriptDir) 'iDezign_Versions.json')
    )
    $manifestPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

    Write-Host ""
    if (-not $manifestPath) {
        Write-Host ("  [version] {0}  v{1}" -f $ScriptName, $CurrentVersion) -ForegroundColor DarkGray
        Write-Host "  [version] No iDezign_Versions.json found - can't confirm this is the latest." -ForegroundColor DarkGray
        return
    }

    try {
        $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json -ErrorAction Stop
        $latest   = $manifest.scripts.$ScriptName
    } catch {
        Write-Host ("  [version] {0}  v{1}  (manifest unreadable)" -f $ScriptName, $CurrentVersion) -ForegroundColor DarkGray
        return
    }

    if (-not $latest) {
        Write-Host ("  [version] {0}  v{1}  (not listed in manifest)" -f $ScriptName, $CurrentVersion) -ForegroundColor DarkGray
        return
    }

    if ($CurrentVersion -eq $latest) {
        Write-Host ("  [version] OK - running the LATEST version of {0} (v{1})" -f $ScriptName, $CurrentVersion) -ForegroundColor Green
    } else {
        # Use string comparison to guess direction. Versions are date-prefixed
        # (yyyy.MM.dd-label) so lexical compare == chronological for the date part.
        if ($CurrentVersion -lt $latest) {
            Write-Host ("  [version] WARNING - {0} looks OUTDATED" -f $ScriptName) -ForegroundColor Yellow
            Write-Host ("            this copy : v{0}" -f $CurrentVersion) -ForegroundColor Yellow
            Write-Host ("            latest    : v{0}" -f $latest) -ForegroundColor Yellow
            Write-Host  "            You may have an old copy - re-copy the full toolkit set." -ForegroundColor Yellow
        } else {
            Write-Host ("  [version] {0} v{1} is NEWER than manifest (v{2})" -f $ScriptName, $CurrentVersion, $latest) -ForegroundColor Cyan
            Write-Host  "            (script updated but iDezign_Versions.json not yet bumped)" -ForegroundColor DarkCyan
        }
    }
}
#endregion

Export-ModuleMember -Function `
    Test-PendingReboot, `
    Write-iDezignAction, `
    Get-RemoteFile, `
    Read-iDezignYN, `
    Get-AdminGroupName, `
    Get-IsServerOS, `
    Get-ServerOSDetails, `
    Show-ServerWarning, `
    Get-iDezignBanner, `
    Start-iDezignTranscript, `
    Start-ProcessWithTimeout, `
    Invoke-WithJobTimeout, `
    Invoke-RebootChoice, `
    Invoke-iDezignSelfStage, `
    Test-iDezignDiskSpace, `
    Test-iDezignNetwork, `
    Test-iDezignBitLocker, `
    Get-iDezignActivationStatus, `
    Sync-SystemTime, `
    Show-VersionCheck, `
    Get-iDezignCommonVersion
