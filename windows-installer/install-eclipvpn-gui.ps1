# install-eclipvpn-gui.ps1 - EclipVPN offline installer, modern WPF GUI (Stage 2).
#
# Dark "card" window over eclip-core.ps1. Auto-detects the router (prefills the
# default gateway, then scans common IPs for an SSH/dropbear banner in the
# background), pick a language (EN/RU), enter the password, press Install, watch
# a colored log. The install + the scan run in background runspaces so the UI
# never freezes; updates flow back through a thread-safe state drained by
# DispatcherTimers on the UI thread.
#
# Launch:  powershell -STA -ExecutionPolicy Bypass -File install-eclipvpn-gui.ps1
# Smoke test (build window, auto-close): set ECLIP_GUI_SMOKE=1 first.
#
# Keep this file pure ASCII (PS 5.1 reads a BOM-less script as ANSI). English UI
# text is inline; Russian lives in lang.ru.txt (UTF-8) read as DATA.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# The WPF window is hosted by powershell.exe, so by default the taskbar shows
# PowerShell's icon and groups it under "Windows PowerShell". Claiming our own
# AppUserModelID (before any window exists) makes the taskbar use our window
# icon and group under EclipVPN instead.
try {
    $appIdT = Add-Type -PassThru -Name 'EclipShell' -Namespace 'EclipVPN' -MemberDefinition `
        '[DllImport("shell32.dll", SetLastError=true)] public static extern void SetCurrentProcessExplicitAppUserModelID(string AppID);'
    $appIdT::SetCurrentProcessExplicitAppUserModelID("EclipVPN.Installer")
} catch {}

$Self = $PSScriptRoot

# English strings (ASCII). RU overrides come from lang.ru.txt next to this file.
$TEN = [ordered]@{
    subtitle    = "Offline router installer"
    host        = "Router IP"
    user        = "User"
    pass        = "Password"
    install     = "Install"
    detect      = "Detect"
    searching   = "Looking for your router..."
    foundFmt    = "Router: {0}"
    typeOpenwrt = "(OpenWrt)"
    typeSsh     = "(SSH)"
    notFound    = "No router found - enter the IP manually"
    ready       = "Ready to install."
    starting    = "Starting..."
    needHost    = "Enter the router IP address."
    needPass    = "Enter the router password."
    doneFmt     = "Done. Open  http://{0}/eclipvpn/"
    failed      = "Failed - see the log above."
}
function Load-Lang([string]$file) {
    $d = [ordered]@{}; foreach ($k in $TEN.Keys) { $d[$k] = $TEN[$k] }
    if (Test-Path $file) {
        try {
            foreach ($line in [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)) {
                if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
                $k = $line.Substring(0, $line.IndexOf('=')).Trim()
                $v = $line.Substring($line.IndexOf('=') + 1).Trim()
                if ($d.Contains($k)) { $d[$k] = $v }
            }
        } catch {}
    }
    return $d
}
$langs = @{ EN = $TEN; RU = (Load-Lang (Join-Path $Self "lang.ru.txt")) }
$script:Tcur = $TEN

# Shared state for the worker runspaces (install + scan).
$sync = [hashtable]::Synchronized(@{
    q = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
    pct = 0; pctLabel = ""; done = $false; ok = $false; err = ""; running = $false
    ps = $null; handle = $null
    scanDone = $false; foundIp = ""; foundType = ""; scanPs = $null; scanHandle = $null
})

$xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" Width="660" Height="610"
        FontFamily="Segoe UI" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Card"    Color="#1B1C28"/>
    <SolidColorBrush x:Key="Field"   Color="#252739"/>
    <SolidColorBrush x:Key="Stroke"  Color="#2E3146"/>
    <SolidColorBrush x:Key="Text"    Color="#C8CEE8"/>
    <SolidColorBrush x:Key="Muted"   Color="#797E9E"/>
    <SolidColorBrush x:Key="Accent"  Color="#7C6CF7"/>
    <SolidColorBrush x:Key="AccentHi" Color="#9384FA"/>
    <SolidColorBrush x:Key="LogBg"   Color="#101019"/>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Field}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="9"
                    BorderBrush="{StaticResource Stroke}" BorderThickness="1">
              <ScrollViewer x:Name="PART_ContentHost" Margin="2" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="PasswordBox">
      <Setter Property="Background" Value="{StaticResource Field}"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="9"
                    BorderBrush="{StaticResource Stroke}" BorderThickness="1">
              <ScrollViewer x:Name="PART_ContentHost" Margin="2" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="AccentBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{StaticResource Accent}" CornerRadius="10" Padding="14,10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="{StaticResource AccentHi}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="b" Property="Background" Value="{StaticResource Stroke}"/>
                <Setter Property="Foreground" Value="{StaticResource Muted}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Lang" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="7" Padding="9,4" Margin="2,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Close" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="8" Width="30" Height="30">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#F7768E"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Background" Value="{StaticResource Field}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border Background="{TemplateBinding Background}" CornerRadius="3">
              <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}"
                      CornerRadius="3" HorizontalAlignment="Left"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border Margin="14" CornerRadius="16" Background="{StaticResource Card}"
          BorderBrush="{StaticResource Stroke}" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="28" ShadowDepth="0" Opacity="0.55" Color="#000000"/>
    </Border.Effect>
    <Grid Margin="26,18,26,22">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- header / drag bar -->
      <Grid x:Name="titleBar" Grid.Row="0" Background="Transparent">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Image x:Name="logo" Width="26" Height="26" Margin="0,0,10,0" VerticalAlignment="Center" RenderOptions.BitmapScalingMode="HighQuality"/>
          <TextBlock x:Name="tTitle" Text="EclipVPN" Foreground="{StaticResource Text}" FontSize="19" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <TextBlock x:Name="tSub" Text="installer" Foreground="{StaticResource Muted}" FontSize="13" Margin="10,2,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
          <Button x:Name="btnEN" Style="{StaticResource Lang}" Content="EN"/>
          <Button x:Name="btnRU" Style="{StaticResource Lang}" Content="RU"/>
          <Button x:Name="btnClose" Style="{StaticResource Close}" Content="x" Margin="8,0,0,0"/>
        </StackPanel>
      </Grid>

      <!-- IP + User -->
      <Grid Grid.Row="1" Margin="0,22,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="16"/>
          <ColumnDefinition Width="170"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <Grid Height="26" Margin="2,0,0,4">
            <TextBlock x:Name="lHost" Text="Router IP" Foreground="{StaticResource Muted}" FontSize="12" VerticalAlignment="Center"/>
            <Button x:Name="btnDetect" Style="{StaticResource Lang}" Content="Detect" HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
          <TextBox x:Name="txtHost" Text="192.168.1.1"/>
          <TextBlock x:Name="lblFound" Text="" Foreground="{StaticResource Muted}" FontSize="11" Margin="2,5,0,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <StackPanel Grid.Column="2">
          <Grid Height="26" Margin="2,0,0,4">
            <TextBlock x:Name="lUser" Text="User" Foreground="{StaticResource Muted}" FontSize="12" VerticalAlignment="Center"/>
          </Grid>
          <TextBox x:Name="txtUser" Text="root"/>
        </StackPanel>
      </Grid>

      <!-- Password -->
      <StackPanel Grid.Row="2" Margin="0,12,0,0">
        <TextBlock x:Name="lPass" Text="Password" Foreground="{StaticResource Muted}" FontSize="12" Margin="2,0,0,5"/>
        <PasswordBox x:Name="txtPass"/>
      </StackPanel>

      <!-- Install -->
      <Button x:Name="btnInstall" Grid.Row="3" Style="{StaticResource AccentBtn}" Content="Install" Margin="0,18,0,0"/>

      <!-- progress + status -->
      <ProgressBar x:Name="bar" Grid.Row="4" Minimum="0" Maximum="100" Value="0" Margin="0,16,0,0"/>
      <TextBlock x:Name="lblStatus" Grid.Row="5" Text="Ready." Foreground="{StaticResource Muted}" FontSize="12" Margin="2,10,0,0"/>

      <!-- log -->
      <Border Grid.Row="6" Margin="0,12,0,0" CornerRadius="10" Background="{StaticResource LogBg}"
              BorderBrush="{StaticResource Stroke}" BorderThickness="1">
        <ScrollViewer x:Name="logScroll" VerticalScrollBarVisibility="Auto" Padding="12,10">
          <StackPanel x:Name="logPanel"/>
        </ScrollViewer>
      </Border>
    </Grid>
  </Border>
</Window>
'@

[xml]$xaml = $xamlStr
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))

$ctl = @{}
"titleBar","btnClose","btnEN","btnRU","btnDetect","logo","tTitle","tSub","lHost","lUser","lPass","lblFound","txtHost","txtUser","txtPass","btnInstall","bar","lblStatus","logScroll","logPanel" |
    ForEach-Object { $ctl[$_] = $window.FindName($_) }

# logo / window icon (the eclipse mark) - one .ico for header, taskbar and exe
$icoPath = Join-Path $Self "eclip.ico"
if (Test-Path $icoPath) {
    try {
        $img = New-Object Windows.Media.Imaging.BitmapImage
        $img.BeginInit(); $img.UriSource = New-Object Uri($icoPath); $img.CacheOption = "OnLoad"; $img.EndInit()
        $ctl.logo.Source = $img
        $window.Icon = $img
    } catch {}
}

# brushes
function _rgb($r,$g,$b) { New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb($r,$g,$b)) }
$accentBrush = _rgb 124 108 247
$mutedBrush  = _rgb 121 126 158
$whiteBrush  = [Windows.Media.Brushes]::White
$clearBrush  = [Windows.Media.Brushes]::Transparent
$brush = @{ step = (_rgb 122 162 247); ok = (_rgb 150 156 196); warn = (_rgb 224 175 104); err = (_rgb 247 118 142); done = (_rgb 158 206 106) }

# router-detection display state
$script:autoHost = ""
$script:scanning = $false
$script:scanShown = $false
$script:fIp = ""
$script:fType = ""

function Render-Found {
    if ($script:scanning) { $ctl.lblFound.Text = $script:Tcur.searching; return }
    if ($script:fIp) {
        $sfx = switch ($script:fType) { "dropbear" { " " + $script:Tcur.typeOpenwrt } "ssh" { " " + $script:Tcur.typeSsh } default { "" } }
        $ctl.lblFound.Text = ($script:Tcur.foundFmt -f ($script:fIp + $sfx)); return
    }
    if ($script:scanShown) { $ctl.lblFound.Text = $script:Tcur.notFound; return }
    $ctl.lblFound.Text = ""
}

# apply a language to all chrome + remember it for runtime messages
function Apply-Lang([string]$code) {
    $t = $langs[$code]; $script:Tcur = $t
    $ctl.tSub.Text          = $t.subtitle
    $ctl.lHost.Text         = $t.host
    $ctl.lUser.Text         = $t.user
    $ctl.lPass.Text         = $t.pass
    $ctl.btnInstall.Content = $t.install
    $ctl.btnDetect.Content  = $t.detect
    if (-not $sync.running -and -not $sync.done) { $ctl.lblStatus.Text = $t.ready }
    Render-Found
    if ($code -eq "RU") { $ctl.btnRU.Background = $accentBrush; $ctl.btnRU.Foreground = $whiteBrush; $ctl.btnEN.Background = $clearBrush; $ctl.btnEN.Foreground = $mutedBrush }
    else                { $ctl.btnEN.Background = $accentBrush; $ctl.btnEN.Foreground = $whiteBrush; $ctl.btnRU.Background = $clearBrush; $ctl.btnRU.Foreground = $mutedBrush }
}

function Add-Log($text,$lvl) {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text
    $tb.Foreground = $(if ($brush.ContainsKey($lvl)) { $brush[$lvl] } else { $brush.ok })
    $tb.FontFamily = New-Object Windows.Media.FontFamily("Consolas")
    $tb.FontSize = 12.5
    $tb.TextWrapping = "Wrap"
    $tb.Margin = "0,1,0,1"
    [void]$ctl.logPanel.Children.Add($tb)
    $ctl.logScroll.ScrollToBottom()
}

# --- router auto-detection -----------------------------------------------
$scanTimer = New-Object System.Windows.Threading.DispatcherTimer
$scanTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$scanTimer.Add_Tick({
    if (-not $sync.scanDone) { return }
    $scanTimer.Stop()
    try { if ($sync.scanPs) { $sync.scanPs.EndInvoke($sync.scanHandle); $sync.scanPs.Runspace.Close(); $sync.scanPs.Dispose() } } catch {}
    $sync.scanPs = $null
    $script:scanning = $false; $script:scanShown = $true
    $script:fIp = [string]$sync.foundIp; $script:fType = [string]$sync.foundType
    # only auto-fill if the user has not edited the field themselves
    if ($script:fIp -and ($ctl.txtHost.Text -eq $script:autoHost)) { $ctl.txtHost.Text = $script:fIp; $script:autoHost = $script:fIp }
    Render-Found
})
function Start-Scan {
    if ($script:scanning) { return }
    $script:scanning = $true; $sync.scanDone = $false; $sync.foundIp = ""; $sync.foundType = ""
    Render-Found
    $rs = [RunspaceFactory]::CreateRunspace(); $rs.Open(); $rs.SessionStateProxy.SetVariable("sync", $sync)
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        function Probe([string]$ip) {
            try {
                $c = New-Object Net.Sockets.TcpClient
                $iar = $c.BeginConnect($ip, 22, $null, $null)
                if (-not ($iar.AsyncWaitHandle.WaitOne(500) -and $c.Connected)) { $c.Close(); return $null }
                $c.EndConnect($iar); $c.ReceiveTimeout = 700
                $ns = $c.GetStream(); Start-Sleep -Milliseconds 180
                $buf = New-Object byte[] 128; $n = 0; try { $n = $ns.Read($buf, 0, 128) } catch {}
                $c.Close()
                if ($n -gt 0) { return [Text.Encoding]::ASCII.GetString($buf, 0, $n) } else { return "" }
            } catch { return $null }
        }
        $cands = @()
        try { $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).NextHop; if ($gw -and $gw -ne '0.0.0.0') { $cands += $gw } } catch {}
        foreach ($ip in '192.168.1.1','192.168.0.1','192.168.10.1','192.168.8.1','192.168.2.1','192.168.31.1','192.168.50.1','10.0.0.1') { if ($cands -notcontains $ip) { $cands += $ip } }
        $fip = ""; $ftype = ""
        foreach ($ip in $cands) {
            $b = Probe $ip
            if ($b -ne $null) {
                if ($b -match 'dropbear') { $fip = $ip; $ftype = 'dropbear'; break }
                if (-not $fip) { if ($b -match 'SSH') { $fip = $ip; $ftype = 'ssh' } else { $fip = $ip; $ftype = '' } }
            }
        }
        $sync.foundIp = $fip; $sync.foundType = $ftype; $sync.scanDone = $true
    })
    $sync.scanPs = $ps; $sync.scanHandle = $ps.BeginInvoke()
    $scanTimer.Start()
}

# header behaviour
# Drag from anywhere on the window: inputs/buttons handle their own clicks (mark
# the event handled), so a press on empty card area / labels / the header moves
# the window, while clicks on controls behave normally.
$window.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch {} })
$ctl.btnClose.Add_Click({ $window.Close() })
$ctl.btnEN.Add_Click({ Apply-Lang "EN" })
$ctl.btnRU.Add_Click({ Apply-Lang "RU" })
$ctl.btnDetect.Add_Click({ Start-Scan })

# default language from the OS culture
$defLang = if ((Get-Culture).TwoLetterISOLanguageName -eq "ru") { "RU" } else { "EN" }
Apply-Lang $defLang

# UI timer drains the install worker queue
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(120)
$timer.Add_Tick({
    $item = $null
    while ($sync.q.TryDequeue([ref]$item)) {
        $prefix = switch ($item.lvl) { "step" {"> "} "err" {"x "} "done" {""} default {"  "} }
        Add-Log ($prefix + $item.m) $item.lvl
    }
    $p = [int]$sync.pct; if ($p -lt 0) { $p = 0 }; if ($p -gt 100) { $p = 100 }
    $ctl.bar.Value = $p
    if ($sync.pctLabel) { $ctl.lblStatus.Text = ("{0}  {1}%" -f $sync.pctLabel, $p) }
    if ($sync.done) {
        $timer.Stop()
        try { if ($sync.ps) { $sync.ps.EndInvoke($sync.handle); $sync.ps.Runspace.Close(); $sync.ps.Dispose() } } catch {}
        $sync.ps = $null; $sync.running = $false
        $ctl.btnInstall.IsEnabled = $true
        if ($sync.ok) { $ctl.lblStatus.Text = ($script:Tcur.doneFmt -f $ctl.txtHost.Text); $ctl.bar.Value = 100 }
        else { Add-Log ("x " + $sync.err) "err"; $ctl.lblStatus.Text = $script:Tcur.failed }
    }
})

# Install -> background runspace
$ctl.btnInstall.Add_Click({
    if ($sync.running) { return }
    if (-not $ctl.txtHost.Text.Trim()) { [void][Windows.MessageBox]::Show($script:Tcur.needHost, "EclipVPN"); return }
    if (-not $ctl.txtPass.Password)    { [void][Windows.MessageBox]::Show($script:Tcur.needPass, "EclipVPN"); return }

    $ctl.logPanel.Children.Clear()
    $item = $null; while ($sync.q.TryDequeue([ref]$item)) {}
    $sync.pct = 0; $sync.pctLabel = ""; $sync.done = $false; $sync.ok = $false; $sync.err = ""; $sync.running = $true
    $ctl.btnInstall.IsEnabled = $false; $ctl.bar.Value = 0; $ctl.lblStatus.Text = $script:Tcur.starting

    $rs = [RunspaceFactory]::CreateRunspace(); $rs.ApartmentState = "STA"; $rs.Open()
    $rs.SessionStateProxy.SetVariable("sync",  $sync)
    $rs.SessionStateProxy.SetVariable("self",  $Self)
    $rs.SessionStateProxy.SetVariable("rhost", $ctl.txtHost.Text.Trim())
    $rs.SessionStateProxy.SetVariable("ruser", $ctl.txtUser.Text.Trim())
    $rs.SessionStateProxy.SetVariable("rpass", $ctl.txtPass.Password)
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        . (Join-Path $self "eclip-core.ps1")
        $logcb  = { param($m,$lvl) $sync.q.Enqueue(@{ m = $m; lvl = $lvl }) }
        $progcb = { param($label,$p) $sync.pctLabel = $label; $sync.pct = $p }
        try {
            Invoke-EclipInstall -RouterHost $rhost -User $ruser -Password $rpass -Port 22 `
                -SelfDir $self -Log $logcb -Progress $progcb | Out-Null
            $sync.ok = $true
        } catch { $sync.err = $_.Exception.Message; $sync.ok = $false }
        finally { $sync.done = $true }
    })
    $sync.ps = $ps
    $sync.handle = $ps.BeginInvoke()
    $timer.Start()
})

# auto-find the router (skip under smoke to keep it fast/headless)
if ($env:ECLIP_GUI_SMOKE -ne "1") {
    $script:autoHost = $ctl.txtHost.Text
    try {
        $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).NextHop
        if ($gw -and $gw -ne '0.0.0.0') { $ctl.txtHost.Text = $gw; $script:autoHost = $gw }
    } catch {}
    $window.Add_Loaded({ Start-Scan })
}

# smoke test: show, auto-close, leave a marker (so a winexe launcher can verify)
if ($env:ECLIP_GUI_SMOKE -eq "1") {
    $st = New-Object System.Windows.Threading.DispatcherTimer
    $st.Interval = [TimeSpan]::FromMilliseconds(1200)
    $st.Add_Tick({ $st.Stop(); $window.Close() })
    $window.Add_Loaded({ $st.Start() })
    [void]$window.ShowDialog()
    try { Set-Content -LiteralPath (Join-Path $env:TEMP "eclip_gui_smoke.ok") -Value "ok" -Encoding ASCII } catch {}
    return
}

[void]$window.ShowDialog()
