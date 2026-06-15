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
    starting    = "Starting..."
    needHost    = "Enter the router IP address."
    needPass    = "Enter the router password."
    openBtn     = "Open EclipVPN"
    urlFmt      = "http://{0}/eclipvpn/"
    next        = "Next"
    back        = "Back"
    retry       = "Retry"
    close       = "Close"
    stepFmt     = "Step {0} of 4"
    welcomeTitle   = "Welcome to EclipVPN"
    welcomeTagline = "Install EclipVPN onto your OpenWrt router over SSH. Fully offline - no internet needed."
    bullet1     = "Works without GitHub or internet access"
    bullet2     = "Auto-detects your router on the network"
    bullet3     = "Takes about a minute"
    connectTitle = "Connect to your router"
    connectHint  = "Enter the router address and password."
    installTitle = "Installing EclipVPN"
    doneTitle    = "Installed and running"
    failTitle    = "Installation failed"
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
    <SolidColorBrush x:Key="Ok"      Color="#9ECE6A"/>
    <SolidColorBrush x:Key="OkHi"    Color="#B4E07F"/>

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

    <Style x:Key="SuccessBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{StaticResource Ok}" CornerRadius="10" Padding="14,10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="{StaticResource OkHi}"/>
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
    <Grid Margin="26,18,26,20">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- header / drag bar (persistent across all steps) -->
      <Grid x:Name="titleBar" Grid.Row="0" Background="Transparent">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Image x:Name="logo" Width="26" Height="26" Margin="0,0,10,0" VerticalAlignment="Center" RenderOptions.BitmapScalingMode="HighQuality"/>
          <TextBlock x:Name="tTitle" Text="EclipVPN" Foreground="{StaticResource Text}" FontSize="19" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <TextBlock x:Name="tSub" Text="installer" Foreground="{StaticResource Muted}" FontSize="13" Margin="10,2,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <TextBlock x:Name="lblStepN" Text="" Foreground="{StaticResource Muted}" FontSize="11" VerticalAlignment="Center" Margin="0,0,12,0"/>
          <Button x:Name="btnEN" Style="{StaticResource Lang}" Content="EN"/>
          <Button x:Name="btnRU" Style="{StaticResource Lang}" Content="RU"/>
          <Button x:Name="btnClose" Style="{StaticResource Close}" Content="x" Margin="8,0,0,0"/>
        </StackPanel>
      </Grid>

      <!-- step body: 4 panels share this cell; Show-Step flips Visibility -->
      <Grid Grid.Row="1" Margin="0,20,0,0">

        <!-- step 1: welcome -->
        <StackPanel x:Name="pnlWelcome" VerticalAlignment="Center" HorizontalAlignment="Center">
          <Image x:Name="logoBig" Width="64" Height="64" HorizontalAlignment="Center" Margin="0,0,0,16" RenderOptions.BitmapScalingMode="HighQuality"/>
          <TextBlock x:Name="wTitle" Text="" Foreground="{StaticResource Text}" FontSize="21" FontWeight="SemiBold" HorizontalAlignment="Center"/>
          <TextBlock x:Name="wTagline" Text="" Foreground="{StaticResource Muted}" FontSize="13" TextWrapping="Wrap" TextAlignment="Center" MaxWidth="430" Margin="0,10,0,18"/>
          <StackPanel x:Name="wBullets" HorizontalAlignment="Left"/>
        </StackPanel>

        <!-- step 2: connect -->
        <StackPanel x:Name="pnlConnect" VerticalAlignment="Center" Visibility="Collapsed">
          <TextBlock x:Name="cTitle" Text="" Foreground="{StaticResource Text}" FontSize="17" FontWeight="SemiBold"/>
          <TextBlock x:Name="cHint" Text="" Foreground="{StaticResource Muted}" FontSize="12" Margin="0,5,0,18"/>
          <Grid>
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
          <StackPanel Margin="0,14,0,0">
            <TextBlock x:Name="lPass" Text="Password" Foreground="{StaticResource Muted}" FontSize="12" Margin="2,0,0,5"/>
            <PasswordBox x:Name="txtPass"/>
          </StackPanel>
        </StackPanel>

        <!-- step 3: installing -->
        <Grid x:Name="pnlInstall" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock x:Name="iTitle" Grid.Row="0" Text="" Foreground="{StaticResource Text}" FontSize="17" FontWeight="SemiBold"/>
          <ProgressBar x:Name="bar" Grid.Row="1" Minimum="0" Maximum="100" Value="0" Margin="0,16,0,0"/>
          <TextBlock x:Name="lblStatus" Grid.Row="2" Text="" Foreground="{StaticResource Muted}" FontSize="12" TextWrapping="Wrap" Margin="2,10,0,0"/>
          <Border Grid.Row="3" Margin="0,12,0,0" CornerRadius="10" Background="{StaticResource LogBg}"
                  BorderBrush="{StaticResource Stroke}" BorderThickness="1">
            <ScrollViewer x:Name="logScroll" VerticalScrollBarVisibility="Auto" Padding="12,10">
              <StackPanel x:Name="logPanel"/>
            </ScrollViewer>
          </Border>
        </Grid>

        <!-- step 4: done (success) -->
        <StackPanel x:Name="pnlDone" VerticalAlignment="Center" HorizontalAlignment="Center" Visibility="Collapsed">
          <TextBlock x:Name="dIcon" Text="" FontSize="48" FontWeight="Bold" HorizontalAlignment="Center"/>
          <TextBlock x:Name="dTitle" Text="" Foreground="{StaticResource Text}" FontSize="20" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,10,0,0"/>
          <TextBlock x:Name="dBody" Text="" Foreground="{StaticResource Muted}" FontSize="13" TextWrapping="Wrap" TextAlignment="Center" MaxWidth="470" Margin="0,10,0,0"/>
        </StackPanel>

      </Grid>

      <!-- footer: Show-Step / the install timer pick which buttons are visible -->
      <Grid Grid.Row="2" Margin="0,18,0,0">
        <Button x:Name="btnBack"   Style="{StaticResource Lang}" Content="Back"  HorizontalAlignment="Left" VerticalAlignment="Center" Visibility="Collapsed"/>
        <Button x:Name="btnFinish" Style="{StaticResource Lang}" Content="Close" HorizontalAlignment="Left" VerticalAlignment="Center" Visibility="Collapsed"/>
        <Button x:Name="btnNext"    Style="{StaticResource AccentBtn}"  Content="Next"          HorizontalAlignment="Right" MinWidth="150" Visibility="Collapsed"/>
        <Button x:Name="btnInstall" Style="{StaticResource AccentBtn}"  Content="Install"       HorizontalAlignment="Right" MinWidth="150" Visibility="Collapsed"/>
        <Button x:Name="btnRetry"   Style="{StaticResource AccentBtn}"  Content="Retry"         HorizontalAlignment="Right" MinWidth="150" Visibility="Collapsed"/>
        <Button x:Name="btnOpen"    Style="{StaticResource SuccessBtn}" Content="Open EclipVPN" HorizontalAlignment="Right" MinWidth="150" Visibility="Collapsed"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

[xml]$xaml = $xamlStr
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))

$ctl = @{}
"titleBar","btnClose","btnEN","btnRU","btnDetect","logo","tTitle","tSub","lblStepN","lHost","lUser","lPass","lblFound","txtHost","txtUser","txtPass","btnInstall","btnOpen","bar","lblStatus","logScroll","logPanel",
"logoBig","pnlWelcome","wTitle","wTagline","wBullets","pnlConnect","cTitle","cHint","pnlInstall","iTitle","pnlDone","dIcon","dTitle","dBody","btnBack","btnFinish","btnNext","btnRetry" |
    ForEach-Object { $ctl[$_] = $window.FindName($_) }

# logo / window icon (the eclipse mark) - one .ico for header, taskbar and exe
$icoPath = Join-Path $Self "eclip.ico"
if (Test-Path $icoPath) {
    try {
        $img = New-Object Windows.Media.Imaging.BitmapImage
        $img.BeginInit(); $img.UriSource = New-Object Uri($icoPath); $img.CacheOption = "OnLoad"; $img.EndInit()
        $ctl.logo.Source = $img
        $ctl.logoBig.Source = $img
        $window.Icon = $img
    } catch {}
}

# brushes
function _rgb($r,$g,$b) { New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb($r,$g,$b)) }
$accentBrush = _rgb 124 108 247
$mutedBrush  = _rgb 121 126 158
$textBrush   = _rgb 200 206 232
$whiteBrush  = [Windows.Media.Brushes]::White
$clearBrush  = [Windows.Media.Brushes]::Transparent
$brush = @{ step = (_rgb 122 162 247); ok = (_rgb 150 156 196); warn = (_rgb 224 175 104); err = (_rgb 247 118 142); done = (_rgb 158 206 106) }

# router-detection display state
$script:autoHost = ""
$script:scanning = $false
$script:scanShown = $false
$script:fIp = ""
$script:fType = ""

# wizard state: current step (1..4) and whether the SSH-banner scan has fired.
$script:step = 1
$script:scanStarted = $false

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
    $ctl.btnOpen.Content    = $t.openBtn
    $ctl.btnNext.Content    = $t.next
    $ctl.btnBack.Content    = $t.back
    $ctl.btnRetry.Content   = $t.retry
    $ctl.btnFinish.Content  = $t.close
    $ctl.wTitle.Text        = $t.welcomeTitle
    $ctl.wTagline.Text      = $t.welcomeTagline
    $ctl.cTitle.Text        = $t.connectTitle
    $ctl.cHint.Text         = $t.connectHint
    $ctl.iTitle.Text        = $t.installTitle
    Build-Bullets
    if ($script:step -ne 4) { $ctl.lblStepN.Text = ($t.stepFmt -f $script:step) }
    # If a run already finished, re-localize the result view in place.
    if ($sync.done -and $sync.ok) { $ctl.dTitle.Text = $t.doneTitle; $ctl.dBody.Text = ($t.urlFmt -f $ctl.txtHost.Text) }
    elseif ($sync.done) { $ctl.iTitle.Text = $t.failTitle }
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

# Rebuild the welcome bullet list from the current language (called by Apply-Lang
# so it relocalizes on EN/RU toggle). ASCII "- " prefix keeps the .ps1 ASCII.
function Build-Bullets {
    $ctl.wBullets.Children.Clear()
    foreach ($k in "bullet1","bullet2","bullet3") {
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = "- " + $script:Tcur[$k]
        $tb.Foreground = $mutedBrush
        $tb.FontSize = 13
        $tb.TextWrapping = "Wrap"
        $tb.Margin = "0,3,0,0"
        [void]$ctl.wBullets.Children.Add($tb)
    }
}

# Wizard step controller. Flips panel Visibility (panels stay in the tree so the
# timers can always write to bar/log/host without throwing) and picks which
# footer buttons show. Step 3 has no footer buttons; step 4's result buttons are
# set by the install timer's done-branch.
function Show-Step([int]$n) {
    $script:step = $n
    $ctl.pnlWelcome.Visibility = $(if ($n -eq 1) { 'Visible' } else { 'Collapsed' })
    $ctl.pnlConnect.Visibility = $(if ($n -eq 2) { 'Visible' } else { 'Collapsed' })
    $ctl.pnlInstall.Visibility = $(if ($n -eq 3) { 'Visible' } else { 'Collapsed' })
    $ctl.pnlDone.Visibility    = $(if ($n -eq 4) { 'Visible' } else { 'Collapsed' })
    foreach ($b in 'btnBack','btnFinish','btnNext','btnInstall','btnRetry','btnOpen') { $ctl[$b].Visibility = 'Collapsed' }
    if     ($n -eq 1) { $ctl.btnNext.Visibility = 'Visible' }
    elseif ($n -eq 2) { $ctl.btnBack.Visibility = 'Visible'; $ctl.btnInstall.Visibility = 'Visible' }
    if ($n -eq 4) { $ctl.lblStepN.Visibility = 'Collapsed' }
    else { $ctl.lblStepN.Visibility = 'Visible'; $ctl.lblStepN.Text = ($script:Tcur.stepFmt -f $n) }
    if ($n -eq 2) { $ctl.txtPass.Focus() }
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
# Open the freshly installed UI in the default browser.
$ctl.btnOpen.Add_Click({
    $h = $ctl.txtHost.Text.Trim()
    if ($h) { try { Start-Process ("http://{0}/eclipvpn/" -f $h) } catch {} }
})
# wizard navigation
$ctl.btnNext.Add_Click({
    Show-Step 2
    if (-not $script:scanStarted) { $script:scanStarted = $true; Start-Scan }  # deferred router scan
})
$ctl.btnBack.Add_Click({ if ($script:step -le 2) { Show-Step 1 } else { Show-Step 2 } })
$ctl.btnRetry.Add_Click({ Show-Step 2 })
$ctl.btnFinish.Add_Click({ $window.Close() })

# default language from the OS culture, then start on the welcome step
$defLang = if ((Get-Culture).TwoLetterISOLanguageName -eq "ru") { "RU" } else { "EN" }
Apply-Lang $defLang
Show-Step 1

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
        if ($sync.ok) {
            # Success -> step 4 (Done): green check, the URL, and Open/Close.
            Show-Step 4
            $ctl.dIcon.Text = [char]0x2713; $ctl.dIcon.Foreground = $brush.done
            $ctl.dTitle.Text = $script:Tcur.doneTitle
            $ctl.dBody.Text = ($script:Tcur.urlFmt -f $ctl.txtHost.Text)
            $ctl.btnOpen.Content = $script:Tcur.openBtn
            $ctl.btnFinish.Visibility = "Visible"
            $ctl.btnOpen.Visibility = "Visible"
        } else {
            # Failure -> stay on the install step so the log stays visible; mark
            # it red and offer Retry / Back.
            Add-Log ("x " + $sync.err) "err"
            $ctl.bar.Value = 100; $ctl.bar.Foreground = $brush.err
            $ctl.iTitle.Text = $script:Tcur.failTitle; $ctl.iTitle.Foreground = $brush.err
            $ctl.lblStatus.Text = $sync.err; $ctl.lblStatus.Foreground = $brush.err
            $ctl.btnBack.Visibility = "Visible"; $ctl.btnRetry.Visibility = "Visible"
        }
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
    # Reset install-step styling (covers a retry after a failed run), then show it.
    $ctl.bar.Value = 0; $ctl.bar.Foreground = $accentBrush
    $ctl.iTitle.Text = $script:Tcur.installTitle; $ctl.iTitle.Foreground = $textBrush
    $ctl.lblStatus.Text = $script:Tcur.starting; $ctl.lblStatus.Foreground = $mutedBrush
    Show-Step 3

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

# Pre-fill the default gateway instantly (skip under smoke). The slower SSH-banner
# scan is deferred to the Connect step (fired from btnNext), not window load.
if ($env:ECLIP_GUI_SMOKE -ne "1") {
    $script:autoHost = $ctl.txtHost.Text
    try {
        $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).NextHop
        if ($gw -and $gw -ne '0.0.0.0') { $ctl.txtHost.Text = $gw; $script:autoHost = $gw }
    } catch {}
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
