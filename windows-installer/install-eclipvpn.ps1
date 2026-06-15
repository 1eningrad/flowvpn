# install-eclipvpn.ps1 - EclipVPN offline installer, headless CLI (Stage 1).
#
# Thin wrapper over eclip-core.ps1. Installs EclipVPN onto a fresh OpenWrt router
# entirely offline (bundled static binaries, no apk/GitHub), over SSH. See
# eclip-core.ps1 for the engine and the install-from-mac.sh lineage.
#
# Usage:
#   .\install-eclipvpn.ps1 -RouterHost 192.168.1.1 -Password 'secret'
#   .\install-eclipvpn.ps1 -RouterHost 192.168.10.1 -KeyFile ~\.ssh\id_rsa   # dev
#   add -NoStart to ship + enable without starting the service.
#
# Keep this file pure ASCII (PS 5.1 reads a BOM-less script as ANSI).

[CmdletBinding()]
param(
    [string]$RouterHost = "192.168.1.1",
    [string]$User       = "root",
    [string]$Password,
    [string]$KeyFile,
    [int]   $Port       = 22,
    [string]$Arch,
    [switch]$NoStart,
    [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "eclip-core.ps1")

$logger = {
    param($m,$lvl)
    switch ($lvl) {
        "step" { Write-Host "[*] $m" -ForegroundColor Cyan }
        "ok"   { Write-Host "    $m" -ForegroundColor DarkGray }
        "warn" { Write-Host "    $m" -ForegroundColor Yellow }
        "err"  { Write-Host "ERROR: $m" -ForegroundColor Red }
        "done" { Write-Host ""; Write-Host "===== $m =====" -ForegroundColor Green }
        default { Write-Host "    $m" -ForegroundColor DarkGray }
    }
}
$prog = {
    param($label,$pct)
    Write-Host ("`r      {0}: {1,3}%   " -f $label, $pct) -NoNewline -ForegroundColor DarkGray
    if ($pct -ge 100) { Write-Host "" }
}

try {
    if (-not $KeyFile -and -not $Password) {
        $sec = Read-Host "Router password for $User@$RouterHost" -AsSecureString
        $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    }
    Invoke-EclipInstall -RouterHost $RouterHost -User $User -Password $Password -KeyFile $KeyFile `
        -Port $Port -Arch $Arch -NoStart:$NoStart -PreflightOnly:$PreflightOnly -SelfDir $PSScriptRoot -Log $logger -Progress $prog | Out-Null
}
catch {
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
