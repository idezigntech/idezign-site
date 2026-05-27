# ============================================================================
#  iDezign_SavePDF.ps1
#  Saves the latest iDezign Diagnostics report as a PDF on the Desktop.
#  Uses Microsoft Edge's built-in headless print-to-PDF (no extra software).
#  Launched from the toolkit menu like any other tool.
# ============================================================================

$ScriptVersion = '2026.05.25-savepdf-v1'

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   iDezign - Save Diagnostics report as PDF" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# --- Locate Microsoft Edge (the PDF engine) ---------------------------------
$edgeCandidates = @(
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
)
if (${env:ProgramFiles(x86)}) {
    $edgeCandidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
}
$edge = $edgeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) {
    Write-Host "  ERROR: Microsoft Edge was not found, so a PDF can't be created." -ForegroundColor Red
    Write-Host "  (Edge ships with Windows 10/11; this machine may be unusual.)" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to close"
    exit 1
}

# --- Find the latest Diagnostics HTML report --------------------------------
$diagDir = 'C:\iDezign_Diagnostics'
$html = Join-Path $diagDir 'Diagnostics_Latest.html'
if (-not (Test-Path $html)) {
    $newest = Get-ChildItem -Path (Join-Path $diagDir 'Diagnostics_*.html') -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) { $html = $newest.FullName }
}
if (-not (Test-Path $html)) {
    Write-Host "  No Diagnostics report found in $diagDir." -ForegroundColor Yellow
    Write-Host "  Run Diagnostics first, then come back and save the PDF." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to close"
    exit 0
}

Write-Host "  Report : $html" -ForegroundColor DarkGray

# --- Build the output path on the Desktop -----------------------------------
$desktop = [Environment]::GetFolderPath('Desktop')
$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmm'
$pdf     = Join-Path $desktop ("iDezign_Diagnostics_{0}.pdf" -f $stamp)
$uri     = 'file:///' + ($html -replace '\\','/')

Write-Host "  Output : $pdf" -ForegroundColor DarkGray
Write-Host "  Creating PDF (Edge headless)..." -ForegroundColor Cyan

# --- Convert via headless Edge ----------------------------------------------
# Quotes are embedded in the path arguments so Desktop paths with spaces work.
try {
    Start-Process -FilePath $edge -Wait -WindowStyle Hidden -ArgumentList @(
        '--headless',
        '--disable-gpu',
        '--no-first-run',
        ('--print-to-pdf="{0}"' -f $pdf),
        ('"{0}"' -f $uri)
    )
} catch {
    Write-Host "  ERROR launching Edge: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to close"
    exit 1
}

# Edge headless can finish writing a moment after exit - wait briefly.
$tries = 0
while (-not (Test-Path $pdf) -and $tries -lt 20) { Start-Sleep -Milliseconds 250; $tries++ }

Write-Host ""
if (Test-Path $pdf) {
    $kb = [math]::Round((Get-Item $pdf).Length / 1KB, 0)
    Write-Host "  SUCCESS - saved to your Desktop:" -ForegroundColor Green
    Write-Host "    $pdf  ($kb KB)" -ForegroundColor Green
    try { Start-Process explorer.exe ('/select,"{0}"' -f $pdf) } catch { }
} else {
    Write-Host "  The PDF was not produced. Try opening the report in Edge and" -ForegroundColor Red
    Write-Host "  using Print -> Save as PDF manually:" -ForegroundColor Red
    Write-Host "    $html" -ForegroundColor DarkGray
}
Write-Host ""
Read-Host "  Press Enter to close"
