# ============================================================================
#  iDezign_Duplicate.ps1
#  Purpose: copy content from ONE location to ANOTHER. Works uniformly for:
#     - Folder to folder                (C:\Photos -> D:\Backup\Photos)
#     - Drive to drive                  (E:\ -> F:\)
#     - USB stick to hard drive         (E:\ -> C:\Users\me\Documents\USB-Backup)
#     - Optical media to hard drive     (D:\ -> C:\CD-rips\my-disc)
#     - Network share to local          (\\server\share -> C:\SharedCache)
#     - Local to network share          (works the other way too)
#
#  All of the above are just filesystem paths. Robocopy handles them uniformly.
#
#  Modes:
#     M - Mirror   : Destination becomes an EXACT copy of source. Files that
#                    exist on dest but not on source are DELETED from dest.
#                    Use when the destination should "match" the source.
#     A - Additive : Copy source -> dest without deleting anything on dest.
#                    Use when dest is a growing collection and you want to
#                    add source's files to it without cleaning.
#     D - Dry-run  : Show what WOULD happen. Nothing is copied, nothing is
#                    deleted. Use to preview before running for real.
#
#  Under the hood: robocopy with retry-limited flags (R:1 W:1). Default
#  robocopy retries 1,000,000 times waiting 30s each on locked files -
#  that's why unattended robocopy runs sometimes hang for hours. Our flags
#  cap at 1 retry + 1s wait so a locked file fails fast and moves on.
#
#  Author: iDezign Toolkit
# ============================================================================

param(
    [string]$Source,
    [string]$Destination,
    [ValidateSet('Mirror','Additive','DryRun')]
    [string]$Mode
)

$ScriptVersion = '2026.07.01-v3.3-duplicate-v1'

# ----------------------------------------------------------------------------
# Load Common module + admin/version check (mirrors what the other tools do).
# Not strictly required for robocopy - it can run without admin - but if the
# user needs to copy protected system files, admin unblocks that.
# ----------------------------------------------------------------------------

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulePath = Join-Path $ScriptDir 'iDezign_Common.psm1'
if (Test-Path $ModulePath) {
    Import-Module $ModulePath -Force -ErrorAction SilentlyContinue
    if (Get-Command Show-VersionCheck -ErrorAction SilentlyContinue) {
        Show-VersionCheck -ScriptName 'iDezign_Duplicate.ps1' -CurrentVersion $ScriptVersion -ScriptDir $ScriptDir
    }
}

# ----------------------------------------------------------------------------
# Banner
# ----------------------------------------------------------------------------

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  iDezign Duplicate" -ForegroundColor Cyan
Write-Host "  Copy content between any two locations (folders/drives/USB)" -ForegroundColor DarkGray
Write-Host "  Version: $ScriptVersion" -ForegroundColor DarkGray
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ----------------------------------------------------------------------------
# Path helpers
# ----------------------------------------------------------------------------

function Read-PathInteractive {
    param(
        [string]$Prompt,
        [switch]$MustExist,
        [switch]$AllowCreate
    )

    while ($true) {
        Write-Host $Prompt -ForegroundColor Yellow
        Write-Host "  Tip: drag the folder/drive from Explorer into this window to auto-fill the path." -ForegroundColor DarkGray
        $raw = Read-Host "  Path"

        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Host "  Path can't be blank." -ForegroundColor Red
            continue
        }

        # Strip surrounding quotes (Explorer drag can add them; users paste with quotes too)
        $path = $raw.Trim().Trim('"').Trim("'")

        # Normalize to absolute if possible
        try {
            $path = [System.IO.Path]::GetFullPath($path)
        } catch { }

        if ($MustExist) {
            if (-not (Test-Path -LiteralPath $path)) {
                Write-Host "  Path does not exist: $path" -ForegroundColor Red
                $again = Read-Host "  Try again? (Y/N)"
                if ($again -notmatch '^(y|yes)$') { throw "Aborted by user." }
                continue
            }
        }

        if ($AllowCreate -and -not (Test-Path -LiteralPath $path)) {
            Write-Host "  Path does not exist yet: $path" -ForegroundColor Yellow
            $create = Read-Host "  Create it? (Y/N)"
            if ($create -match '^(y|yes)$') {
                try {
                    New-Item -Path $path -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    Write-Host "  Created." -ForegroundColor Green
                } catch {
                    Write-Host "  ERROR creating destination: $($_.Exception.Message)" -ForegroundColor Red
                    continue
                }
            } else {
                Write-Host "  OK - not creating. Try a different path." -ForegroundColor Yellow
                continue
            }
        }

        return $path
    }
}

function Test-DestinationInsideSource {
    param([string]$Source, [string]$Destination)

    # Normalize both to full-path form for reliable comparison
    try {
        $src = [System.IO.Path]::GetFullPath($Source).TrimEnd('\','/')
        $dst = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\','/')
    } catch {
        return $false
    }

    if ([string]::IsNullOrEmpty($src) -or [string]::IsNullOrEmpty($dst)) { return $false }

    # Case-insensitive on Windows
    if ($dst.Length -ge $src.Length -and $dst.Substring(0, $src.Length).ToLower() -eq $src.ToLower()) {
        # dst starts with src - either same path OR nested
        if ($dst.Length -eq $src.Length) { return $true }  # same path
        if ($dst.Substring($src.Length, 1) -in @('\','/')) { return $true }  # nested
    }
    return $false
}

# ----------------------------------------------------------------------------
# Gather inputs (interactive if not provided as params)
# ----------------------------------------------------------------------------

try {
    if ([string]::IsNullOrWhiteSpace($Source)) {
        Write-Host "----- Source -----" -ForegroundColor Cyan
        $Source = Read-PathInteractive -Prompt "Enter SOURCE path (the folder/drive to copy FROM):" -MustExist
        Write-Host ""
    } elseif (-not (Test-Path -LiteralPath $Source)) {
        throw "Source path does not exist: $Source"
    }

    if ([string]::IsNullOrWhiteSpace($Destination)) {
        Write-Host "----- Destination -----" -ForegroundColor Cyan
        $Destination = Read-PathInteractive -Prompt "Enter DESTINATION path (the folder/drive to copy TO):" -AllowCreate
        Write-Host ""
    } elseif (-not (Test-Path -LiteralPath $Destination)) {
        # Non-interactive dest - create it
        New-Item -Path $Destination -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    # ------------------------------------------------------------------------
    # Sanity: is destination INSIDE source? robocopy would recurse into itself.
    # ------------------------------------------------------------------------
    if (Test-DestinationInsideSource -Source $Source -Destination $Destination) {
        Write-Host "ERROR: destination '$Destination' is inside source '$Source'." -ForegroundColor Red
        Write-Host "That would recurse forever - refusing to run." -ForegroundColor Red
        exit 1
    }

    # ------------------------------------------------------------------------
    # Mode picker (interactive if not passed as param)
    # ------------------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($Mode)) {
        Write-Host "----- Mode -----" -ForegroundColor Cyan
        Write-Host "  M) Mirror   - destination becomes an EXACT copy of source." -ForegroundColor Green
        Write-Host "              Files on dest that aren't on source will be DELETED." -ForegroundColor DarkYellow
        Write-Host "              Use when 'the two should match'." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  A) Additive - copy source -> dest, don't delete anything on dest." -ForegroundColor Green
        Write-Host "              Safer. Use when 'add source's stuff to dest'." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  D) Dry-run  - preview only. Nothing is copied or deleted." -ForegroundColor Green
        Write-Host "              Use to see what Mirror or Additive WOULD do." -ForegroundColor DarkGray
        Write-Host ""
        do {
            $raw = Read-Host "Mode (M/A/D)"
            $answer = $raw.Trim().ToUpper()
        } while ($answer -notin @('M','A','D'))
        $Mode = switch ($answer) {
            'M' { 'Mirror' }
            'A' { 'Additive' }
            'D' { 'DryRun' }
        }
        Write-Host ""
    }

    # ------------------------------------------------------------------------
    # Confirmation
    # ------------------------------------------------------------------------
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  About to run:" -ForegroundColor Cyan
    Write-Host "    Source      : $Source" -ForegroundColor Cyan
    Write-Host "    Destination : $Destination" -ForegroundColor Cyan
    Write-Host "    Mode        : $Mode" -ForegroundColor Cyan
    if ($Mode -eq 'Mirror') {
        Write-Host "    WARNING     : Mirror will DELETE files on dest that aren't on source." -ForegroundColor Red
    }
    Write-Host "============================================================" -ForegroundColor Cyan
    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -notmatch '^(y|yes)$') {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
    Write-Host ""

    # ------------------------------------------------------------------------
    # Build robocopy args per mode
    #   /E     copy subdirs INCLUDING empty
    #   /MIR   equivalent to /E /PURGE (delete on dest what isn't on source)
    #   /L     list only (dry run) - combines with /E to preview
    #   /R:1   1 retry per file (default is 1 million)
    #   /W:1   1 second wait between retries (default is 30 seconds)
    #   /MT:16 multithreaded (fast on modern hardware)
    #   /XJ    exclude junction points (avoid infinite loops on system drives)
    #   /NDL   no directory listing (cleaner output)
    #   /NP    no progress percentages (avoids garbage carriage returns)
    #   /TEE   write to console + log file at the same time
    # ------------------------------------------------------------------------
    $baseArgs = @('/R:1','/W:1','/MT:16','/XJ','/NDL','/NP')

    switch ($Mode) {
        'Mirror'   { $modeArgs = @('/MIR') }
        'Additive' { $modeArgs = @('/E') }
        'DryRun'   { $modeArgs = @('/E','/L') }
    }

    # Log file goes next to the destination for later audit
    $logDir = if ([System.IO.Path]::IsPathRooted($Destination)) {
                 Split-Path -Parent $Destination
              } else { $env:TEMP }
    if (-not (Test-Path -LiteralPath $logDir)) { $logDir = $env:TEMP }
    $logFile = Join-Path $logDir ('iDezign_Duplicate_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')

    $roboArgs = @($Source, $Destination) + $modeArgs + $baseArgs + @("/LOG:$logFile")

    Write-Host "Running robocopy..." -ForegroundColor Green
    Write-Host "  Log: $logFile" -ForegroundColor DarkGray
    Write-Host ""

    $started = Get-Date
    & robocopy @roboArgs
    $rc = $LASTEXITCODE
    $elapsed = (Get-Date) - $started

    # ------------------------------------------------------------------------
    # Interpret robocopy exit code (it uses a bit-flag scheme, not a plain rc)
    #   0 = no files copied, no failures - up-to-date
    #   1 = files copied successfully
    #   2 = extra files/dirs found on dest (mirror candidates for deletion)
    #   4 = mismatched files/dirs
    #   8 = some files/dirs could not be copied - FAILURE
    #  16 = fatal error
    # Any combination >= 8 is a failure.
    # ------------------------------------------------------------------------
    $status = if ($rc -ge 8) { 'FAILED' } elseif ($rc -eq 0) { 'UP-TO-DATE' } else { 'OK' }
    $color  = if ($rc -ge 8) { 'Red' } elseif ($rc -eq 0) { 'DarkGray' } else { 'Green' }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ("  Duplicate {0}" -f $status) -ForegroundColor $color
    Write-Host ("  Elapsed  : {0:mm\:ss}" -f $elapsed) -ForegroundColor DarkGray
    Write-Host ("  Exit code: {0} (robocopy bitflag)" -f $rc) -ForegroundColor DarkGray
    Write-Host ("  Log      : {0}" -f $logFile) -ForegroundColor DarkGray
    Write-Host "============================================================" -ForegroundColor Cyan

    if ($rc -ge 8) {
        exit 1
    }
    exit 0

} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}
