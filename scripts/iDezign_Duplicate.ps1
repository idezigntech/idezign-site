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

$ScriptVersion = '2026.10.25-duplicate-v1.1-root-mirror-guards'

# v3.7: launched from the GUI there is no -NoExit, so the window vanishes
# the instant the script exits and the user never sees the result. Every
# exit path goes through here so they get a chance to read the screen.
function Wait-KeyThenExit {
    param([int]$Code = 0)
    Write-Host ""
    Write-Host "Press any key to close this window..." -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
    exit $Code
}

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

# v3.7: the reverse check. Mirroring C:\Photos -> C:\ would /PURGE everything
# on C:\ that isn't inside Photos (i.e. the whole drive). Same path-prefix
# logic, arguments swapped - a thin sibling so the caller reads clearly.
function Test-SourceInsideDestination {
    param([string]$Source, [string]$Destination)
    return (Test-DestinationInsideSource -Source $Destination -Destination $Source)
}

# v3.7: drive roots (E:\, F:) are the most dangerous Mirror targets - a
# wrong pick wipes a whole disk. Used to force the typed MIRROR confirmation.
function Test-DriveRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return ($Path.Trim() -match '^[A-Za-z]:\\?$')
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
        Wait-KeyThenExit 1
    }
    # v3.7: source INSIDE destination is just as bad in Mirror mode - /PURGE
    # would delete everything on the destination that isn't in the (smaller)
    # source tree. Refuse outright rather than trust a confirmation prompt.
    if (Test-SourceInsideDestination -Source $Source -Destination $Destination) {
        Write-Host "ERROR: source '$Source' is inside destination '$Destination'." -ForegroundColor Red
        Write-Host "A Mirror would delete everything on the destination outside the source tree - refusing to run." -ForegroundColor Red
        Write-Host "Pick a destination folder that is NOT a parent of the source." -ForegroundColor Yellow
        Wait-KeyThenExit 1
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

    # v3.7: a dry run used to always preview Additive (/E /L), which never
    # shows the EXTRA files Mirror would delete - the one thing a tech most
    # wants to preview. Ask which mode to simulate.
    $dryRunMirror = $false
    if ($Mode -eq 'DryRun') {
        $dm = (Read-Host "Dry-run: preview which mode? (M)irror / (A)dditive [Enter = A]").Trim().ToUpper()
        if ($dm -eq 'M') {
            $dryRunMirror = $true
            Write-Host "  Previewing MIRROR - lines marked *EXTRA are what a real Mirror would delete." -ForegroundColor DarkYellow
        } else {
            Write-Host "  Previewing ADDITIVE - nothing on the destination would be deleted." -ForegroundColor DarkGray
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
        Wait-KeyThenExit 0
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
    # v3.7: /TEE added - the header always promised it, but without it /LOG
    # swallowed all output and the console sat blank for the whole copy.
    $baseArgs = @('/R:1','/W:1','/MT:16','/XJ','/NDL','/NP','/TEE')

    switch ($Mode) {
        'Mirror'   { $modeArgs = @('/MIR') }
        'Additive' { $modeArgs = @('/E') }
        'DryRun'   { if ($dryRunMirror) { $modeArgs = @('/MIR','/L') } else { $modeArgs = @('/E','/L') } }   # v3.7
    }

    # Log file goes next to the destination for later audit
    $logDir = if ([System.IO.Path]::IsPathRooted($Destination)) {
                 Split-Path -Parent $Destination
              } else { $env:TEMP }
    # v3.7: Split-Path -Parent 'F:\' returns '' and Test-Path -LiteralPath ''
    # throws - which sent every drive-root destination into the catch block.
    # A drive root has no parent, so log onto the drive itself.
    if ([string]::IsNullOrEmpty($logDir)) { $logDir = $Destination }
    if ([string]::IsNullOrEmpty($logDir) -or -not (Test-Path -LiteralPath $logDir)) { $logDir = $env:TEMP }
    $logFile = Join-Path $logDir ('iDezign_Duplicate_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')

    # ------------------------------------------------------------------------
    # v3.7: Mirror pre-pass. Run the same /MIR as a list-only (/L) pass first
    # and count what it would purge from the destination. If anything would
    # be deleted, or the destination is a whole drive, a plain Y is not enough
    # - the tech must type MIRROR. This is the one place in the toolkit where
    # a mis-click can wipe a disk, so the friction is deliberate.
    # ------------------------------------------------------------------------
    if ($Mode -eq 'Mirror') {
        Write-Host "Mirror pre-check: listing what would be deleted on the destination..." -ForegroundColor DarkGray
        # No /NFL or /NDL here on purpose - the "*EXTRA File" / "*EXTRA Dir"
        # lines we count are part of the file/dir listing.
        $preArgs = @($Source, $Destination, '/MIR', '/L', '/R:0', '/W:0', '/XJ', '/NP', '/NJH', '/NJS')
        $preOut = & robocopy @preArgs 2>&1
        $extraFiles = @($preOut | Where-Object { $_ -match '\*EXTRA File' }).Count
        $extraDirs  = @($preOut | Where-Object { $_ -match '\*EXTRA Dir' }).Count
        $destIsRoot = Test-DriveRoot $Destination

        if (($extraFiles + $extraDirs) -gt 0) {
            Write-Host ("  Mirror would DELETE {0} extra file(s) / {1} extra dir(s) on the destination." -f $extraFiles, $extraDirs) -ForegroundColor Red
        } else {
            Write-Host "  Mirror would delete nothing on the destination (no extras found)." -ForegroundColor Green
        }
        if ($destIsRoot) {
            Write-Host "  Destination '$Destination' is a DRIVE ROOT - a Mirror here rewrites the whole drive." -ForegroundColor Red
        }

        if ((($extraFiles + $extraDirs) -gt 0) -or $destIsRoot) {
            Write-Host ""
            Write-Host "  To proceed, type MIRROR (all caps, exact). Anything else aborts." -ForegroundColor Yellow
            $typed = Read-Host "  Confirm"
            if ($typed -cne 'MIRROR') {
                Write-Host "Aborted - nothing was changed." -ForegroundColor Yellow
                Wait-KeyThenExit 0
            }
        }
        Write-Host ""
    }

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

    # v3.7: pause before every exit so the GUI-launched window stays readable.
    if ($rc -ge 8) {
        Wait-KeyThenExit 1
    }
    Wait-KeyThenExit 0

} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Wait-KeyThenExit 2
}
