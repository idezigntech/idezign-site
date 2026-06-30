# ============================================================================
#  iDezign_Remediation.ps1
#  Companion to iDezign_Diagnostics.ps1
#  Walks through identified issues one at a time, asks Y/N for each fix,
#  and generates hardware replacement recommendations with customer-facing
#  email language where appropriate.
#
#  This is an INTERACTIVE script. Every action requires explicit consent.
#  Run as Administrator.
# ============================================================================
#  Tiers of action:
#    Tier 1 (LOW risk)    : start services, flush DNS, update sigs, scan
#    Tier 2 (MEDIUM risk) : reset WU components, winsock reset, sfc/dism
#    Tier 3 (RECOMMEND)   : hardware replacement / upgrade advice only
#
#  Output:
#    C:\iDezign_Remediation\Actions_YYYY-MM-DD_HHmm.txt
# ============================================================================

#region --- Safety + setup ---------------------------------------------------

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Use Run-Remediation.bat (it self-elevates) or right-click -> Run with PowerShell as Admin." -ForegroundColor Yellow
    Pause
    exit 1
}

$ErrorActionPreference = 'Continue'

# Version stamp - bumped when behavior changes. Shown in console banner
# and recorded in transcript log so we can verify deployed version.
$ScriptVersion = '2026.06.30-v3.0-pdf-merge'

# Load shared module if present (non-fatal if missing - the script has its
# own copy of needed functions as fallback).
$ModulePath = Join-Path $PSScriptRoot 'iDezign_Common.psm1'
if (Test-Path $ModulePath) {
    Import-Module $ModulePath -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "(note: iDezign_Common.psm1 not found alongside script - using built-in functions)" -ForegroundColor DarkYellow
}

# Server detection - gate destructive remediations behind extra confirmations.
$ServerInfo = $null
if (Get-Command Get-ServerOSDetails -ErrorAction SilentlyContinue) {
    $ServerInfo = Get-ServerOSDetails
} else {
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

$RemediationDir = 'C:\iDezign_Remediation'
$DiagDir        = 'C:\iDezign_Diagnostics'
$SnapshotDir    = Join-Path $DiagDir 'snapshots'
$Timestamp      = Get-Date -Format 'yyyy-MM-dd_HHmm'
$ActionLog      = Join-Path $RemediationDir "Actions_$Timestamp.txt"

if (-not (Test-Path $RemediationDir)) { New-Item -Path $RemediationDir -ItemType Directory -Force | Out-Null }

# Action log accumulator. One line per action attempted, no before/after.
$logLines = New-Object System.Collections.Generic.List[string]
function Write-Action {
    param([string]$Text)
    $stamp = (Get-Date -Format 'HH:mm:ss')
    $line  = "[$stamp] $Text"
    $logLines.Add($line) | Out-Null
}

# Track counters for the final summary
$script:ActionsTaken    = 0
$script:ActionsSkipped  = 0
$script:Recommendations = 0

# Lists of WHAT was done, for the end-of-run summary. Counters tell you "how
# many", these lists tell you "which ones". The handlers still own incrementing
# the counters; the main loop owns adding titles to these lists.
$script:FixedList          = New-Object System.Collections.Generic.List[string]
$script:SkippedList        = New-Object System.Collections.Generic.List[string]
$script:RecommendationList = New-Object System.Collections.Generic.List[string]

#endregion

#region --- Banner -----------------------------------------------------------

Clear-Host
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  iDezign Remediation - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "  Version: $ScriptVersion$(if(Get-Command Get-iDezignCommonVersion -EA SilentlyContinue){"  |  module: $(Get-iDezignCommonVersion)"})" -ForegroundColor DarkGray
Write-Host "  Computer: $env:COMPUTERNAME   User: $env:USERNAME" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Each proposed fix will ask Y/N. No fix runs without your OK." -ForegroundColor DarkGray
Write-Host "  Press Q at any prompt to quit (actions so far are logged)." -ForegroundColor DarkGray
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Big yellow server banner if applicable. Lists what's gated and disabled.
if ($IsServer) {
    if (Get-Command Show-ServerWarning -ErrorAction SilentlyContinue) {
        $disabled = @()
        $gated    = @('Winsock/IP reset (kills active RDP/SMB/SQL connections)',
                      'Auto-reboot (would interrupt production users)')
        if ($IsDC) {
            $disabled += 'Local account remediations (DCs use domain accounts)'
        }
        Show-ServerWarning -ServerInfo $ServerInfo -ToolName 'Remediation' `
                           -Disabled $disabled -Gated $gated
    }
}

#endregion

#region --- Snapshot source: re-scan or read latest? ------------------------

$latestSnap = $null
if (Test-Path $SnapshotDir) {
    $latestSnap = Get-ChildItem $SnapshotDir -Filter 'Snapshot_*.json' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

$snapshot = $null
$snapSource = 'live re-scan'

if ($latestSnap) {
    $ageMin = [int]((Get-Date) - $latestSnap.LastWriteTime).TotalMinutes
    Write-Host "  Most recent diagnostics snapshot: $($latestSnap.Name)" -ForegroundColor DarkGray
    Write-Host "  Age: $ageMin minute(s) old" -ForegroundColor DarkGray
    Write-Host ""

    if ($ageMin -le 30) {
        $ans = Read-Host "  Use this snapshot? (Y = use it, N = re-scan now)"
        if ($ans -match '^(y|yes|)$') {
            try {
                $snapshot = Get-Content $latestSnap.FullName -Raw | ConvertFrom-Json
                $snapSource = "snapshot ($ageMin min old)"
            } catch {
                Write-Host "  Could not read snapshot - will re-scan instead." -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "  Snapshot is older than 30 minutes - re-scanning is recommended." -ForegroundColor Yellow
        $ans = Read-Host "  Re-scan now? (Y/N)  [Y]"
        if ($ans -match '^(n|no)$') {
            try {
                $snapshot = Get-Content $latestSnap.FullName -Raw | ConvertFrom-Json
                $snapSource = "snapshot ($ageMin min old)"
            } catch { }
        }
    }
} else {
    Write-Host "  No prior diagnostics snapshot found." -ForegroundColor Yellow
    Write-Host "  Will run live checks now (limited - run iDezign_Diagnostics.ps1 first for full picture)." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  Source: $snapSource" -ForegroundColor DarkGray
Write-Action "Source for issue list: $snapSource"

#endregion

#region --- Helpers ----------------------------------------------------------

function Ask-YN {
    # Returns 'Y', 'N', or 'Q'
    param([string]$Prompt = "Apply this fix? (Y/N/Q=quit)")
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

function Show-IssueHeader {
    param([int]$Num, [int]$Total, [string]$Title, [string]$Tier, [string]$Risk)
    Write-Host ""
    Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ("  ISSUE {0} of {1} : {2}" -f $Num, $Total, $Title) -ForegroundColor Cyan
    Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  Tier: $Tier   Risk: $Risk" -ForegroundColor DarkGray
}

function Test-PendingReboot {
    $signals = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')   { $signals += 'CBS RebootPending' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')  { $signals += 'WindowsUpdate RebootRequired' }
    $sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    if ($sm -and $sm.PendingFileRenameOperations) { $signals += 'PendingFileRenameOperations' }
    if (Test-Path 'C:\Windows\WinSxS\pending.xml') { $signals += 'pending.xml exists' }
    return $signals
}

function Write-Check {
    param([string]$Label)
    Write-Host ("    checking {0} ..." -f $Label) -ForegroundColor DarkGray
}

# Builds the list of actionable issues, either from a snapshot or live.
# Each issue is a hashtable with: Title, Tier, Risk, Type, Data
# Type drives which remediation function gets called.
function Build-IssueList {
    param($Snap)

    $issues = New-Object System.Collections.Generic.List[hashtable]

    Write-Host ""
    Write-Host "  Running health checks..." -ForegroundColor Cyan

    # --- Essential services (live check - cheap and authoritative) ---
    Write-Check 'essential Windows services'
    # NOTE: BITS intentionally omitted - per Eric's preference, false positives
    # on healthy boxes outweigh the value. (Mirrors the diagnostics tool.)
    # Only AUTOMATIC services that are stopped are genuine problems. Manual /
    # trigger-start services (e.g. msiserver, and wuauserv on Win10/11) are
    # SUPPOSED to sit stopped until something needs them - flagging those was
    # noise, so they're excluded and the filter requires StartType = Automatic.
    $essentials = @('WinDefend','RpcSs','Dhcp','Dnscache','LanmanServer','LanmanWorkstation','Schedule','CryptSvc')
    foreach ($e in $essentials) {
        $s = Get-Service -Name $e -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne 'Running' -and $s.StartType -eq 'Automatic') {
            $issues.Add(@{
                Title = "Essential service '$e' is $($s.Status)"
                Tier  = 1; Risk = 'LOW'
                Type  = 'StartService'
                Data  = @{ Name = $e }
            })
        }
    }

    # --- Defender state ---
    Write-Check 'Windows Defender'
    $mp = $null
    try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { }
    if ($mp) {
        if (-not $mp.AntivirusEnabled) {
            $issues.Add(@{
                Title = "Defender antivirus is DISABLED"
                Tier  = 2; Risk = 'MEDIUM'
                Type  = 'EnableDefender'
                Data  = @{}
            })
        }
        if ($mp.AntivirusEnabled -and -not $mp.RealTimeProtectionEnabled) {
            $issues.Add(@{
                Title = "Defender real-time protection is OFF"
                Tier  = 2; Risk = 'MEDIUM'
                Type  = 'EnableRealTime'
                Data  = @{}
            })
        }
        if ($mp.AntispywareSignatureLastUpdated) {
            $age = [int]((Get-Date) - $mp.AntispywareSignatureLastUpdated).TotalDays
            if ($age -gt 7) {
                $issues.Add(@{
                    Title = "Defender signatures $age days old"
                    Tier  = 1; Risk = 'LOW'
                    Type  = 'UpdateSigs'
                    Data  = @{ AgeDays = $age }
                })
            }
        }
    }

    # --- DNS / network (use snapshot if available, otherwise live) ---
    Write-Check 'DNS & network'
    $dnsBad = $false; $dnsMs = $null; $internetBad = $false; $gatewayBad = $false
    if ($Snap -and $Snap.Network) {
        $dnsBad      = ($Snap.Network.DNSOk -eq $false)
        $dnsMs       = $Snap.Network.DNSms
        $internetBad = ($Snap.Network.InternetOk -eq $false)
        $gatewayBad  = ($Snap.Network.GatewayPing -eq $false)
    } else {
        # Quick live probe
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $null = Resolve-DnsName -Name 'www.microsoft.com' -Type A -ErrorAction Stop -QuickTimeout
            $sw.Stop(); $dnsMs = $sw.ElapsedMilliseconds
            if ($dnsMs -gt 1000) { $dnsBad = $true }
        } catch { $dnsBad = $true }
    }
    if ($dnsBad) {
        $issues.Add(@{
            Title = "DNS resolution failed or slow$(if($dnsMs){" ($dnsMs ms)"})"
            Tier  = 2; Risk = 'MEDIUM'
            Type  = 'FixDNS'
            Data  = @{ Ms = $dnsMs }
        })
    }
    if ($internetBad) {
        $issues.Add(@{
            Title = "HTTPS internet reach failed"
            Tier  = 2; Risk = 'MEDIUM'
            Type  = 'ResetNetwork'
            Data  = @{}
        })
    }

    # --- Pending reboot (always live) ---
    Write-Check 'pending reboot'
    $pending = Test-PendingReboot
    if ($pending.Count -gt 0) {
        $issues.Add(@{
            Title = "Reboot is pending: $($pending -join '; ')"
            Tier  = 1; Risk = 'LOW'
            Type  = 'Reboot'
            Data  = @{ Signals = $pending }
        })
    }

    # --- Filesystem corruption signals (always live) ---
    Write-Check 'filesystem integrity'
    # We flag chkdsk as a remediation when EITHER of these is true on any
    # local fixed volume:
    #   (a) Dirty bit is set (fsutil dirty query)
    #   (b) NTFS source errors in System log within last 30 days
    #       - Event ID 55  : NTFS corruption detected
    #       - Event ID 130 : Volume needs to be checked
    #       - Event ID 137 : Transactional resource manager metadata corrupt
    # SMART failures or read errors get a separate "replace drive" track -
    # chkdsk doesn't help with hardware failure.
    try {
        $fixedVols = Get-Volume -ErrorAction Stop | Where-Object {
            $_.DriveType -eq 'Fixed' -and
            $_.DriveLetter -and
            $_.FileSystem -match 'NTFS|ReFS'
        }

        $cutoff = (Get-Date).AddDays(-30)
        $ntfsEvents = $null
        try {
            $ntfsEvents = Get-WinEvent -FilterHashtable @{
                LogName='System'
                ProviderName='Ntfs','Microsoft-Windows-Ntfs'
                Level=1,2,3   # Critical, Error, Warning
                StartTime=$cutoff
            } -ErrorAction SilentlyContinue
        } catch { }

        foreach ($v in $fixedVols) {
            $letter = "$($v.DriveLetter):"

            # (a) Dirty bit check
            $dirty = $false
            try {
                $out = & fsutil dirty query $letter 2>&1
                if ($LASTEXITCODE -eq 0 -and $out -match 'is Dirty' -and $out -notmatch 'is NOT Dirty') {
                    $dirty = $true
                }
            } catch { }

            # (b) NTFS error events specifically for this volume
            $volEvents = $null
            if ($ntfsEvents) {
                $volEvents = $ntfsEvents | Where-Object {
                    $_.Id -in 55,130,137 -and
                    ($_.Message -match [regex]::Escape($letter) -or $_.Message -match "Volume $($v.DriveLetter)")
                }
            }
            $eventCount = ($volEvents | Measure-Object).Count

            if ($dirty -or $eventCount -gt 0) {
                $reasons = @()
                if ($dirty)            { $reasons += "dirty bit set" }
                if ($eventCount -gt 0) { $reasons += "$eventCount NTFS error(s) in last 30d" }

                # System volume vs data volume changes the risk profile
                $isSystem = ($letter -eq "$env:SystemDrive")
                $tier = if ($isSystem) { 2 } else { 2 }
                $risk = if ($isSystem) { 'MEDIUM (reboot required)' } else { 'MEDIUM' }

                $issues.Add(@{
                    Title = "Filesystem may be corrupt on $letter ($($reasons -join ', '))"
                    Tier  = $tier; Risk = $risk
                    Type  = 'Chkdsk'
                    Data  = @{
                        Drive      = $letter
                        IsSystem   = $isSystem
                        Dirty      = $dirty
                        EventCount = $eventCount
                        Reasons    = $reasons
                    }
                })
            }
        }
    } catch {
        # Filesystem check failure isn't fatal - just skip this issue type.
    }

    # --- Hardware: disk health (snapshot or live) ---
    Write-Check 'disk health (SMART)'
    if ($Snap -and $Snap.Disks) {
        foreach ($d in $Snap.Disks) {
            if ($d.Health -ne 'Healthy') {
                $issues.Add(@{
                    Title = "Disk '$($d.Name)' health = $($d.Health) - failing"
                    Tier  = 3; Risk = 'RECOMMEND'
                    Type  = 'ReplaceDrive'
                    Data  = @{ Name=$d.Name; Reason="Health status: $($d.Health)"; SizeGB=$d.SizeGB }
                })
            }
            if ($d.Wear -and [int]$d.Wear -ge 80) {
                $issues.Add(@{
                    Title = "SSD '$($d.Name)' wear at $($d.Wear)% - end of life"
                    Tier  = 3; Risk = 'RECOMMEND'
                    Type  = 'ReplaceDrive'
                    Data  = @{ Name=$d.Name; Reason="SSD wear level: $($d.Wear)%"; SizeGB=$d.SizeGB }
                })
            } elseif ($d.Wear -and [int]$d.Wear -ge 60) {
                $issues.Add(@{
                    Title = "SSD '$($d.Name)' wear at $($d.Wear)% - plan replacement"
                    Tier  = 3; Risk = 'RECOMMEND'
                    Type  = 'PlanReplaceDrive'
                    Data  = @{ Name=$d.Name; Wear=$d.Wear; SizeGB=$d.SizeGB }
                })
            }
            if ($d.ReadErrors -and [int]$d.ReadErrors -gt 0) {
                $issues.Add(@{
                    Title = "Disk '$($d.Name)' has $($d.ReadErrors) read errors"
                    Tier  = 3; Risk = 'RECOMMEND'
                    Type  = 'ReplaceDrive'
                    Data  = @{ Name=$d.Name; Reason="$($d.ReadErrors) read errors logged"; SizeGB=$d.SizeGB }
                })
            }
        }
    } else {
        # Live disk health
        try {
            $disks = Get-PhysicalDisk -ErrorAction Stop
            foreach ($d in $disks) {
                if ($d.HealthStatus -ne 'Healthy') {
                    $issues.Add(@{
                        Title = "Disk '$($d.FriendlyName)' health = $($d.HealthStatus) - failing"
                        Tier  = 3; Risk = 'RECOMMEND'
                        Type  = 'ReplaceDrive'
                        Data  = @{ Name=$d.FriendlyName; Reason="Health status: $($d.HealthStatus)"; SizeGB=[math]::Round($d.Size/1GB,0) }
                    })
                }
                $rel = $null
                try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
                if ($rel.Wear -and [int]$rel.Wear -ge 80) {
                    $issues.Add(@{
                        Title = "SSD '$($d.FriendlyName)' wear at $($rel.Wear)%"
                        Tier  = 3; Risk = 'RECOMMEND'
                        Type  = 'ReplaceDrive'
                        Data  = @{ Name=$d.FriendlyName; Reason="SSD wear: $($rel.Wear)%"; SizeGB=[math]::Round($d.Size/1GB,0) }
                    })
                }
            }
        } catch { }
    }

    # --- Hardware: RAM ---
    Write-Check 'memory (RAM)'
    # Multiple gotchas this guards against:
    #   1. Hyper-V VMs with Dynamic Memory report current allocation, not configured
    #      max - a VM ballooned down to 2.5 GB while idle should NOT flag.
    #   2. Hardware target should be role-aware: 8 GB is reasonable for a
    #      single-user dental workstation, 16 GB+ for a Server 2022 box running
    #      Dentrix SQL.
    #   3. Win32_PhysicalMemory + Win32_ComputerSystem.TotalPhysicalMemory give
    #      installed hardware RAM, which is what we care about on bare metal.
    $totalGB     = $null
    $isVM        = $false
    $vmModel     = $null
    try {
        $cs       = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        $os       = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

        # Prefer Win32_ComputerSystem.TotalPhysicalMemory (actual installed hardware)
        # over Win32_OperatingSystem.TotalVisibleMemorySize (current OS-visible,
        # affected by dynamic memory balloon state).
        if ($cs -and $cs.TotalPhysicalMemory) {
            $totalGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        } elseif ($os -and $os.TotalVisibleMemorySize) {
            $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1024 / 1024, 1)
        }

        # VM detection - any of these models means we're in a guest, and current
        # RAM reading may be balloon-driven rather than reflective of host capacity.
        if ($cs) {
            $vmModel = "$($cs.Manufacturer) / $($cs.Model)"
            $vmSignatures = @(
                'Virtual Machine',          # Hyper-V
                'VMware',                   # VMware Workstation/ESXi
                'VirtualBox',               # Oracle
                'KVM',                      # Linux KVM
                'Xen',                      # Citrix/AWS
                'QEMU',                     # Generic QEMU
                'Parallels'                 # Mac Parallels
            )
            foreach ($sig in $vmSignatures) {
                if (($cs.Model -like "*$sig*") -or ($cs.Manufacturer -like "*$sig*")) {
                    $isVM = $true
                    break
                }
            }
        }
    } catch { }

    # Role-aware target. Server-class machines need more headroom than
    # single-user workstations. The "urgent" threshold is the floor below
    # which the system is genuinely struggling; the "recommended" threshold
    # is the realistic target for the role.
    $isServerRole = $false
    try { $isServerRole = [bool](Get-IsServerOS) } catch { }

    if ($isServerRole) {
        $ramFloor   = 8   # below this on a server = urgent
        $ramTarget  = 16  # realistic target for a server
    } else {
        $ramFloor   = 4   # below this on a workstation = urgent
        $ramTarget  = 8   # realistic target for a dental/legal workstation
    }

    if ($totalGB -and -not $isVM) {
        # Bare metal - apply role-aware thresholds normally.
        if ($totalGB -lt $ramFloor) {
            $issues.Add(@{
                Title = "Only $totalGB GB RAM installed - upgrade required (target: $ramTarget GB)"
                Tier  = 3; Risk = 'RECOMMEND'
                Type  = 'UpgradeRAM'
                Data  = @{ Current=$totalGB; Target=$ramTarget; Urgent=$true; Role=$(if($isServerRole){'server'}else{'workstation'}) }
            })
        } elseif ($totalGB -lt $ramTarget) {
            # Only flag if there's ALSO observed memory pressure - having
            # 6 GB on a quiet workstation isn't worth alarming about.
            $memPressure = $false
            if ($Snap -and $Snap.MemoryCPU -and $Snap.MemoryCPU.FreeRAM_MB -lt 1024) { $memPressure = $true }
            if ($memPressure) {
                $issues.Add(@{
                    Title = "$totalGB GB RAM + low free RAM observed - upgrade recommended (target: $ramTarget GB)"
                    Tier  = 3; Risk = 'RECOMMEND'
                    Type  = 'UpgradeRAM'
                    Data  = @{ Current=$totalGB; Target=$ramTarget; Urgent=$false; Role=$(if($isServerRole){'server'}else{'workstation'}) }
                })
            }
        }
    } elseif ($isVM) {
        # In a VM, current memory reading is unreliable (dynamic balloon).
        # Don't flag a RAM upgrade against the customer - the host admin
        # controls VM memory, not the toolkit.  Just log informationally.
        Write-Verbose "RAM check skipped: running in VM ($vmModel), current = $totalGB GB. Adjust on the host, not the guest."
    }

    # --- Hardware: unexpected shutdowns + BSODs ---
    Write-Check 'crash history'
    if ($Snap -and $Snap.Events) {
        if ($Snap.Events.UnexpectedShutdowns -ge 3) {
            $issues.Add(@{
                Title = "$($Snap.Events.UnexpectedShutdowns) unexpected shutdowns in 7 days"
                Tier  = 3; Risk = 'RECOMMEND'
                Type  = 'HardwareInvestigate'
                Data  = @{ Reason='unexpected shutdowns'; Count=$Snap.Events.UnexpectedShutdowns }
            })
        }
        if ($Snap.Events.CrashDumps -ge 2) {
            $issues.Add(@{
                Title = "$($Snap.Events.CrashDumps) BSOD crash dumps in 7 days"
                Tier  = 3; Risk = 'RECOMMEND'
                Type  = 'HardwareInvestigate'
                Data  = @{ Reason='BSOD crashes'; Count=$Snap.Events.CrashDumps }
            })
        }
    }

    # --- Hardware: install age ---
    Write-Check 'Windows install age'
    if ($Snap -and $Snap.System -and $Snap.System.InstallAge -gt 1825) {
        $issues.Add(@{
            Title = "Windows install is $($Snap.System.InstallAge) days old (>5 years)"
            Tier  = 3; Risk = 'RECOMMEND'
            Type  = 'ConsiderReinstall'
            Data  = @{ AgeDays = $Snap.System.InstallAge }
        })
    }

    # --- Dentrix-specific ---
    Write-Check 'Dentrix services'
    $dentrixSvcs = Get-Service -ErrorAction SilentlyContinue | Where-Object {
        ($_.Name -match 'Dentrix' -or $_.DisplayName -match 'Dentrix') -and
        $_.Status -ne 'Running' -and $_.StartType -eq 'Automatic'
    }
    foreach ($s in $dentrixSvcs) {
        $issues.Add(@{
            Title = "Dentrix service '$($s.Name)' is $($s.Status)"
            Tier  = 2; Risk = 'MEDIUM'
            Type  = 'StartDentrixService'
            Data  = @{ Name = $s.Name }
        })
    }

    # SQL Server instances (Dentrix backend)
    Write-Check 'SQL Server (Dentrix backend)'
    $sqlSvcs = Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^MSSQL\$' -and $_.Status -ne 'Running' -and $_.StartType -eq 'Automatic'
    }
    foreach ($s in $sqlSvcs) {
        $issues.Add(@{
            Title = "SQL Server instance '$($s.Name)' is $($s.Status) (Dentrix backend)"
            Tier  = 2; Risk = 'MEDIUM'
            Type  = 'StartSQL'
            Data  = @{ Name = $s.Name }
        })
    }

    return $issues
}

#endregion

#region --- Remediation handlers --------------------------------------------
# Each handler returns $true if applied successfully, $false if skipped/failed.

function Do-StartService {
    param([hashtable]$Data)
    $name = $Data.Name
    Write-Host "  Recommended action: Start service '$name' (and any dependencies)" -ForegroundColor White

    $deps = (Get-Service -Name $name -ErrorAction SilentlyContinue).ServicesDependedOn
    if ($deps) {
        Write-Host "  Dependencies: $($deps.Name -join ', ')" -ForegroundColor DarkGray
    }
    Write-Host "  Reversible: yes (Stop-Service $name)" -ForegroundColor DarkGray

    $ans = Ask-YN
    if ($ans -eq 'Q') { return 'Q' }
    if ($ans -eq 'N') {
        Write-Action "SKIPPED Start service: $name"
        return $false
    }

    try {
        # Start deps first
        if ($deps) {
            foreach ($d in $deps) {
                if ($d.Status -ne 'Running') {
                    Write-Host "    Starting dependency $($d.Name)..." -ForegroundColor DarkGray
                    Start-Service -Name $d.Name -ErrorAction Stop
                }
            }
        }
        Start-Service -Name $name -ErrorAction Stop
        Start-Sleep -Seconds 1
        $after = (Get-Service -Name $name).Status
        Write-Host "  Result: $name is now $after" -ForegroundColor Green
        Write-Action "Started service $name -> $after"
        return $true
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Action "FAILED to start $name : $($_.Exception.Message)"
        return $false
    }
}

function Do-UpdateSigs {
    param([hashtable]$Data)
    Write-Host "  Recommended action: Update Defender signatures (Update-MpSignature)" -ForegroundColor White
    Write-Host "  Currently $($Data.AgeDays) days old. Downloads from Microsoft." -ForegroundColor DarkGray
    Write-Host "  Reversible: signatures only go forward, can't undo" -ForegroundColor DarkGray

    $ans = Ask-YN
    if ($ans -eq 'Q') { return 'Q' }
    if ($ans -eq 'N') { Write-Action "SKIPPED Defender signature update"; return $false }

    try {
        Update-MpSignature -ErrorAction Stop
        Start-Sleep -Seconds 2
        $mp = Get-MpComputerStatus
        $newAge = if ($mp.AntispywareSignatureLastUpdated) { [int]((Get-Date) - $mp.AntispywareSignatureLastUpdated).TotalHours } else { 999 }
        Write-Host "  Result: signatures updated. Now $newAge hours old." -ForegroundColor Green
        Write-Action "Updated Defender signatures (now $newAge hours old)"
        return $true
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Action "FAILED Defender signature update: $($_.Exception.Message)"
        return $false
    }
}

function Do-EnableDefender {
    Write-Host "  Recommended action: Re-enable Windows Defender antivirus" -ForegroundColor White
    Write-Host "  This sets DisableAntiSpyware = 0 via Set-MpPreference" -ForegroundColor DarkGray
    Write-Host "  CAUTION: only do this if no third-party AV is installed." -ForegroundColor DarkYellow

    $ans = Ask-YN -Prompt "Apply this fix? (Y/N/Q) - CONFIRM no other AV present"
    if ($ans -eq 'Q') { return 'Q' }
    if ($ans -eq 'N') { Write-Action "SKIPPED Enable Defender"; return $false }

    try {
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Write-Host "  Result: Defender real-time monitoring re-enabled." -ForegroundColor Green
        Write-Action "Re-enabled Defender real-time monitoring"
        return $true
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Action "FAILED to enable Defender: $($_.Exception.Message)"
        return $false
    }
}

function Do-EnableRealTime {
    Write-Host "  Recommended action: Turn ON Defender real-time protection" -ForegroundColor White
    Write-Host "  Set-MpPreference -DisableRealtimeMonitoring `$false" -ForegroundColor DarkGray
    $ans = Ask-YN
    if ($ans -eq 'Q') { return 'Q' }
    if ($ans -eq 'N') { Write-Action "SKIPPED Enable real-time"; return $false }

    try {
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Write-Host "  Result: real-time protection enabled." -ForegroundColor Green
        Write-Action "Enabled Defender real-time protection"
        return $true
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Action "FAILED to enable real-time: $($_.Exception.Message)"
        return $false
    }
}

function Do-FixDNS {
    param([hashtable]$Data)
    Write-Host "  Recommended action: Flush DNS cache (ipconfig /flushdns)" -ForegroundColor White
    Write-Host "  Reversible: cache rebuilds automatically on next query" -ForegroundColor DarkGray
    if ($Data.Ms) { Write-Host "  Measured DNS: $($Data.Ms) ms (target: under 200ms)" -ForegroundColor DarkGray }

    $ans = Ask-YN
    if ($ans -eq 'Q') { return 'Q' }
    if ($ans -eq 'N') { Write-Action "SKIPPED DNS flush"; return $false }

    try {
        ipconfig /flushdns | Out-Null
        Write-Host "  Result: DNS cache cleared." -ForegroundColor Green
        Write-Action "Flushed DNS resolver cache"

        # Re-test
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $null = Resolve-DnsName 'www.microsoft.com' -Type A -ErrorAction Stop -QuickTimeout
            $sw.Stop()
            Write-Host "  Re-test: microsoft.com resolved in $($sw.ElapsedMilliseconds) ms" -ForegroundColor DarkGray
            Write-Action "DNS re-test: $($sw.ElapsedMilliseconds) ms"
        } catch {
            Write-Host "  Re-test: still failing - may need network reset (next prompt)" -ForegroundColor DarkYellow
        }
        return $true
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Do-ResetNetwork {
    Write-Host "  Recommended action: Reset Winsock and TCP/IP stack" -ForegroundColor White
    Write-Host "  Commands:" -ForegroundColor DarkGray
    Write-Host "    netsh winsock reset" -ForegroundColor DarkGray
    Write-Host "    netsh int ip reset"  -ForegroundColor DarkGray
    Write-Host "  WARNING: kills active network connections briefly. REBOOT REQUIRED after." -ForegroundColor DarkYellow

    # Extra safety gate on servers - this would disconnect RDP, SMB clients,
    # SQL connections, anyone using shared files. Require a typed confirmation,
    # not just Y.
    if ($IsServer) {
        Write-Host ""
        Write-Host "  *** SERVER DETECTED ***" -ForegroundColor Yellow
        Write-Host "  Winsock reset will disconnect every active network connection," -ForegroundColor Yellow
        Write-Host "  including:" -ForegroundColor Yellow
        Write-Host "    - Your own RDP session (you may lose access)" -ForegroundColor Yellow
        Write-Host "    - SMB clients accessing shares" -ForegroundColor Yellow
        Write-Host "    - SQL Server connections from workstations" -ForegroundColor Yellow
        Write-Host "    - Any other TCP service this box hosts" -ForegroundColor Yellow
        Write-Host "  The fix requires a REBOOT after to fully take effect." -ForegroundColor Yellow
        Write-Host ""
        $typed = Read-Host "  Type 'DISCONNECT' (all caps) to proceed, or anything else to skip"
        if ($typed -ne 'DISCONNECT') {
            Write-Host "  Skipped (confirmation not typed)." -ForegroundColor Yellow
            Write-Action "SKIPPED Network reset on server (typed-confirm not provided)"
            return $false
        }
    } else {
        $ans = Read-iDezignYN -Prompt "Apply network stack reset? (Y/N/Q)"
        if (-not $ans) { $ans = Ask-YN -Prompt "Apply network stack reset? (Y/N/Q)" }  # fallback to local
        if ($ans -eq 'Q') { return 'Q' }
        if ($ans -eq 'N') { Write-Action "SKIPPED Network stack reset"; return $false }
    }

    try {
        netsh winsock reset | Out-Null
        netsh int ip reset  | Out-Null
        Write-Host "  Result: winsock + IP stack reset. REBOOT REQUIRED to take full effect." -ForegroundColor Green
        Write-Action "Reset winsock + IP stack (REBOOT REQUIRED)"
        $script:RebootNeeded = $true
        return $true
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Do-Chkdsk {
    <#
    Run chkdsk /f /r on the target drive. Behavior depends on whether the
    drive is the system volume:
       - System drive (C:): cannot be checked while running, so we PRE-FEED 'Y'
         to chkdsk which schedules an autochk run at next boot. Sets RebootNeeded.
       - Data drive (D:, E:, etc.): runs live with timeout. /x dismounts the
         volume so chkdsk can take exclusive access. Anything using files on
         that drive will get errors during the scan.

    Runtime guidance:
       - /f alone   : fixes filesystem errors, fast (1-5 min on healthy drives)
       - /r implies /f and reads every sector for bad blocks - HOURS on big drives
       - We use both because if we're chkdsking at all, the user wants thorough.
    #>
    param([hashtable]$Data)

    $drive    = $Data.Drive
    $isSystem = [bool]$Data.IsSystem

    Write-Host "  Recommended action: Run chkdsk on $drive" -ForegroundColor White
    Write-Host "  Reasons: $($Data.Reasons -join '; ')" -ForegroundColor DarkGray
    Write-Host "  Command : chkdsk $drive /f /r" -ForegroundColor DarkGray
    Write-Host "  /f = fix errors  |  /r = check + remap bad sectors (slow)" -ForegroundColor DarkGray
    Write-Host ""

    if ($isSystem) {
        Write-Host "  $drive is the SYSTEM drive - cannot scan while Windows is running." -ForegroundColor Yellow
        Write-Host "  Choosing Y will SCHEDULE chkdsk for the next boot." -ForegroundColor Yellow
        Write-Host "  CAUTION: chkdsk /r can take 2-8+ HOURS at boot on a large drive." -ForegroundColor DarkYellow
        Write-Host "  The machine will be unavailable for the entire scan." -ForegroundColor DarkYellow
    } else {
        Write-Host "  $drive will be DISMOUNTED for the scan (/x). Anything using it" -ForegroundColor DarkYellow
        Write-Host "  during the scan will get I/O errors. Expect 30 min to several hours." -ForegroundColor DarkYellow
    }

    # Server gating - chkdsk on a production server is potentially HOURS of
    # downtime. Require typed confirmation, not just Y.
    if ($IsServer) {
        Write-Host ""
        Write-Host "  *** SERVER DETECTED ***" -ForegroundColor Yellow
        if ($isSystem) {
            Write-Host "  At next boot, this server will run chkdsk before the OS comes up." -ForegroundColor Yellow
            Write-Host "  AD/DNS/SMB/SQL/RDP will be DOWN for the duration (often hours)." -ForegroundColor Yellow
            Write-Host "  Schedule this for after-hours unless you have a maintenance window NOW." -ForegroundColor Yellow
        } else {
            Write-Host "  Drive $drive will be dismounted. Anything stored on it - file shares," -ForegroundColor Yellow
            Write-Host "  SQL databases, backup targets - will become inaccessible." -ForegroundColor Yellow
        }
        Write-Host ""
        $typed = Read-Host "  Type 'CHKDSK' (all caps) to proceed, or anything else to skip"
        if ($typed -ne 'CHKDSK') {
            Write-Host "  Skipped (confirmation not typed)." -ForegroundColor Yellow
            Write-Action "SKIPPED chkdsk $drive on server (typed-confirm not provided)"
            return $false
        }
    } else {
        $ans = Ask-YN -Prompt "Run chkdsk on $drive? (Y/N/Q)"
        if ($ans -eq 'Q') { return 'Q' }
        if ($ans -eq 'N') { Write-Action "SKIPPED chkdsk on $drive"; return $false }
    }

    if ($isSystem) {
        # For the system volume: pipe Y into chkdsk to accept the
        # "Cannot lock current drive. Schedule for next boot?" prompt.
        # cmd.exe handles the echo|chkdsk pipeline correctly.
        Write-Host "  Scheduling chkdsk for next boot..." -ForegroundColor DarkGray
        try {
            $output = & cmd.exe /c "echo Y| chkdsk $drive /f /r" 2>&1 | Out-String
            Write-Host $output.Trim() -ForegroundColor DarkGray

            # Verify scheduling worked - chkntfs reports what's scheduled
            $verify = & chkntfs $drive 2>&1 | Out-String
            if ($verify -match 'dirty' -or $verify -match 'scheduled') {
                Write-Host "  Confirmed: chkdsk scheduled for $drive at next boot." -ForegroundColor Green
                Write-Action "Scheduled chkdsk /f /r on $drive for next boot"
                $script:RebootNeeded = $true
                return $true
            } else {
                Write-Host "  chkntfs verification: $($verify.Trim())" -ForegroundColor DarkYellow
                Write-Action "Attempted to schedule chkdsk on $drive - verification ambiguous"
                $script:RebootNeeded = $true
                return $true
            }
        } catch {
            Write-Host "  FAILED to schedule chkdsk: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    } else {
        # Data volume - run live with timeout. 4 hours is generous but bounded.
        # /x forces dismount so chkdsk can take exclusive access.
        Write-Host "  Running chkdsk $drive /f /r /x (timeout 4 hours)..." -ForegroundColor DarkGray
        Write-Host "  This window will appear frozen during the scan - that is normal." -ForegroundColor DarkGray

        if (Get-Command Start-ProcessWithTimeout -ErrorAction SilentlyContinue) {
            $rc = Start-ProcessWithTimeout -FilePath 'chkdsk.exe' `
                    -ArgumentList @($drive, '/f', '/r', '/x') `
                    -TimeoutMinutes 240 -Label "chkdsk $drive" -NoNewWindow $true

            if ($rc -eq 0) {
                Write-Host "  chkdsk completed successfully (no errors found or all errors fixed)." -ForegroundColor Green
                Write-Action "chkdsk $drive /f /r completed cleanly (exit 0)"
                return $true
            } elseif ($rc -eq 1) {
                Write-Host "  chkdsk found and fixed errors on $drive (exit 1)." -ForegroundColor Yellow
                Write-Action "chkdsk $drive found and fixed errors (exit 1)"
                return $true
            } elseif ($rc -eq 2) {
                Write-Host "  chkdsk performed cleanup, /f was needed (exit 2)." -ForegroundColor Yellow
                Write-Action "chkdsk $drive performed cleanup (exit 2)"
                return $true
            } elseif ($rc -eq 3) {
                Write-Host "  chkdsk could NOT check the disk - errors remain (exit 3)." -ForegroundColor Red
                Write-Host "  This usually means the drive is failing. Consider replacement." -ForegroundColor Red
                Write-Action "chkdsk $drive failed - errors remain (exit 3)"
                return $false
            } elseif ($rc -eq -1) {
                Write-Host "  chkdsk TIMED OUT after 4 hours - likely a hardware issue or" -ForegroundColor Red
                Write-Host "  the drive is so large/damaged that it can't complete in reasonable time." -ForegroundColor Red
                Write-Action "chkdsk $drive TIMED OUT after 4 hours"
                return $false
            } else {
                Write-Host "  chkdsk returned unexpected exit code $rc." -ForegroundColor Yellow
                Write-Action "chkdsk $drive returned exit $rc"
                return $false
            }
        } else {
            # Fallback without timeout helper
            Write-Host "  (no timeout helper available - this may run indefinitely)" -ForegroundColor DarkYellow
            & chkdsk.exe $drive /f /r /x
            $rc = $LASTEXITCODE
            Write-Action "chkdsk $drive exit $rc (no timeout protection)"
            return ($rc -in 0,1,2)
        }
    }
}

function Do-Reboot {
    param([hashtable]$Data)
    Write-Host "  Recommended action: Reboot the computer" -ForegroundColor White
    Write-Host "  Pending: $($Data.Signals -join '; ')" -ForegroundColor DarkGray

    # Server gating is now built into Invoke-RebootChoice itself, but we still
    # want to show the server-specific impact warning here BEFORE the prompt.
    if ($IsServer) {
        Write-Host ""
        Write-Host "  *** SERVER DETECTED ***" -ForegroundColor Yellow
        Write-Host "  Rebooting this server will:" -ForegroundColor Yellow
        Write-Host "    - Disconnect every RDP user immediately" -ForegroundColor Yellow
        Write-Host "    - Interrupt SMB clients accessing shares (Dentrix, etc.)" -ForegroundColor Yellow
        Write-Host "    - Halt any running SQL/Veeam/backup job" -ForegroundColor Yellow
        Write-Host "    - Take services 5-15 minutes to come back online" -ForegroundColor Yellow
        if ($IsDC) {
            Write-Host "    - Make AD/DNS unavailable to clients until back up" -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  Consider scheduling for off-hours instead." -ForegroundColor Yellow
    }

    if (Get-Command Invoke-RebootChoice -ErrorAction SilentlyContinue) {
        $rebooted = Invoke-RebootChoice `
            -Reason "Clearing pending operations: $($Data.Signals -join '; ')" `
            -CountdownSeconds 30 `
            -DeferMessage "The pending flag stays - you'll see it again until you reboot."

        if ($rebooted) {
            Write-Action "TRIGGERED reboot (30 sec timer) for pending: $($Data.Signals -join '; ')"
            return $true
        } else {
            Write-Action "DEFERRED reboot - pending: $($Data.Signals -join '; ')"
            return $false
        }
    } else {
        # Fallback - module missing. Old Y/N behavior.
        $ans = Ask-YN -Prompt "Reboot in 30 seconds? (Y/N/Q)"
        if ($ans -eq 'Q') { return 'Q' }
        if ($ans -eq 'N') { Write-Action "SKIPPED Reboot (pending: $($Data.Signals -join '; '))"; return $false }
        shutdown /r /t 30 /c "iDezign Remediation: clearing pending operations."
        Write-Action "TRIGGERED reboot (30 sec timer) for pending: $($Data.Signals -join '; ')"
        return $true
    }
}

function Do-StartDentrixService {
    param([hashtable]$Data)
    $name = $Data.Name
    Write-Host "  Recommended action: Start Dentrix service '$name'" -ForegroundColor White
    Write-Host "  CAUTION: if you suspect Dentrix data corruption or recently had a" -ForegroundColor DarkYellow
    Write-Host "  power loss, do NOT just restart - call Henry Schein support first." -ForegroundColor DarkYellow

    $ans = Ask-YN -Prompt "Start the Dentrix service? (Y/N/Q)"
    if ($ans -eq 'Q') { return 'Q' }
    if ($ans -eq 'N') { Write-Action "SKIPPED Dentrix service start: $name"; return $false }

    try {
        Start-Service -Name $name -ErrorAction Stop
        Start-Sleep -Seconds 2
        $after = (Get-Service -Name $name).Status
        Write-Host "  Result: $name is now $after" -ForegroundColor Green
        Write-Action "Started Dentrix service $name -> $after"
        return $true
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Action "FAILED Dentrix service start: $($_.Exception.Message)"
        return $false
    }
}

function Do-StartSQL {
    param([hashtable]$Data)
    $name = $Data.Name
    Write-Host "  Recommended action: Start SQL Server instance '$name'" -ForegroundColor White
    Write-Host "  This is the database backend for Dentrix." -ForegroundColor DarkGray
    Write-Host "  CAUTION: if SQL didn't shut down cleanly, starting it will trigger" -ForegroundColor DarkYellow
    Write-Host "  database recovery on startup. That's usually fine, but if you saw" -ForegroundColor DarkYellow
    Write-Host "  a sudden power loss or disk error, contact Henry Schein support" -ForegroundColor DarkYellow
    Write-Host "  before starting - they may want to do a controlled recovery." -ForegroundColor DarkYellow

    $ans = Ask-YN -Prompt "Start SQL instance '$name'? (Y/N/Q)"
    if ($ans -eq 'Q') { return 'Q' }
    if ($ans -eq 'N') { Write-Action "SKIPPED SQL start: $name"; return $false }

    try {
        Start-Service -Name $name -ErrorAction Stop
        Start-Sleep -Seconds 3
        $after = (Get-Service -Name $name).Status
        Write-Host "  Result: $name is now $after" -ForegroundColor Green
        Write-Action "Started SQL instance $name -> $after"
        return $true
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Check SQL error log at:" -ForegroundColor DarkGray
        Write-Host "    C:\Program Files\Microsoft SQL Server\MSSQL*\MSSQL\Log\ERRORLOG" -ForegroundColor DarkGray
        Write-Action "FAILED SQL start $name : $($_.Exception.Message)"
        return $false
    }
}

# --- Tier 3 recommendation-only handlers ---
# These don't apply fixes - they print guidance and offer customer-facing language.

function Do-ReplaceDrive {
    param([hashtable]$Data)
    Write-Host "  RECOMMENDATION: Replace drive" -ForegroundColor Red
    Write-Host "  Drive  : $($Data.Name)" -ForegroundColor White
    Write-Host "  Size   : $($Data.SizeGB) GB" -ForegroundColor White
    Write-Host "  Reason : $($Data.Reason)" -ForegroundColor White
    Write-Host ""
    Write-Host "  This is NOT auto-fixable. Plan replacement immediately." -ForegroundColor Yellow
    Write-Host "  BACK UP DATA FIRST before scheduling the swap." -ForegroundColor Yellow

    $emailLang = @"

  ---- Suggested customer-facing language ----
  Subject: Workstation $env:COMPUTERNAME - Drive Replacement Recommended

  During routine maintenance on workstation $env:COMPUTERNAME, we identified
  that the primary storage drive is showing signs of failure ($($Data.Reason)).
  We recommend scheduling a drive replacement as soon as possible to prevent
  unplanned downtime and potential data loss.

  Recommended next steps:
    1. Verify recent backups are intact.
    2. Schedule replacement appointment (1-2 hour service window).
    3. We will image the drive to a new SSD and transfer all data and
       software so the workstation is operational by end of appointment.

  Please reply to confirm a preferred date/time.
  ----------------------------------------------
"@
    Write-Host $emailLang -ForegroundColor DarkGray
    Write-Action "RECOMMENDED drive replacement: $($Data.Name) - $($Data.Reason)"
    $script:Recommendations++
    Write-Host ""
    Read-Host "  Press Enter to continue"
    return $false
}

function Do-PlanReplaceDrive {
    param([hashtable]$Data)
    Write-Host "  RECOMMENDATION: Plan SSD replacement within 6-12 months" -ForegroundColor Yellow
    Write-Host "  Drive : $($Data.Name)" -ForegroundColor White
    Write-Host "  Wear  : $($Data.Wear)% (replace before 80%)" -ForegroundColor White
    Write-Host "  Size  : $($Data.SizeGB) GB" -ForegroundColor White
    Write-Host ""
    Write-Host "  Not urgent. Add to client's hardware refresh schedule." -ForegroundColor DarkGray
    Write-Action "RECOMMENDED future SSD replacement: $($Data.Name) at $($Data.Wear)% wear"
    $script:Recommendations++
    Read-Host "  Press Enter to continue"
    return $false
}

function Do-UpgradeRAM {
    param([hashtable]$Data)
    $tag = if ($Data.Urgent) { 'REQUIRED' } else { 'RECOMMENDED' }
    Write-Host "  RECOMMENDATION ($tag): RAM upgrade" -ForegroundColor $(if($Data.Urgent){'Red'}else{'Yellow'})
    Write-Host "  Current : $($Data.Current) GB" -ForegroundColor White
    Write-Host "  Target  : $($Data.Target) GB" -ForegroundColor White
    Write-Host ""
    Write-Host "  Hardware change - not auto-fixable." -ForegroundColor DarkGray

    $emailLang = @"

  ---- Suggested customer-facing language ----
  Subject: Workstation $env:COMPUTERNAME - Memory Upgrade Recommended

  During routine maintenance on workstation $env:COMPUTERNAME, we identified
  that the system has only $($Data.Current) GB of RAM installed, which is below
  current recommendations for $(if($Data.Urgent){'reliable everyday'}else{'optimal'}) operation.

  We recommend upgrading to $($Data.Target) GB. Benefits:
    - Faster application response, especially with multiple programs open
    - Less drive wear (less paging activity)
    - Better Windows Update reliability
    - $(if($Data.Urgent){'Restores basic acceptable performance levels.'}else{'Extends usable life of the workstation by 2-3 years.'})

  Estimated time : 30 minutes on-site
  Please reply to schedule.
  ----------------------------------------------
"@
    Write-Host $emailLang -ForegroundColor DarkGray
    Write-Action "RECOMMENDED RAM upgrade: $($Data.Current) GB -> $($Data.Target) GB ($tag)"
    $script:Recommendations++
    Read-Host "  Press Enter to continue"
    return $false
}

function Do-HardwareInvestigate {
    param([hashtable]$Data)
    Write-Host "  RECOMMENDATION: Hardware investigation needed" -ForegroundColor Yellow
    Write-Host "  Reason: $($Data.Count) $($Data.Reason) in 7 days" -ForegroundColor White
    Write-Host ""
    Write-Host "  Suggested investigation order:" -ForegroundColor DarkGray
    Write-Host "    1. Memory test (Windows Memory Diagnostic or MemTest86 from USB)" -ForegroundColor DarkGray
    Write-Host "    2. CPU temperature under load (HWiNFO64 / Core Temp)" -ForegroundColor DarkGray
    Write-Host "    3. PSU output stability (multimeter or load test)" -ForegroundColor DarkGray
    Write-Host "    4. Dust / thermal paste age (most overlooked, often the fix)" -ForegroundColor DarkGray
    Write-Host "    5. Driver review - check Reliability Monitor (perfmon /rel)" -ForegroundColor DarkGray
    Write-Action "RECOMMENDED hardware investigation: $($Data.Count) $($Data.Reason)"
    $script:Recommendations++
    Read-Host "  Press Enter to continue"
    return $false
}

function Do-ConsiderReinstall {
    param([hashtable]$Data)
    $years = [math]::Round($Data.AgeDays / 365, 1)
    Write-Host "  RECOMMENDATION: Consider clean Windows install or fresh image" -ForegroundColor Yellow
    Write-Host "  Current install is $years years old ($($Data.AgeDays) days)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Old installs accumulate: orphaned drivers, leftover services," -ForegroundColor DarkGray
    Write-Host "  registry bloat, dead app data, and update history that can't be" -ForegroundColor DarkGray
    Write-Host "  fully cleaned. A fresh image deployment usually adds 30-50% to" -ForegroundColor DarkGray
    Write-Host "  perceived performance with no hardware change." -ForegroundColor DarkGray
    Write-Action "RECOMMENDED reimaging: install age $years years"
    $script:Recommendations++
    Read-Host "  Press Enter to continue"
    return $false
}

#endregion

#region --- Main loop --------------------------------------------------------

$issues = Build-IssueList -Snap $snapshot

if ($issues.Count -eq 0) {
    Write-Host ""
    Write-Host "  No actionable issues detected. Nothing to remediate." -ForegroundColor Green
    Write-Host ""
    Write-Action "No actionable issues found"
} else {
    Write-Host ""
    Write-Host "  Found $($issues.Count) actionable issue(s). Walking through one at a time." -ForegroundColor Cyan
    Write-Host ""

    # Sort: Tier 1 first (easy wins), then Tier 2, then Tier 3 (recommendations)
    $sortedIssues = $issues | Sort-Object { [int]$_.Tier }

    $n = 0
    $quit = $false
    foreach ($issue in $sortedIssues) {
        if ($quit) { break }
        $n++
        $tierName = switch ($issue.Tier) { 1 {'1 (low risk)'} 2 {'2 (medium risk)'} 3 {'3 (recommend only)'} }
        Show-IssueHeader -Num $n -Total $sortedIssues.Count -Title $issue.Title -Tier $tierName -Risk $issue.Risk

        $result = switch ($issue.Type) {
            'StartService'         { Do-StartService         -Data $issue.Data }
            'UpdateSigs'           { Do-UpdateSigs           -Data $issue.Data }
            'EnableDefender'       { Do-EnableDefender }
            'EnableRealTime'       { Do-EnableRealTime }
            'FixDNS'               { Do-FixDNS               -Data $issue.Data }
            'ResetNetwork'         { Do-ResetNetwork }
            'Chkdsk'               { Do-Chkdsk               -Data $issue.Data }
            'Reboot'               { Do-Reboot               -Data $issue.Data }
            'StartDentrixService'  { Do-StartDentrixService  -Data $issue.Data }
            'StartSQL'             { Do-StartSQL             -Data $issue.Data }
            'ReplaceDrive'         { Do-ReplaceDrive         -Data $issue.Data }
            'PlanReplaceDrive'     { Do-PlanReplaceDrive     -Data $issue.Data }
            'UpgradeRAM'           { Do-UpgradeRAM           -Data $issue.Data }
            'HardwareInvestigate'  { Do-HardwareInvestigate  -Data $issue.Data }
            'ConsiderReinstall'    { Do-ConsiderReinstall    -Data $issue.Data }
            default                { Write-Host "  (no handler for type $($issue.Type))" -ForegroundColor DarkYellow; $false }
        }

        # Type-safe result handling. PowerShell's -eq does silent type coercion:
        # `$true -eq 'Q'` evaluates to TRUE because 'Q' converts to Boolean $true
        # (any non-empty string is truthy in PS). So we MUST type-check first or
        # successful fixes will be misinterpreted as "user quit".
        if (($result -is [string]) -and ($result -eq 'Q')) {
            Write-Host ""
            Write-Host "  Quit requested. Skipping remaining issues." -ForegroundColor Yellow
            Write-Action "User quit at issue $n of $($sortedIssues.Count)"
            $quit = $true
        } elseif (($result -is [bool]) -and ($result -eq $true)) {
            $script:ActionsTaken++
            $script:FixedList.Add($issue.Title) | Out-Null
        } elseif (($result -is [bool]) -and ($result -eq $false)) {
            if ($issue.Tier -lt 3) {
                $script:ActionsSkipped++
                $script:SkippedList.Add($issue.Title) | Out-Null
            } else {
                # Tier 3 - $script:Recommendations already incremented in handler.
                # We just record the title here for the summary list.
                $script:RecommendationList.Add($issue.Title) | Out-Null
            }
        }
        # Tier 3 "recommendations" are counted in their handlers via $script:Recommendations
    }
}

#endregion

#region --- Final summary + log write ---------------------------------------

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Remediation Summary - $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

if ($issues.Count -eq 0) {
    # Nothing to do - explicitly tell the user the machine is healthy.
    Write-Host ""
    Write-Host "  No actionable issues were found on this machine." -ForegroundColor Green
    Write-Host "  Nothing was changed. The system appears to be in good shape." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Things checked this run:" -ForegroundColor DarkGray
    Write-Host "    - Essential services (wuauserv, WinDefend, RPC, etc.)" -ForegroundColor DarkGray
    Write-Host "    - Windows Defender state and signature age" -ForegroundColor DarkGray
    Write-Host "    - DNS resolution and internet reachability" -ForegroundColor DarkGray
    Write-Host "    - Pending reboot signals (CBS, WU, WinSxS)" -ForegroundColor DarkGray
    Write-Host "    - Disk health (SMART, wear, errors)  if snapshot available" -ForegroundColor DarkGray
    Write-Host "    - RAM size + memory pressure        if snapshot available" -ForegroundColor DarkGray
    Write-Host "    - Unexpected shutdowns / BSODs      if snapshot available" -ForegroundColor DarkGray
    Write-Host "    - Dentrix services + SQL backend    if Dentrix detected" -ForegroundColor DarkGray
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "  Issues found    : $($issues.Count)" -ForegroundColor Cyan
    Write-Host "  Fixed           : $script:ActionsTaken" -ForegroundColor Green
    Write-Host "  Skipped (N)     : $script:ActionsSkipped" -ForegroundColor Yellow
    Write-Host "  Recommendations : $script:Recommendations" -ForegroundColor Yellow
    Write-Host ""

    if ($script:FixedList.Count -gt 0) {
        Write-Host "  FIXED:" -ForegroundColor Green
        foreach ($f in $script:FixedList) {
            Write-Host "    + $f" -ForegroundColor Green
        }
        Write-Host ""
    }

    if ($script:SkippedList.Count -gt 0) {
        Write-Host "  SKIPPED (you said N):" -ForegroundColor Yellow
        foreach ($s in $script:SkippedList) {
            Write-Host "    - $s" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    if ($script:RecommendationList.Count -gt 0) {
        Write-Host "  RECOMMENDATIONS LOGGED (hardware - no auto-fix):" -ForegroundColor Yellow
        foreach ($r in $script:RecommendationList) {
            Write-Host "    ! $r" -ForegroundColor Yellow
        }
        Write-Host "    (Customer-facing email language is in the action log.)" -ForegroundColor DarkGray
        Write-Host ""
    }

    # Special "everything fixable was fixed" message
    if ($script:FixedList.Count -gt 0 -and $script:SkippedList.Count -eq 0 -and $script:RecommendationList.Count -eq 0) {
        Write-Host "  All actionable issues were resolved on this run." -ForegroundColor Green
        Write-Host ""
    }
}

if ($script:RebootNeeded) {
    Write-Host "  *** REBOOT REQUIRED ***" -ForegroundColor Red
    Write-Host "  Network changes were applied that need a reboot to fully take effect." -ForegroundColor Yellow
    Write-Host ""
}

# Write the action log
$header = @(
    "============================================================"
    "  iDezign Remediation - Action Log"
    "  Version  : $ScriptVersion"
    "  Computer : $env:COMPUTERNAME"
    "  User     : $env:USERNAME"
    "  Started  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "  Source   : $snapSource"
    "============================================================"
    ""
    "Summary:"
    "  Actions taken    : $script:ActionsTaken"
    "  Actions skipped  : $script:ActionsSkipped"
    "  Recommendations  : $script:Recommendations"
    ""
    "Actions in order:"
)
($header + $logLines) -join "`r`n" | Set-Content -Path $ActionLog -Encoding UTF8

Write-Host "  Action log saved to:" -ForegroundColor Cyan
Write-Host "    $ActionLog"
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# v3.0: Optional combined Diagnostics + Remediation PDF (merged from old
# iDezign_SavePDF.ps1). Asks Y/N. If Y, builds a single HTML document with
# the latest Diagnostics report (from C:\iDezign_Diagnostics) followed by
# the Remediation actions log, then converts to PDF via Edge headless.
# Saves to Desktop with computer name + timestamp in the filename.
# ============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Save service report as PDF (Diagnostics + Remediation)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
$pdfAns = Read-Host "  Save combined report as PDF on Desktop? (Y/N)"
if ($pdfAns -match '^(?i)y') {
    # --- Locate Microsoft Edge (the PDF engine) ----------------------------
    $edgeCandidates = @(
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $edgeCandidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
    }
    $edge = $edgeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $edge) {
        Write-Host "  Microsoft Edge was not found - cannot create PDF." -ForegroundColor Yellow
        Write-Host "  (Edge ships with Windows 10/11; this machine may be unusual.)" -ForegroundColor DarkGray
    } else {
        # --- Find latest Diagnostics report --------------------------------
        $diagHtmlPath = Join-Path $DiagDir 'Diagnostics_Latest.html'
        if (-not (Test-Path $diagHtmlPath)) {
            $newest = Get-ChildItem -Path (Join-Path $DiagDir 'Diagnostics_*.html') -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest) { $diagHtmlPath = $newest.FullName }
        }
        $hasDiag = Test-Path $diagHtmlPath
        if ($hasDiag) {
            Write-Host "  Diagnostics source : $diagHtmlPath" -ForegroundColor DarkGray
        } else {
            Write-Host "  No Diagnostics report found in $DiagDir." -ForegroundColor Yellow
            Write-Host "  PDF will contain Remediation log only." -ForegroundColor Yellow
        }

        # --- Extract Diagnostics body + styles -----------------------------
        $diagBody   = ''
        $diagStyles = ''
        if ($hasDiag) {
            try {
                $diagContent = Get-Content -Raw -Path $diagHtmlPath -Encoding UTF8
                if ($diagContent -match '(?si)<body[^>]*>(.*?)</body>') { $diagBody   = $matches[1] }
                if ($diagContent -match '(?si)<style[^>]*>(.*?)</style>') { $diagStyles = $matches[1] }
            } catch {
                Write-Host "  WARN: could not parse Diagnostics HTML: $($_.Exception.Message)" -ForegroundColor Yellow
                $hasDiag = $false
            }
        }

        # --- Escape Remediation log lines for HTML -------------------------
        $remHtmlContent = ($logLines | ForEach-Object {
            ($_ -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
        }) -join "`r`n"

        # --- Build combined HTML ------------------------------------------
        $coverDate = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        $partLabel = if ($hasDiag) { 'Part 2 - ' } else { '' }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('<!DOCTYPE html>')
        [void]$sb.AppendLine('<html lang="en">')
        [void]$sb.AppendLine('<head>')
        [void]$sb.AppendLine('<meta charset="utf-8">')
        [void]$sb.AppendLine("<title>iDezign Service Report - $env:COMPUTERNAME</title>")
        [void]$sb.AppendLine('<style>')
        [void]$sb.AppendLine($diagStyles)
        [void]$sb.AppendLine('
/* Combined report overrides */
body { font-family: "Segoe UI", "Helvetica Neue", Arial, sans-serif; }
.report-cover { page-break-after: always; padding: 60px 40px; text-align: center; border-bottom: 4px solid #A82828; }
.report-cover h1 { color: #A82828; font-size: 36px; margin-bottom: 16px; }
.report-cover .meta { color: #555; font-size: 14px; line-height: 1.8; }
.section-header { page-break-before: always; padding: 20px 40px; background: #A82828; color: white; margin: 0; }
.section-header h1 { font-size: 24px; margin: 0; color: white; }
.remediation-log { font-family: "Consolas", "Courier New", monospace; font-size: 11px; white-space: pre-wrap; background: #f8f8f8; padding: 20px 40px; border-left: 4px solid #A82828; margin: 0; }
.remediation-summary { padding: 20px 40px; }
.remediation-summary strong { color: #A82828; }
')
        [void]$sb.AppendLine('</style>')
        [void]$sb.AppendLine('</head>')
        [void]$sb.AppendLine('<body>')
        [void]$sb.AppendLine('<div class="report-cover">')
        [void]$sb.AppendLine('<h1>iDezign Service Report</h1>')
        [void]$sb.AppendLine('<div class="meta">')
        [void]$sb.AppendLine("<p><strong>Computer:</strong> $env:COMPUTERNAME</p>")
        [void]$sb.AppendLine("<p><strong>User:</strong> $env:USERNAME</p>")
        [void]$sb.AppendLine("<p><strong>Generated:</strong> $coverDate</p>")
        [void]$sb.AppendLine("<p><strong>Remediation v$ScriptVersion</strong></p>")
        [void]$sb.AppendLine('</div>')
        [void]$sb.AppendLine('</div>')
        if ($hasDiag) {
            [void]$sb.AppendLine('<div class="section-header"><h1>Part 1 - Diagnostics</h1></div>')
            [void]$sb.AppendLine($diagBody)
        }
        [void]$sb.AppendLine("<div class=`"section-header`"><h1>${partLabel}Remediation Actions</h1></div>")
        [void]$sb.AppendLine('<div class="remediation-summary">')
        [void]$sb.AppendLine("<p><strong>Actions taken:</strong> $script:ActionsTaken</p>")
        [void]$sb.AppendLine("<p><strong>Actions skipped:</strong> $script:ActionsSkipped</p>")
        [void]$sb.AppendLine("<p><strong>Recommendations logged:</strong> $script:Recommendations</p>")
        [void]$sb.AppendLine('</div>')
        [void]$sb.AppendLine("<pre class=`"remediation-log`">$remHtmlContent</pre>")
        [void]$sb.AppendLine('</body>')
        [void]$sb.AppendLine('</html>')

        # --- Save combined HTML to temp -----------------------------------
        $tempHtml = Join-Path $env:TEMP "iDezign_ServiceReport_$Timestamp.html"
        Set-Content -Path $tempHtml -Value $sb.ToString() -Encoding UTF8

        # --- Build PDF path on Desktop ------------------------------------
        $desktop = [Environment]::GetFolderPath('Desktop')
        $pdf     = Join-Path $desktop ("iDezign_ServiceReport_{0}_{1}.pdf" -f $env:COMPUTERNAME, $Timestamp)
        $uri     = 'file:///' + ($tempHtml -replace '\\','/')

        Write-Host "  Output : $pdf" -ForegroundColor DarkGray
        Write-Host "  Creating PDF (Edge headless)..." -ForegroundColor Cyan

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
        }

        # Edge headless can finish writing a moment after exit - wait briefly.
        $tries = 0
        while (-not (Test-Path $pdf) -and $tries -lt 20) { Start-Sleep -Milliseconds 250; $tries++ }

        Write-Host ""
        if (Test-Path $pdf) {
            $kb = [math]::Round((Get-Item $pdf).Length / 1KB, 0)
            Write-Host "  SUCCESS - PDF saved to your Desktop:" -ForegroundColor Green
            Write-Host "    $pdf  ($kb KB)" -ForegroundColor Green
            try { Start-Process explorer.exe ('/select,"{0}"' -f $pdf) } catch { }
        } else {
            Write-Host "  PDF was not produced. Edge may have failed silently." -ForegroundColor Red
            Write-Host "  You can open the source HTML and Print -> Save as PDF manually:" -ForegroundColor Yellow
            Write-Host "    $tempHtml" -ForegroundColor DarkGray
        }
        # Note: temp HTML is left in place as a manual-fallback option.
    }
    Write-Host ""
} else {
    Write-Host "  Skipped (no PDF generated)." -ForegroundColor DarkGray
    Write-Host ""
}

# Pause so the elevated PowerShell window doesn't auto-close on script exit.
# (Run-Remediation.bat launches via Start-Process -Verb RunAs, which spawns a
# new window that disappears the moment the script returns. This keeps it open
# so you can read the summary.)
Read-Host "Press Enter to close this window"

#endregion
