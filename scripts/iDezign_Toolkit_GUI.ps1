# ============================================================================
#  iDezign_Toolkit_GUI.ps1
#  Light, web-style WPF launcher for the iDezign Toolkit - matches the
#  iDezign.ai brand (white, Jost/Century Gothic, crimson #A82828 accents).
#
#  Design:
#   * White window, hairline border, logo top-left, "TOOLKIT vX" top-right
#   * Crimson divider, "SCRIPTS" eyebrow label, a vertical list of script rows
#     built dynamically from iDezign_Versions.json (the manifest)
#   * Each row launches its tool in its OWN elevated window (separate-window
#     model - required for tools that self-stage and reboot, like Cleanup)
#   * Double-click the header to maximize/restore; drag the header to move
#
#  Version: 2026.05.25-gui-v3-webdesign
# ============================================================================

$ScriptVersion = '2026.06.29-gui-v2.9.1-bigwindow'

# --- Diagnostic logging ------------------------------------------------------
$script:DiagLog = $null
function Write-Diag {
    param([string]$Message)
    try {
        if ($script:DiagLog) {
            ('[{0}] {1}' -f (Get-Date).ToString('o'), $Message) |
                Out-File -FilePath $script:DiagLog -Append -Encoding UTF8
        }
    } catch { }
}
trap {
    Write-Diag ("FATAL {0}: {1}" -f $_.Exception.GetType().FullName, $_.Exception.Message)
    Write-Diag ("  at : {0}" -f $_.InvocationInfo.PositionMessage)
    Write-Diag ("  stk: {0}" -f $_.ScriptStackTrace)
    break
}

# --- Admin check -------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')) {
    [System.Windows.MessageBox]::Show(
        "iDezign Toolkit must be run as Administrator.`r`n`r`nClose this and launch via Run-Toolkit-GUI.bat instead, which will prompt for elevation.",
        "iDezign Toolkit - Admin required",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning) | Out-Null
    exit 1
}

# --- WPF assemblies ----------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly } catch { }

# --- Paths / self-location ---------------------------------------------------
$ScriptDir = $null
if ($PSScriptRoot)      { $ScriptDir = $PSScriptRoot }
elseif ($PSCommandPath) { $ScriptDir = Split-Path -Parent $PSCommandPath }
if (-not $ScriptDir -or -not (Test-Path $ScriptDir)) {
    try { $ScriptDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { }
}
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

$script:DiagLog = Join-Path $ScriptDir 'gui_startup.log'
try { Remove-Item $script:DiagLog -ErrorAction SilentlyContinue } catch { }
Write-Diag ("=== GUI start v{0}  PS={1}  Dir={2} ===" -f $ScriptVersion, $PSVersionTable.PSVersion, $ScriptDir)

# Logo: on a WHITE background use the DARK-on-transparent variant.
$LogoPath = $null
foreach ($cand in @('iDezign-logo-trim.png','iDezign-ai-logo-v2-transparent.png','iDezign_Logo.png','iDezign_Logo.jpg')) {
    $p = Join-Path $ScriptDir $cand
    if (Test-Path $p) { $LogoPath = $p; break }
}

# --- Manifest (single source of truth) --------------------------------------
$ManifestPath = Join-Path $ScriptDir 'iDezign_Versions.json'
$DefaultToolDefs = @(
    [PSCustomObject]@{ key='Diagnostics'; displayName='Diagnostics';        subtitle='Health check + HTML report';        scriptFile='iDezign_Diagnostics.ps1';       destructive=$false; order=1 }
    [PSCustomObject]@{ key='Cleanup';     displayName='Cleanup';            subtitle='Maintenance + imaging prep';        scriptFile='iDezign_Cleanup_Utility.ps1';   destructive=$false; order=2 }
    [PSCustomObject]@{ key='Remediation'; displayName='Remediation';        subtitle='Interactive issue fixer';           scriptFile='iDezign_Remediation.ps1';       destructive=$false; order=3 }
    [PSCustomObject]@{ key='Reset';       displayName='Reset to OOBE';      subtitle='Sysprep for imaging (destructive)'; scriptFile='iDezign_Reset_to_OOBE.ps1';     destructive=$true;  order=4 }
    [PSCustomObject]@{ key='SavePDF';     displayName='Save PDF to Desktop';subtitle='Latest Diagnostics report -> PDF';  scriptFile='iDezign_SavePDF.ps1';           destructive=$false; order=5 }
    [PSCustomObject]@{ key='Migrate';     displayName='Migrate';            subtitle='Back up + move user data';          scriptFile='iDezign_Migration_Utility.ps1'; destructive=$false; order=6 }
)
$ToolDefs = $null
$ToolkitVersion = '2.0'
try {
    if (Test-Path $ManifestPath) {
        $mf = Get-Content -Raw -Encoding UTF8 $ManifestPath | ConvertFrom-Json -ErrorAction Stop
        if ($mf.tools -and @($mf.tools).Count -gt 0) {
            $ToolDefs = @($mf.tools | Sort-Object { [int]$_.order })
        }
        if ($mf.toolkitVersion) { $ToolkitVersion = [string]$mf.toolkitVersion }
    }
} catch { $ToolDefs = $null }
if (-not $ToolDefs) { $ToolDefs = $DefaultToolDefs }

$Tools = @{}
$ToolDefByKey = @{}
foreach ($d in $ToolDefs) {
    $Tools[$d.key]        = Join-Path $ScriptDir $d.scriptFile
    $ToolDefByKey[$d.key] = $d
}
Write-Diag ("manifest loaded: {0} tools, toolkit v{1}" -f $ToolDefs.Count, $ToolkitVersion)

# --- XAML --------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="iDezign Toolkit"
        Height="700" Width="400"
        WindowStartupLocation="CenterScreen"
        ShowInTaskbar="True" Topmost="False"
        Background="#FFFFFF"
        FontFamily="Jost, Century Gothic, Segoe UI"
        WindowStyle="None"
        AllowsTransparency="True"
        ResizeMode="CanResize">

  <Window.Resources>
    <SolidColorBrush x:Key="ink"    Color="#161616"/>
    <SolidColorBrush x:Key="muted"  Color="#6A6A6A"/>
    <SolidColorBrush x:Key="muted2" Color="#8A8A8A"/>
    <SolidColorBrush x:Key="hair"   Color="#ECECEC"/>
    <SolidColorBrush x:Key="hair2"  Color="#CFCFCF"/>
    <SolidColorBrush x:Key="red"    Color="#A82828"/>
    <SolidColorBrush x:Key="white"  Color="#FFFFFF"/>

    <!-- Script row: a light card button with hover highlight -->
    <Style x:Key="ScriptRow" TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="{StaticResource ink}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="{StaticResource hair}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Normal"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="rb" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Stretch"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="rb" Property="Background" Value="#F5F5F5"/>
                <Setter TargetName="rb" Property="BorderBrush" Value="{StaticResource hair2}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="rb" Property="Background" Value="#EFEFEF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Subtle window control button (minimize / close) -->
    <Style x:Key="WinBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource muted}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Width" Value="30"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="wb" Background="{TemplateBinding Background}" CornerRadius="4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="wb" Property="Background" Value="#F0F0F0"/>
                <Setter Property="Foreground" Value="{StaticResource red}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border BorderBrush="#E0E0E0" BorderThickness="1" Background="#FFFFFF">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="74"/>   <!-- header -->
        <RowDefinition Height="2"/>    <!-- red divider -->
        <RowDefinition Height="*"/>    <!-- scripts -->
        <RowDefinition Height="30"/>   <!-- footer -->
      </Grid.RowDefinitions>

      <!-- HEADER -->
      <Border x:Name="TitleBar" Grid.Row="0" Background="#FFFFFF">
        <Grid Margin="22,0,12,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Image x:Name="LogoImage" Grid.Column="0" Height="54" MaxWidth="300"
                 RenderOptions.BitmapScalingMode="Fant"
                 Stretch="Uniform" VerticalAlignment="Center" HorizontalAlignment="Left"/>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock x:Name="lblToolkit" Text="T O O L K I T   v2.0"
                       FontSize="11" Foreground="{StaticResource muted}"
                       VerticalAlignment="Center" Margin="0,0,18,0"/>
            <Button x:Name="btnMin" Style="{StaticResource WinBtn}" Content="&#8212;" ToolTip="Minimize"/>
            <Button x:Name="btnClose" Style="{StaticResource WinBtn}" Content="&#10005;" ToolTip="Close"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- RED DIVIDER -->
      <Border Grid.Row="1" Background="#A82828"/>

      <!-- SCRIPTS -->
      <Grid Grid.Row="2" Margin="22,16,22,8">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,14" VerticalAlignment="Center">
          <Border Width="34" Height="1" Background="#A82828" VerticalAlignment="Center" Margin="0,2,14,0"/>
          <TextBlock Text="S C R I P T S" FontSize="12" Foreground="{StaticResource red}" VerticalAlignment="Center"/>
        </StackPanel>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="RowsPanel"/>
        </ScrollViewer>
      </Grid>

      <!-- FOOTER -->
      <Border Grid.Row="3" BorderBrush="{StaticResource hair}" BorderThickness="0,1,0,0">
        <Grid Margin="40,0,40,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="lblStatus" Grid.Column="0" Text="Ready." FontSize="12"
                     Foreground="{StaticResource muted}" VerticalAlignment="Center"
                     TextTrimming="CharacterEllipsis" Margin="0,0,12,0"/>
          <TextBlock Grid.Column="1" Text="iDezign Technology" FontSize="11"
                     Foreground="{StaticResource muted2}" VerticalAlignment="Center"/>
        </Grid>
      </Border>

    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
Write-Diag 'CP: XAML parsed, window created'

function Find-Control { param([string]$name) $window.FindName($name) }
$ui = @{
    TitleBar  = Find-Control 'TitleBar'
    Logo      = Find-Control 'LogoImage'
    Toolkit   = Find-Control 'lblToolkit'
    BtnMin    = Find-Control 'btnMin'
    BtnClose  = Find-Control 'btnClose'
    RowsPanel = Find-Control 'RowsPanel'
    Status    = Find-Control 'lblStatus'
}

# Toolkit version label
$ui.Toolkit.Text = ("T O O L K I T   v{0}" -f $ToolkitVersion)

# Logo
if ($LogoPath -and (Test-Path $LogoPath)) {
    try {
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.UriSource = New-Object System.Uri($LogoPath, [System.UriKind]::Absolute)
        $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bi.EndInit(); $bi.Freeze()
        $ui.Logo.Source = $bi
    } catch { Write-Diag ("logo load failed: {0}" -f $_.Exception.Message) }
}

# --- Status helper -----------------------------------------------------------
function Set-Status {
    param([string]$Text, [string]$ColorHex = '#6A6A6A')
    $window.Dispatcher.Invoke([Action]{
        $ui.Status.Text = $Text
        try { $ui.Status.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($ColorHex) } catch { }
    })
}

# --- Launch a tool in its own elevated window --------------------------------
function Start-Tool {
    param([string]$ToolName)
    $scriptPath = $Tools[$ToolName]
    $label = $ToolName
    if ($ToolDefByKey[$ToolName]) { $label = $ToolDefByKey[$ToolName].displayName }
    if (-not $scriptPath -or -not (Test-Path $scriptPath)) {
        Set-Status ("Script not found for {0}" -f $label) '#A82828'
        Write-Diag "ERR script not found: $scriptPath"
        return
    }
    try {
        Start-Process -FilePath 'powershell.exe' -WorkingDirectory $ScriptDir -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f $scriptPath)
        ) | Out-Null
        Set-Status ("Launched {0}  -  {1}" -f $label, (Get-Date -Format 'HH:mm'))
        Write-Diag "launched $label"
    } catch {
        Set-Status ("Failed to launch {0}: {1}" -f $label, $_.Exception.Message) '#A82828'
        Write-Diag ("ERR launching {0}: {1}" -f $label, $_.Exception.Message)
    }
}

# --- Build the script rows from the manifest ---------------------------------
$row_Click = {
    param($sender, $e)
    $key = $sender.Tag
    if (-not $key) { return }
    $def = $ToolDefByKey[$key]
    if ($def -and $def.destructive) {
        $resp = [System.Windows.MessageBox]::Show(
            "$($def.displayName) is a DESTRUCTIVE operation.`r`n`r`nThe tool will ask for its own confirmations, but do you want to launch it on THIS machine?",
            "iDezign Toolkit - Confirm",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        if ($resp -ne [System.Windows.MessageBoxResult]::Yes) {
            Set-Status ("Cancelled {0}" -f $def.displayName) '#8A8A8A'
            return
        }
    }
    Start-Tool $key
}

function New-ScriptRow {
    # v2.8 visual upgrade:
    #   * Prefixes each row with the emoji from the manifest "icon" field
    #     (Segoe UI Emoji forced so PS 5.1 / WPF renders the glyphs reliably).
    #   * For destructive tools, appends a small crimson "DESTRUCTIVE" pill
    #     badge next to the name, in addition to the existing red text colour.
    #   * Subtitle column stays right-aligned (auto width) as before.
    param($Def)

    $brush = New-Object System.Windows.Media.BrushConverter

    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = $window.FindResource('ScriptRow')
    $btn.Tag   = $Def.key

    $g = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = [System.Windows.GridLength]::Auto
    $g.ColumnDefinitions.Add($c1)
    $g.ColumnDefinitions.Add($c2)

    # Left side = horizontal StackPanel of [icon] [name] [optional DESTRUCTIVE badge]
    $left = New-Object System.Windows.Controls.StackPanel
    $left.Orientation = 'Horizontal'
    $left.VerticalAlignment = 'Center'

    if ($Def.icon) {
        $iconBlock = New-Object System.Windows.Controls.TextBlock
        $iconBlock.Text = [string]$Def.icon
        $iconBlock.FontSize = 16
        $iconBlock.VerticalAlignment = 'Center'
        $iconBlock.Margin = [System.Windows.Thickness]::new(0,0,10,0)
        # Force the emoji font so PS5.1/WPF picks colour glyphs over fallback boxes
        try { $iconBlock.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI Emoji' } catch { }
        [void]$left.Children.Add($iconBlock)
    }

    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = [string]$Def.displayName
    $name.FontSize = 13
    $name.VerticalAlignment = 'Center'
    if ($Def.destructive) {
        $name.Foreground = $brush.ConvertFromString('#A82828')
        $name.FontWeight = 'SemiBold'
    } else {
        $name.Foreground = $brush.ConvertFromString('#161616')
    }
    [void]$left.Children.Add($name)

    if ($Def.destructive) {
        $badge = New-Object System.Windows.Controls.Border
        $badge.Background = $brush.ConvertFromString('#A82828')
        $badge.CornerRadius = New-Object System.Windows.CornerRadius(3)
        $badge.Padding = [System.Windows.Thickness]::new(6,1,6,2)
        $badge.Margin = [System.Windows.Thickness]::new(8,0,0,0)
        $badge.VerticalAlignment = 'Center'

        $badgeText = New-Object System.Windows.Controls.TextBlock
        $badgeText.Text = 'DESTRUCTIVE'
        $badgeText.FontSize = 9
        $badgeText.FontWeight = 'Bold'
        $badgeText.Foreground = $brush.ConvertFromString('#FFFFFF')
        $badge.Child = $badgeText

        [void]$left.Children.Add($badge)
    }

    [System.Windows.Controls.Grid]::SetColumn($left, 0)
    [void]$g.Children.Add($left)

    if ($Def.subtitle) {
        $sub = New-Object System.Windows.Controls.TextBlock
        $sub.Text = [string]$Def.subtitle
        $sub.FontSize = 11
        $sub.VerticalAlignment = 'Center'
        $sub.Margin = [System.Windows.Thickness]::new(12,0,0,0)
        $sub.Foreground = $brush.ConvertFromString('#8A8A8A')
        [System.Windows.Controls.Grid]::SetColumn($sub, 1)
        [void]$g.Children.Add($sub)
    }

    $btn.Content = $g
    $btn.Add_Click($row_Click)
    return $btn
}

Write-Diag ("CP: building {0} rows" -f $ToolDefs.Count)
foreach ($def in $ToolDefs) {
    try {
        $row = New-ScriptRow -Def $def
        [void]$ui.RowsPanel.Children.Add($row)
        Write-Diag ("CP: built row {0}" -f $def.key)
    } catch {
        Write-Diag ("ERR building row {0}: {1}" -f $def.key, $_.Exception.Message)
    }
}

# --- Header: drag + double-click maximize; window controls -------------------
$script:PrevBounds = $null
$titleBar_MouseDown = {
    param($sender, $e)
    Write-Diag ("titlebar mousedown: clicks={0}" -f $e.ClickCount)
    if ($e.ClickCount -eq 2) {
        if ($script:PrevBounds) {
            $window.Left   = $script:PrevBounds.Left
            $window.Top    = $script:PrevBounds.Top
            $window.Width  = $script:PrevBounds.Width
            $window.Height = $script:PrevBounds.Height
            $script:PrevBounds = $null
        } else {
            $wa = [System.Windows.SystemParameters]::WorkArea
            $script:PrevBounds = [PSCustomObject]@{
                Left = $window.Left; Top = $window.Top
                Width = $window.Width; Height = $window.Height
            }
            $window.Left = $wa.Left; $window.Top = $wa.Top
            $window.Width = $wa.Width; $window.Height = $wa.Height
        }
        return
    }
    if ($e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
        try { $window.DragMove() } catch { Write-Diag ("DragMove err: {0}" -f $_.Exception.Message) }
    }
}
$ui.TitleBar.add_MouseLeftButtonDown($titleBar_MouseDown)
$ui.BtnMin.add_Click({ $window.WindowState = [System.Windows.WindowState]::Minimized })
$ui.BtnClose.add_Click({ $window.Close() })

# --- Show the window (crash-safe Application.Run) ----------------------------
try {
    $window.WindowStartupLocation = 'Manual'
    $window.Left = 140; $window.Top = 120
    $window.WindowState = 'Normal'
    $window.Topmost = $false
    $window.ShowInTaskbar = $true
} catch { }

Set-Status ("Ready - {0} scripts loaded." -f $ToolDefs.Count)
Write-Diag 'CP: about to present window'
try {
    if (-not [System.Windows.Application]::Current) {
        $app = New-Object System.Windows.Application
        $app.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
        $app.add_DispatcherUnhandledException({
            param($src, $e)
            Write-Diag ("DISPATCHER EXC (handled): {0}: {1}" -f $e.Exception.GetType().FullName, $e.Exception.Message)
            $e.Handled = $true
        })
        $app.Run($window)
    } else {
        [void]$window.ShowDialog()
    }
} catch {
    Write-Diag ("present catch: {0}" -f $_.Exception.Message)
    try { [void]$window.ShowDialog() } catch { }
}
Write-Diag 'CP: window closed'
