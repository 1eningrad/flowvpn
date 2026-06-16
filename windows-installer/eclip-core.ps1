# eclip-core.ps1 - shared install engine for EclipVPN (Stage 1 core, reusable).
#
# Dot-sourced by install-eclipvpn.ps1 (headless CLI) and install-eclipvpn-gui.ps1
# (WinForms). Defines the SSH/transfer helpers and Invoke-EclipInstall, which
# runs the whole offline install and reports progress through caller-supplied
# callbacks so the CLI can print and the GUI can update controls.
#
# No top-level code here except function definitions, so it is safe to dot-source.
# Keep this file pure ASCII: PowerShell 5.1 reads a BOM-less script as the ANSI
# codepage and a stray non-ASCII byte desyncs the parser.

# Source files shipped as TEXT (CR stripped). The shell files come from the
# single manifest packaging/ship-files (shared with deploy.sh / install*.sh and
# the CI guard) so this list can never drift; the UI is appended here because it
# ships to a special dest and is intentionally not in the manifest. Relative
# paths; the same path is recreated under / on the router. $PSScriptRoot is
# windows-installer\ (set even when dot-sourced); the repo root - and the
# extracted bundle root at install time - is its parent.
$script:EclipManifest = Join-Path (Split-Path $PSScriptRoot -Parent) "packaging\ship-files"
$script:EclipTextFiles = @(
    (Get-Content -LiteralPath $script:EclipManifest |
        Where-Object { $_ -and ($_ -notmatch '^\s*#') }) +
    "www/eclipvpn/index.html"
)

# Bundled binaries shipped per-arch from payload\bin\<arch>\.
$script:EclipBinaries = @(
    @{ Name="xray";                 Dest="/usr/bin/xray";                       Exec=$true  },
    @{ Name="sing-box";             Dest="/usr/bin/sing-box";                   Exec=$true  },
    @{ Name="jq";                   Dest="/usr/bin/jq";                         Exec=$true  },
    @{ Name="curl";                 Dest="/usr/bin/curl";                       Exec=$true  },
    @{ Name="ca-certificates.crt";  Dest="/etc/ssl/certs/ca-certificates.crt";  Exec=$false }
)

# Default callbacks (overridable). $Log gets (message, level); level is one of
# step|ok|warn|err|info. $Progress gets (label, percent) for long transfers.
$script:EclipLog      = { param($m,$lvl) Write-Host $m }
$script:EclipProgress = { param($label,$pct) }

function _log([string]$m, [string]$lvl="info") { & $script:EclipLog $m $lvl }

function Invoke-SSH([string]$cmd, [switch]$Check) {
    # Each RunCommand opens its own channel/shell: no cwd/env persistence, so
    # every command must be self-contained (absolute paths).
    $r = $script:ssh.RunCommand($cmd)
    $res = [pscustomobject]@{ Code = $r.ExitStatus; Out = $r.Result; Err = $r.Error }
    if ($Check -and $res.Code -ne 0) {
        throw ("remote command failed (exit {0}): {1}`n{2}{3}" -f $res.Code, $cmd, $res.Err, $res.Out)
    }
    return $res
}

# Core file push: base64 the bytes, append in chunks to a temp file, then
# `base64 -d` into place and verify the byte count. base64's alphabet is
# quote-safe, so chunks sit inside single quotes with no escaping. One small
# printf per chunk: OpenWrt's dropbear aborts the connection on an exec request
# bigger than ~10-16KB (measured: 8000 ok, 16000 reset), so no batching. 7500
# is verified reliable over thousands of commands with a matching sha256.
function Push-Bytes([byte[]]$bytes, [string]$dest, [bool]$exec, [string]$label) {
    $b64   = [Convert]::ToBase64String($bytes)
    $tmp   = "/tmp/.eclipup.b64"
    $chunk = 7500
    Invoke-SSH "rm -f '$tmp'" -Check | Out-Null
    $total = [Math]::Ceiling($b64.Length / $chunk); $n = 0
    for ($i = 0; $i -lt $b64.Length; $i += $chunk) {
        $len = [Math]::Min($chunk, $b64.Length - $i)
        Invoke-SSH ("printf '%s' '" + $b64.Substring($i, $len) + "' >> '$tmp'") -Check | Out-Null
        $n++
        if ($total -gt 20 -and ($n % 20 -eq 0 -or $n -eq $total)) { & $script:EclipProgress $label ([int](100 * $n / $total)) }
    }
    $r = Invoke-SSH "base64 -d '$tmp' > '$dest' && rm -f '$tmp' && wc -c < '$dest'" -Check
    $got = 0; [void][int]::TryParse($r.Out.Trim(), [ref]$got)
    if ($got -ne $bytes.Length) { throw "size mismatch for ${dest}: sent $($bytes.Length), got $got" }
    if ($exec) { Invoke-SSH "chmod +x '$dest'" -Check | Out-Null }
}

# Text push: strip CR so busybox ash never sees CRLF (a checkout with
# autocrlf=true silently breaks #!/bin/ash). UTF-8, no BOM (ash chokes on BOM).
function Push-Text([string]$local, [string]$dest) {
    $text  = [IO.File]::ReadAllText($local, [Text.Encoding]::UTF8)
    $text  = $text -replace "`r`n", "`n" -replace "`r", "`n"
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($text)
    Push-Bytes $bytes $dest $false $null
}

# Executable push: stage to .new then rename, so upgrading a running binary
# never hits ETXTBSY (the live process keeps its old inode).
function Push-Exe([string]$local, [string]$dest, [string]$label) {
    Push-Bytes ([IO.File]::ReadAllBytes($local)) "$dest.new" $true $label
    Invoke-SSH "mv '$dest.new' '$dest'" -Check | Out-Null
}

# Wait for the router's SSH port to answer. TCP probe, not ICMP - ping is often
# firewalled while SSH is the port we need open anyway.
function Wait-Router([string]$h, [int]$port, [int]$seconds=25) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $t = New-Object Net.Sockets.TcpClient
            $iar = $t.BeginConnect($h, $port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(2000) -and $t.Connected) { $t.EndConnect($iar); $t.Close(); return $true }
            $t.Close()
        } catch {}
        Start-Sleep -Milliseconds 700
    }
    return $false
}

# The whole offline install. Throws on any fatal error (caller catches and
# reports). $SelfDir = the installer directory (contains lib\ and payload\); the
# EclipVPN source tree is taken from $SrcRoot (defaults to $SelfDir's parent).
function Invoke-EclipInstall {
    param(
        [Parameter(Mandatory=$true)][string]$RouterHost,
        [string]$User = "root",
        [string]$Password,
        [string]$KeyFile,
        [int]   $Port = 22,
        [string]$Arch,
        [switch]$NoStart,
        [switch]$PreflightOnly,
        [Parameter(Mandatory=$true)][string]$SelfDir,
        [string]$SrcRoot,
        [scriptblock]$Log,
        [scriptblock]$Progress
    )
    if ($Log)      { $script:EclipLog = $Log }
    if ($Progress) { $script:EclipProgress = $Progress }
    if (-not $SrcRoot) { $SrcRoot = Split-Path $SelfDir -Parent }
    $DllPath = Join-Path $SelfDir "lib\Renci.SshNet.dll"
    $Payload = Join-Path $SelfDir "payload"

    # --- validate local payload ------------------------------------------
    _log "Validating local payload" "step"
    if (-not (Test-Path $DllPath)) { throw "missing SSH library: $DllPath" }
    foreach ($rel in $script:EclipTextFiles) {
        $p = Join-Path $SrcRoot ($rel -replace '/', '\')
        if (-not (Test-Path $p)) { throw "missing source file: $p" }
    }
    Add-Type -Path $DllPath
    _log ("source files: {0}, SSH.NET loaded" -f $script:EclipTextFiles.Count) "ok"

    # --- wait + connect --------------------------------------------------
    _log "Waiting for ${RouterHost}:$Port" "step"
    if (-not (Wait-Router $RouterHost $Port 25)) { throw "cannot reach ${RouterHost}:$Port within 25s - check the cable/Wi-Fi and that SSH (dropbear) is running." }
    _log "router reachable" "ok"

    _log "Connecting as $User" "step"
    if ($KeyFile) {
        $pk = New-Object Renci.SshNet.PrivateKeyFile((Resolve-Path $KeyFile).Path)
        $authMethod = New-Object Renci.SshNet.PrivateKeyAuthenticationMethod($User, $pk)
    } else {
        $authMethod = New-Object Renci.SshNet.PasswordAuthenticationMethod($User, $Password)
    }
    $ci = New-Object Renci.SshNet.ConnectionInfo($RouterHost, $Port, $User, $authMethod)
    $ci.Timeout = [TimeSpan]::FromSeconds(15)
    $script:ssh = New-Object Renci.SshNet.SshClient($ci)
    try {
        try {
            $script:ssh.Connect()
        } catch {
            $m = $_.Exception.Message
            if     ($m -match "denied")  { throw "authentication failed - wrong password or user '$User'." }
            elseif ($m -match "refused|No connection|unreachable|timed out|host") { throw "cannot reach ${RouterHost}:$Port - is SSH enabled?" }
            else   { throw "connect failed: $m" }
        }
        $Password = $null
        _log "connected" "ok"

        # --- preflight ---------------------------------------------------
        _log "Preflight checks" "step"
        $rel = (Invoke-SSH "cat /etc/openwrt_release 2>/dev/null").Out
        if ($rel -notmatch "DISTRIB_ID") { throw "this does not look like OpenWrt (no /etc/openwrt_release)." }
        ($rel -split "`n" | Where-Object { $_ -match "DISTRIB_DESCRIPTION" }) | ForEach-Object { _log ($_ -replace "DISTRIB_DESCRIPTION=", "firmware: " -replace "'", "") "ok" }

        if (-not $Arch) { $Arch = (Invoke-SSH "uname -m").Out.Trim() }
        $archDir = Join-Path $Payload ("bin\" + $Arch)
        if (-not (Test-Path $archDir)) {
            $have = (Get-ChildItem (Join-Path $Payload 'bin') -Directory -ErrorAction SilentlyContinue).Name -join ', '
            throw "no bundled binaries for arch '$Arch' (this build has: $have)"
        }
        foreach ($b in $script:EclipBinaries) { if (-not (Test-Path (Join-Path $archDir $b.Name))) { throw "payload missing $($b.Name) for $Arch" } }
        _log "arch: $Arch (payload present)" "ok"

        if ((Invoke-SSH "echo aGk= | base64 -d 2>/dev/null").Out.Trim() -ne "hi") { throw "router has no working 'base64 -d' (needed for file delivery)." }
        _log "base64 delivery: ok" "ok"

        if ($PreflightOnly) { _log "Preflight OK (no changes made)" "done"; return $true }

        # --- migrate old flowvpn install (idempotent) --------------------
        _log "Migrating any old flowvpn install" "step"
        $migrate = "if [ -e /usr/bin/flowvpn ] || [ -d /etc/flowvpn ] || [ -e /etc/init.d/flowvpn ]; then`n" +
                   "  /etc/init.d/flowvpn stop 2>/dev/null; /etc/init.d/flowvpn disable 2>/dev/null`n" +
                   "  for p in /proc/[0-9]*; do [ -r `"`$p/cmdline`" ] || continue`n" +
                   "    case `$(tr `"\0`" `" `" < `"`$p/cmdline`") in `"/bin/ash /usr/bin/flowvpn watchdog`"*) kill -9 `"`${p##*/}`" 2>/dev/null ;; esac`n" +
                   "  done`n" +
                   "  nft delete table ip flowvpn 2>/dev/null; nft delete table inet flowvpn 2>/dev/null; nft delete table ip flowvpn_dns 2>/dev/null`n" +
                   "  crontab -l 2>/dev/null | grep -v `"/usr/bin/flowvpn `" | crontab - 2>/dev/null`n" +
                   "  if [ -f /tmp/dnsmasq.d/flowvpn.conf ]; then rm -f /tmp/dnsmasq.d/flowvpn.conf; /etc/init.d/dnsmasq restart 2>/dev/null; fi`n" +
                   "  if [ -d /etc/flowvpn ]; then`n" +
                   "    if [ ! -e /etc/eclipvpn ]; then mv /etc/flowvpn /etc/eclipvpn`n" +
                   "    elif [ -f /etc/flowvpn/config.json ] && ! grep -q '`"subscription_url`": *`"http' /etc/eclipvpn/config.json 2>/dev/null; then cp -a /etc/flowvpn/. /etc/eclipvpn/; rm -rf /etc/flowvpn`n" +
                   "    else rm -rf /etc/flowvpn; fi`n" +
                   "  fi`n" +
                   "  rm -rf /usr/bin/flowvpn /usr/lib/flowvpn /etc/init.d/flowvpn /www/cgi-bin/flowvpn /tmp/flowvpn`n" +
                   "  echo migrated`n" +
                   "fi"
        $mr = (Invoke-SSH $migrate -Check).Out.Trim()
        _log $(if ($mr -eq "migrated") { "old flowvpn install migrated" } else { "nothing to migrate" }) "ok"

        # --- dirs (NOT /etc/eclipvpn - migration owns that) --------------
        _log "Creating directories" "step"
        Invoke-SSH "mkdir -p /usr/lib/eclipvpn /www/eclipvpn /www/flowvpn /www/cgi-bin /tmp/eclipvpn /etc/ssl/certs" -Check | Out-Null

        # --- ship source -------------------------------------------------
        _log ("Shipping EclipVPN source ({0} files)" -f $script:EclipTextFiles.Count) "step"
        foreach ($r in $script:EclipTextFiles) {
            Push-Text (Join-Path $SrcRoot ($r -replace '/', '\')) "/$r"
            _log "/$r" "info"
        }

        # --- ship binaries -----------------------------------------------
        _log "Shipping binaries (offline, no apk)" "step"
        foreach ($b in $script:EclipBinaries) {
            $localBin = Join-Path $archDir $b.Name
            if ($b.Exec) { Push-Exe $localBin $b.Dest $b.Name } else { Push-Bytes ([IO.File]::ReadAllBytes($localBin)) $b.Dest $false $b.Name }
            _log ("{0}  ({1:n0} KB)" -f $b.Dest, ((Get-Item $localBin).Length / 1KB)) "ok"
        }

        # --- tproxy ------------------------------------------------------
        _log "Checking nft tproxy support" "step"
        Invoke-SSH "grep -q nft_tproxy /proc/modules || modprobe nft_tproxy 2>/dev/null" | Out-Null
        if ((Invoke-SSH "grep -q nft_tproxy /proc/modules && echo yes").Out.Trim() -eq "yes") {
            _log "nft_tproxy: available" "ok"
        } else {
            _log "WARNING: nft_tproxy not present - tproxy redirect may fail on this firmware (install kmod-nft-tproxy for this build)." "warn"
        }

        # --- perms + default config --------------------------------------
        _log "Setting permissions + initial config" "step"
        Invoke-SSH "chmod +x /usr/bin/eclipvpn /etc/init.d/eclipvpn /www/cgi-bin/eclipvpn /usr/lib/eclipvpn/*.sh" -Check | Out-Null
        Invoke-SSH "/usr/bin/eclipvpn >/dev/null 2>&1 || true" | Out-Null

        # --- legacy redirect ---------------------------------------------
        $redirect = "<!DOCTYPE html>`n<meta charset=`"utf-8`">`n<meta http-equiv=`"refresh`" content=`"0;url=/eclipvpn/`">`n<title>EclipVPN</title>`n<p>Open <a href=`"/eclipvpn/`">/eclipvpn/</a></p>`n"
        Push-Bytes ((New-Object Text.UTF8Encoding($false)).GetBytes($redirect)) "/www/flowvpn/index.html" $false $null

        # --- autostart + start -------------------------------------------
        _log "Enabling autostart" "step"
        Invoke-SSH "/etc/init.d/eclipvpn enable" -Check | Out-Null
        if (-not $NoStart) {
            _log "Starting EclipVPN" "step"
            Invoke-SSH "/etc/init.d/eclipvpn start" | Out-Null
            Start-Sleep -Seconds 2
            $st = (Invoke-SSH "/usr/bin/eclipvpn status 2>/dev/null | (jq -r '`"running=`" + (.running|tostring) + `" servers=`" + (.servers|length|tostring)' 2>/dev/null || head -c 200)").Out.Trim()
            _log $st "ok"
        }

        _log ("DONE - UI at http://{0}/eclipvpn/" -f $RouterHost) "done"
        return $true
    }
    finally {
        if ($script:ssh -and $script:ssh.IsConnected) { $script:ssh.Disconnect() }
        if ($script:ssh) { $script:ssh.Dispose() }
        $script:ssh = $null
    }
}
