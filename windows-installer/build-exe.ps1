# build-exe.ps1 - package the EclipVPN installer into one self-contained .exe.
#
# Stages everything the installer needs (scripts + SSH.NET DLL + the per-arch
# static-binary payload + the EclipVPN source tree), zips it, and compiles
# launcher.cs with the framework csc.exe, embedding the zip as a resource. The
# result is a single EclipVPN-Installer.exe that extracts to %TEMP% and launches
# the GUI - no Python/Qt runtime, no 7-Zip, no internet.
#
# Run:  powershell -ExecutionPolicy Bypass -File build-exe.ps1

param([string]$OutExe = "EclipVPN-Installer.exe")

$ErrorActionPreference = "Stop"
$Self = $PSScriptRoot
$Repo = Split-Path $Self -Parent

# csc cannot overwrite the output if a previous build's exe is still open - close it.
$procName = [IO.Path]::GetFileNameWithoutExtension($OutExe)
Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Authoritative source-file list straight from the engine (no drift).
. (Join-Path $Self "eclip-core.ps1")

$stage = Join-Path $env:TEMP ("eclip-stage-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $stage | Out-Null
Write-Host "staging -> $stage" -ForegroundColor Cyan

function Stage-File([string]$rel) {
    $src = Join-Path $Repo ($rel -replace '/', '\')
    if (-not (Test-Path $src)) { throw "missing for bundle: $src" }
    $dst = Join-Path $stage ($rel -replace '/', '\')
    New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
}

# 1) installer scripts + SSH library
# generate the eclipse icon if missing
$ico = Join-Path $Self "eclip.ico"
if (-not (Test-Path $ico)) { & (Join-Path $Self "build-icon.ps1") }

@(
    "windows-installer/eclip-core.ps1",
    "windows-installer/install-eclipvpn.ps1",
    "windows-installer/install-eclipvpn-gui.ps1",
    "windows-installer/lang.ru.txt",
    "windows-installer/eclip.ico",
    "windows-installer/lib/Renci.SshNet.dll",
    "packaging/ship-files"
) | ForEach-Object { Stage-File $_ }

# 2) the per-arch static-binary payload (xray/sing-box/jq/curl/ca-bundle)
$payloadDst = Join-Path $stage "windows-installer\payload"
New-Item -ItemType Directory -Force $payloadDst | Out-Null
Copy-Item -Recurse -Force (Join-Path $Self "payload\*") $payloadDst
$binCount = (Get-ChildItem (Join-Path $payloadDst "bin") -Recurse -File).Count
Write-Host "payload binaries staged: $binCount" -ForegroundColor DarkGray

# 3) EclipVPN source tree (engine ships these; list comes from packaging/ship-files + UI)
$EclipTextFiles | ForEach-Object { Stage-File $_ }
Write-Host "source files staged: $($EclipTextFiles.Count)" -ForegroundColor DarkGray

# 4) zip the staging dir (entries become windows-installer/..., usr/..., etc.)
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = Join-Path $Self "bundle.zip"
if (Test-Path $zip) { [IO.File]::Delete($zip) }
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
Write-Host ("bundle.zip: {0:n1} MB" -f ((Get-Item $zip).Length / 1MB)) -ForegroundColor DarkGray

# 5) compile the self-extracting stub with the framework C# compiler
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path $csc)) { throw "csc.exe (.NET Framework 4.x compiler) not found" }
$out = Join-Path $Self $OutExe
$cs  = Join-Path $Self "launcher.cs"
& $csc /nologo /target:winexe /platform:anycpu "/out:$out" "/resource:$zip,bundle.zip" "/win32icon:$ico" `
    /reference:System.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll /reference:System.Windows.Forms.dll `
    $cs
if ($LASTEXITCODE -ne 0) { throw "csc failed (exit $LASTEXITCODE)" }

# cleanup staging (Directory.Delete, not Remove-Item, to avoid recurse guards)
try { [IO.Directory]::Delete($stage, $true) } catch {}
try { [IO.File]::Delete($zip) } catch {}

Write-Host ""
Write-Host ("BUILT: {0}  ({1:n1} MB)" -f $out, ((Get-Item $out).Length / 1MB)) -ForegroundColor Green
