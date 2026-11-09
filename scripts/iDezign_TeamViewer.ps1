# ============================================================================
#  iDezign_TeamViewer.ps1
#  Standalone: download + silently install the iDezign-branded TeamViewer
#  Host from custom.teamviewer.com/idhelp, verify the service, and show the
#  machine's TeamViewer ID so it can be added to the iDezign device list.
#
#  Why standalone (v3.8): the same install lives inside Cleanup (Phase 1e),
#  but a service call often needs ONLY remote access set up - no reason to
#  drag a full Cleanup along. Same source URL, same /S silent switch.
#
#  Hardening over the Cleanup phase:
#    * The download is validated as a real Windows executable ("MZ" header,
#      sane size). TeamViewer's custom links can answer with an HTML landing
#      page instead of the installer; if that happens we look for the real
#      installer link inside the page and retry, and as a last resort open
#      the page in the browser and say so - never "installing" an HTML file.
#    * Already installed? Shows version + ID and asks before reinstalling.
#
#  Run as Administrator. No reboot.
# ============================================================================

$ScriptVersion = '2026.11.09-teamviewer-v1.0'
$RunStarted    = Get-Date

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
    Show-VersionCheck -ScriptName 'iDezign_TeamViewer.ps1' -CurrentVersion $ScriptVersion -ScriptDir $ScriptDir
}

#endregion

#region --- Banner ---------------------------------------------------------

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  iDezign Toolkit - TeamViewer Host (iDezign branded)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Script version : $ScriptVersion" -ForegroundColor DarkGray
Write-Host "  Started        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
Write-Host ""

#endregion

#region --- Helpers --------------------------------------------------------

$TvUrl     = 'https://custom.teamviewer.com/idhelp'
$WorkDir   = Join-Path $env:ProgramData 'iDezign\Toolkit'
$TvExe     = Join-Path $WorkDir 'TeamViewer_Host_iDezign.exe'
# Browser-like UA: TeamViewer's download hosts treat unknown agents differently.
$BrowserUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'

function Get-TeamViewerInfo {
    # Returns @{ Installed; Version; ClientId; ServiceState } from registry + service.
    $info = @{ Installed = $false; Version = $null; ClientId = $null; ServiceState = $null }
    foreach ($k in @('HKLM:\SOFTWARE\TeamViewer', 'HKLM:\SOFTWARE\WOW6432Node\TeamViewer')) {
        try {
            if (Test-Path $k) {
                $p = Get-ItemProperty -Path $k -ErrorAction Stop
                if ($p.Version)  { $info.Version  = [string]$p.Version }
                if ($p.ClientID) { $info.ClientId = [string]$p.ClientID }
                if ($p.Version -or $p.ClientID -or $p.InstallationDirectory) { $info.Installed = $true }
            }
        } catch { }
    }
    $svc = Get-Service -Name 'TeamViewer' -ErrorAction SilentlyContinue
    if ($svc) { $info.Installed = $true; $info.ServiceState = [string]$svc.Status }
    return $info
}

function Format-TeamViewerId {
    param([string]$Id)
    if (-not $Id) { return '(not assigned yet)' }
    # 1 234 567 890 style grouping, the way TeamViewer displays it
    $s = $Id.Trim()
    $out = ''
    for ($i = $s.Length; $i -gt 0; $i -= 3) {
        $start = [math]::Max(0, $i - 3)
        $chunk = $s.Substring($start, $i - $start)
        if ($out) { $out = $chunk + ' ' + $out } else { $out = $chunk }
    }
    return $out
}

function Test-IsExecutable {
    # True when the file starts with the PE "MZ" header and is a plausible size.
    param([string]$Path, [int]$MinBytes = 3MB)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $fi = Get-Item -LiteralPath $Path
        if ($fi.Length -lt $MinBytes) { return $false }
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $b0 = $fs.ReadByte(); $b1 = $fs.ReadByte()
        } finally { $fs.Close() }
        return ($b0 -eq 0x4D -and $b1 -eq 0x5A)
    } catch { return $false }
}

function Get-TvInstaller {
    # Download $Url to $OutFile with a browser UA. Returns $true on HTTP success.
    param([string]$Url, [string]$OutFile)
    try {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -UserAgent $BrowserUA -TimeoutSec 180 -MaximumRedirection 10 -ErrorAction Stop
        return $true
    } catch {
        Write-Host "  Download error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Find-InstallerLinkInHtml {
    # When the custom link answers with a landing page, dig the real
    # installer URL out of it (href/src/meta-refresh pointing at an .exe or
    # a /download path). Returns $null if nothing plausible is found.
    param([string]$HtmlPath, [string]$BaseUrl)
    try {
        $html = Get-Content -LiteralPath $HtmlPath -Raw -ErrorAction Stop
        $cands = New-Object System.Collections.Generic.List[string]
        foreach ($m in [regex]::Matches($html, '(?i)(?:href|src|url)\s*=\s*["'']?([^"''\s>]+)')) {
            $u = $m.Groups[1].Value
            if ($u -match '(?i)\.exe(\?|$)' -or $u -match '(?i)/download') { [void]$cands.Add($u) }
        }
        foreach ($m in [regex]::Matches($html, '(?i)https?://[^"''\s<>]+\.exe[^"''\s<>]*')) { [void]$cands.Add($m.Value) }
        foreach ($c in $cands) {
            $c2 = $c -replace '&amp;', '&'
            if ($c2 -match '^https?://') { return $c2 }
            try { return ([Uri]::new([Uri]$BaseUrl, $c2)).AbsoluteUri } catch { }
        }
    } catch { }
    return $null
}

function Exit-Tool {
    param([int]$Code = 0)
    Write-Host ""
    Write-Host "Press any key to close this window..." -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
    exit $Code
}

function Complete-Tool {
    param([string]$Status, [string]$Summary)
    if (Get-Command Complete-iDezignRun -ErrorAction SilentlyContinue) {
        # Short tool - the console banner is enough, no popup needed.
        Complete-iDezignRun -Tool 'TeamViewer' -Version $ScriptVersion -Started $RunStarted -Status $Status -Summary $Summary -NoPopup
    }
}

#endregion

#region --- Current state --------------------------------------------------

$before = Get-TeamViewerInfo
if ($before.Installed) {
    Write-Host "  TeamViewer is already installed on this machine:" -ForegroundColor Yellow
    Write-Host ("    Version : {0}" -f $(if ($before.Version) { $before.Version } else { 'unknown' })) -ForegroundColor DarkGray
    Write-Host ("    Service : {0}" -f $(if ($before.ServiceState) { $before.ServiceState } else { 'not found' })) -ForegroundColor DarkGray
    Write-Host ("    ID      : {0}" -f (Format-TeamViewerId $before.ClientId)) -ForegroundColor Cyan
    Write-Host ""
    $answer = Read-Host "Reinstall / update with the iDezign-branded Host? (Y/N) [Enter = N]"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host "  Left as-is." -ForegroundColor DarkGray
        Complete-Tool -Status 'OK' -Summary ("Already installed (v{0}); ID {1}; no changes" -f $before.Version, (Format-TeamViewerId $before.ClientId))
        Exit-Tool 0
    }
} else {
    Write-Host "  TeamViewer is not installed - installing the iDezign-branded Host." -ForegroundColor Green
}

#endregion

#region --- Download -------------------------------------------------------

if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force | Out-Null }

Write-Host ""
Write-Host "[1/3] Downloading..." -ForegroundColor Green
Write-Host "  Source: $TvUrl" -ForegroundColor DarkGray
Write-Host "  Local : $TvExe" -ForegroundColor DarkGray

$gotExe = $false
if (Get-TvInstaller -Url $TvUrl -OutFile $TvExe) {
    if (Test-IsExecutable -Path $TvExe) {
        $gotExe = $true
    } else {
        # Landing page instead of the installer - find the real link and retry.
        Write-Host "  Server answered with a web page, not the installer - looking for the download link in it..." -ForegroundColor DarkYellow
        $htmlCopy = Join-Path $WorkDir 'teamviewer_landing.html'
        try { Copy-Item -LiteralPath $TvExe -Destination $htmlCopy -Force } catch { }
        $real = Find-InstallerLinkInHtml -HtmlPath $htmlCopy -BaseUrl $TvUrl
        if ($real) {
            Write-Host "  Found: $real" -ForegroundColor DarkGray
            if ((Get-TvInstaller -Url $real -OutFile $TvExe) -and (Test-IsExecutable -Path $TvExe)) { $gotExe = $true }
        }
        try { Remove-Item -LiteralPath $htmlCopy -Force -ErrorAction SilentlyContinue } catch { }
    }
}

if (-not $gotExe) {
    Write-Host ""
    Write-Host "  Could not download a valid installer automatically." -ForegroundColor Red
    Write-Host "  Opening the iDezign TeamViewer page in the browser - click the download there," -ForegroundColor Yellow
    Write-Host "  run the file it saves, then run this tool again to verify + show the ID." -ForegroundColor Yellow
    try { Start-Process $TvUrl } catch { }
    try { if (Test-Path -LiteralPath $TvExe) { Remove-Item -LiteralPath $TvExe -Force -ErrorAction SilentlyContinue } } catch { }
    Complete-Tool -Status 'Failed' -Summary 'Download did not return a valid installer; opened page in browser'
    Exit-Tool 1
}

$sizeMB = [math]::Round((Get-Item -LiteralPath $TvExe).Length / 1MB, 1)
Write-Host "  Downloaded: $sizeMB MB (valid Windows executable)" -ForegroundColor DarkGray
try {
    $sig = Get-AuthenticodeSignature -FilePath $TvExe -ErrorAction Stop
    if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'TeamViewer') {
        Write-Host "  Signature : valid (TeamViewer)" -ForegroundColor DarkGray
    } else {
        Write-Host ("  Signature : {0} - {1}" -f $sig.Status, $sig.SignerCertificate.Subject) -ForegroundColor DarkYellow
        $answer = Read-Host "  Installer is not signed by TeamViewer as expected. Install anyway? (Y/N) [Enter = N]"
        if ($answer -notmatch '^(y|yes)$') {
            Remove-Item -LiteralPath $TvExe -Force -ErrorAction SilentlyContinue
            Complete-Tool -Status 'Failed' -Summary 'Installer signature not TeamViewer; aborted by tech'
            Exit-Tool 1
        }
    }
} catch {
    Write-Host "  Signature : could not be checked ($($_.Exception.Message))" -ForegroundColor DarkYellow
}

#endregion

#region --- Install --------------------------------------------------------

Write-Host ""
Write-Host "[2/3] Installing silently (timeout 10 min)..." -ForegroundColor Green
$rc = $null
if (Get-Command Start-ProcessWithTimeout -ErrorAction SilentlyContinue) {
    $rc = Start-ProcessWithTimeout -FilePath $TvExe -ArgumentList @('/S') -TimeoutMinutes 10 -Label 'TeamViewer Host installer'
} else {
    try {
        $p = Start-Process -FilePath $TvExe -ArgumentList '/S' -Wait -PassThru
        $rc = $p.ExitCode
    } catch {
        Write-Host "  ERROR running installer: $($_.Exception.Message)" -ForegroundColor Red
        $rc = -2
    }
}
if ($rc -eq -1) {
    Write-Host "  Installer TIMED OUT (>10 min)." -ForegroundColor Red
} elseif ($rc -ne 0) {
    Write-Host "  Installer returned exit code $rc (some custom Host builds return non-zero on success - verifying below)." -ForegroundColor DarkYellow
} else {
    Write-Host "  Installer finished." -ForegroundColor DarkGray
}

#endregion

#region --- Verify + show ID -----------------------------------------------

Write-Host ""
Write-Host "[3/3] Verifying..." -ForegroundColor Green
# The service registers and the ID is assigned a few seconds after install.
$after = $null
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Seconds 5
    $after = Get-TeamViewerInfo
    if ($after.ServiceState -eq 'Running' -and $after.ClientId) { break }
}
if ($after.ServiceState -and $after.ServiceState -ne 'Running') {
    try { Start-Service -Name 'TeamViewer' -ErrorAction Stop; Start-Sleep -Seconds 3; $after = Get-TeamViewerInfo } catch { }
}

$ok = ($after.Installed -and $after.ServiceState -eq 'Running')
Write-Host ("  Installed : {0}" -f $(if ($after.Installed) { 'yes' } else { 'NO' })) -ForegroundColor $(if ($after.Installed) { 'Green' } else { 'Red' })
Write-Host ("  Version   : {0}" -f $(if ($after.Version) { $after.Version } else { 'unknown' })) -ForegroundColor DarkGray
Write-Host ("  Service   : {0}" -f $(if ($after.ServiceState) { $after.ServiceState } else { 'not found' })) -ForegroundColor $(if ($after.ServiceState -eq 'Running') { 'Green' } else { 'Yellow' })
Write-Host ""
Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
Write-Host ("  |  TeamViewer ID :  {0,-22} |" -f (Format-TeamViewerId $after.ClientId)) -ForegroundColor Cyan
Write-Host ("  |  Computer      :  {0,-22} |" -f $env:COMPUTERNAME) -ForegroundColor Cyan
Write-Host "  +------------------------------------------+" -ForegroundColor Cyan
if (-not $after.ClientId) {
    Write-Host "  (ID not assigned yet - needs internet; it appears in the TeamViewer window within a minute.)" -ForegroundColor DarkYellow
}

# Installer is no longer needed; keep the machine tidy.
try { Remove-Item -LiteralPath $TvExe -Force -ErrorAction SilentlyContinue } catch { }

if ($ok) {
    Complete-Tool -Status 'OK' -Summary ("Host v{0} installed, service running; ID {1}" -f $after.Version, (Format-TeamViewerId $after.ClientId))
    Exit-Tool 0
} elseif ($after.Installed) {
    Complete-Tool -Status 'Attention' -Summary ("Installed but service is {0}; ID {1}" -f $after.ServiceState, (Format-TeamViewerId $after.ClientId))
    Write-Host "  Installed, but the service is not running - a reboot usually settles it." -ForegroundColor Yellow
    Exit-Tool 0
} else {
    Complete-Tool -Status 'Failed' -Summary ("Install not detected (installer exit code {0})" -f $rc)
    Write-Host "  TeamViewer was not detected after the install. Try again, or install from $TvUrl in a browser." -ForegroundColor Red
    Exit-Tool 1
}

#endregion
