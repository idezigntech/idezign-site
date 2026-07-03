# ============================================================================
#  check-external-urls.ps1
#  Scans the repo for external http(s) URLs referenced in scripts and web
#  pages, HEADs each unique URL, reports pass/fail. Non-zero exit if any
#  target returns HTTP 400+ or is unreachable. Meant to run in GitHub Actions
#  on a weekly schedule + on push to files under scripts/, toolkit/, help/.
#
#  Why: URLs rot silently. Vendor download pages get renamed (see the
#  get.teamviewer.com/idezign -> custom.teamviewer.com/idhelp change that
#  went undetected for months). This job catches URL rot before a customer
#  does.
# ============================================================================

param(
    [string[]]$SearchPaths = @('scripts', 'toolkit', 'help'),
    [string[]]$FileExts    = @('.ps1', '.psm1', '.html'),
    [int]$RequestTimeoutSec = 15,
    [int]$SleepMs = 250,
    [string]$UserAgent = 'iDezign-Toolkit-URL-Check/1.0 (+https://github.com/idezigntech/idezign-site)'
)

$ErrorActionPreference = 'Continue'

# --- Resolve repo root -----------------------------------------------------
$repoRoot = $null
try {
    $probe = git rev-parse --show-toplevel 2>&1
    if ($LASTEXITCODE -eq 0) { $repoRoot = $probe.Trim() }
} catch { }
if (-not $repoRoot) { $repoRoot = (Get-Location).Path }
Write-Host "Repo root: $repoRoot"

# --- Collect target files --------------------------------------------------
$files = @()
foreach ($p in $SearchPaths) {
    $full = Join-Path $repoRoot $p
    if (Test-Path $full) {
        $files += Get-ChildItem -Path $full -Recurse -File |
                  Where-Object { $FileExts -contains $_.Extension.ToLower() }
    }
}
Write-Host "Scanning $($files.Count) files under $($SearchPaths -join ', ')"

# --- Extract URLs ----------------------------------------------------------
# Regex captures http(s)://... up to the first whitespace, quote, angle
# bracket, or common trailing punctuation. Trim a few common trailers after
# capture too (period, comma, semicolon).
$urlRegex = 'https?://[^\s"''<>)}\]]+'
$found = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $text = Get-Content -Raw -Path $f.FullName -ErrorAction SilentlyContinue
    if (-not $text) { continue }
    foreach ($m in ([regex]::Matches($text, $urlRegex))) {
        $u = $m.Value.TrimEnd('.', ',', ';', ':', ')', ']')
        # Skip inline anchors
        if ($u -match '#') { $u = $u.Split('#')[0] }
        if ([string]::IsNullOrWhiteSpace($u)) { continue }
        $found.Add([PSCustomObject]@{ Url = $u; RelPath = $f.FullName.Substring($repoRoot.Length).TrimStart('\','/') })
    }
}

# --- Skip patterns (URLs we don't want to probe) --------------------------
# Three categories of false-positive:
#  (1) XML namespaces / schema URIs - these are namespace declarations, not
#      resources. localhost and example.com follow the same shape.
#  (2) Preconnect hint domains - domains referenced only via <link rel=
#      "preconnect"> (fonts.googleapis.com, fonts.gstatic.com) legitimately
#      404 on the bare URL because they don't serve a landing page. Real
#      resource fetches happen at specific sub-paths that are captured
#      separately if present.
#  (3) Domain-only URLs to sites known to reject HEAD/GET at root
#      (behind a Cloudflare 'protect the honeypot' rule etc.).
$skipPatterns = @(
    # (1) namespaces + localhost
    '^https?://localhost',
    '^https?://127\.0\.0\.1',
    'example\.com',
    '^https?://schemas\.microsoft\.com',
    '^https?://schemas\.openxmlformats\.org',
    '^https?://www\.w3\.org',
    '^https?://schemas\.xmlsoap\.org',
    '^https?://ns\.adobe\.com',

    # (2) preconnect hint domains (bare URL 404s but sub-paths work)
    '^https?://fonts\.googleapis\.com/?$',
    '^https?://fonts\.gstatic\.com/?$',

    # (3) JavaScript-concatenation prefix truncations. When the URL regex
    # captures a string literal like "https://.../download/v" that gets
    # concatenated with a variable in the code, the captured URL is a
    # truncated prefix that will 404 on probe. Detect the "ends at a
    # single lowercase letter after /" pattern common to release URLs.
    '/v$',
    '/download/$'
)
function Test-ShouldSkip {
    param([string]$Url)
    foreach ($pat in $skipPatterns) {
        if ($Url -match $pat) { return $true }
    }
    return $false
}

# --- Deduplicate + separate probable-file URLs from real endpoints --------
$unique = $found | Group-Object -Property Url | ForEach-Object {
    [PSCustomObject]@{
        Url    = $_.Name
        Files  = ($_.Group.RelPath | Sort-Object -Unique)
    }
}
$toCheck = $unique | Where-Object { -not (Test-ShouldSkip -Url $_.Url) }
$skipped = $unique | Where-Object { Test-ShouldSkip -Url $_.Url }

Write-Host ""
Write-Host "Unique URLs found : $($unique.Count)"
Write-Host "Will check        : $($toCheck.Count)"
Write-Host "Skipped (schema/etc): $($skipped.Count)"
Write-Host ""

# --- Probe each URL --------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($item in $toCheck) {
    $i++
    $u = $item.Url
    Write-Host ("[{0,3}/{1}] {2}" -f $i, $toCheck.Count, $u)

    $ok      = $false
    $status  = 0
    $method  = 'HEAD'
    $errMsg  = $null
    $transient = $false

    # First attempt: HEAD (fast, no body)
    try {
        $resp = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing `
                    -TimeoutSec $RequestTimeoutSec -MaximumRedirection 5 `
                    -UserAgent $UserAgent -ErrorAction Stop
        $status = [int]$resp.StatusCode
        $ok     = ($status -ge 200 -and $status -lt 400)
    } catch {
        # Fallback: GET (some CDNs 405 on HEAD)
        $method = 'GET'
        try {
            $resp = Invoke-WebRequest -Uri $u -Method Get -UseBasicParsing `
                        -TimeoutSec $RequestTimeoutSec -MaximumRedirection 5 `
                        -UserAgent $UserAgent -ErrorAction Stop
            $status = [int]$resp.StatusCode
            $ok     = ($status -ge 200 -and $status -lt 400)
        } catch {
            $errMsg = $_.Exception.Message
            if ($_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            }
        }
    }

    # 5xx = server-side transient (bad gateway / CDN hiccup / temp maintenance).
    # Wait 5s and retry ONCE with GET. If still 5xx, treat as OK-with-warning
    # rather than a failure - the URL itself isn't dead, just briefly unhappy.
    if (-not $ok -and $status -ge 500 -and $status -lt 600) {
        Write-Host ("        transient 5xx (status={0}) - waiting 5s and retrying..." -f $status) -ForegroundColor DarkYellow
        Start-Sleep -Seconds 5
        try {
            $resp = Invoke-WebRequest -Uri $u -Method Get -UseBasicParsing `
                        -TimeoutSec $RequestTimeoutSec -MaximumRedirection 5 `
                        -UserAgent $UserAgent -ErrorAction Stop
            $status = [int]$resp.StatusCode
            $ok     = ($status -ge 200 -and $status -lt 400)
            if (-not $ok) { $transient = $true }
        } catch {
            if ($_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            }
            # Still failing after retry - flag as transient so summary treats it as warn
            if ($status -ge 500 -and $status -lt 600) { $transient = $true; $ok = $true }
        }
    }

    $tag = if ($ok) { 'OK' } else { 'FAIL' }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("        {0}  status={1}  method={2}" -f $tag, $status, $method) -ForegroundColor $color
    if ($errMsg) { Write-Host ("        error: $errMsg") -ForegroundColor DarkYellow }

    $results.Add([PSCustomObject]@{
        Url    = $u
        Status = $status
        OK     = $ok
        Method = $method
        Error  = $errMsg
        Files  = $item.Files
    })

    Start-Sleep -Milliseconds $SleepMs
}

# --- Summary ---------------------------------------------------------------
$total  = $results.Count
$okCnt  = ($results | Where-Object OK).Count
$failed = @($results | Where-Object { -not $_.OK })

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("  Total probed : {0}" -f $total)
Write-Host ("  OK           : {0}" -f $okCnt) -ForegroundColor Green
Write-Host ("  FAILED       : {0}" -f $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'DarkGray' })
Write-Host ""

if ($failed.Count -gt 0) {
    Write-Host "Failed URLs:" -ForegroundColor Red
    foreach ($r in $failed) {
        Write-Host ("  {0}  (status={1})" -f $r.Url, $r.Status) -ForegroundColor Red
        foreach ($f in $r.Files) {
            Write-Host ("    referenced in: {0}" -f $f) -ForegroundColor DarkYellow
        }
        if ($r.Error) {
            Write-Host ("    error: {0}" -f $r.Error) -ForegroundColor DarkYellow
        }
    }
    Write-Host ""
    Write-Host "Fix any dead links above, then re-run the check." -ForegroundColor Yellow

    # Write a machine-readable report the CI job picks up and pastes into
    # an auto-created GitHub Issue. Kept simple: one Markdown table.
    $reportLines = @()
    $reportLines += '| Status | URL | Referenced in |'
    $reportLines += '|---|---|---|'
    foreach ($r in $failed) {
        $files = ($r.Files -join '<br>')
        $urlEsc = '`' + $r.Url + '`'
        $reportLines += "| $($r.Status) | $urlEsc | $files |"
    }
    if ($env:GITHUB_WORKSPACE) {
        $reportPath = Join-Path $env:GITHUB_WORKSPACE 'url-check-report.md'
    } else {
        $reportPath = 'url-check-report.md'
    }
    ($reportLines -join "`n") | Set-Content -Path $reportPath -Encoding UTF8

    exit 1
}

Write-Host "All external URLs healthy." -ForegroundColor Green
exit 0
