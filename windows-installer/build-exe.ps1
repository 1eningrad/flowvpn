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

# Stage TRACKED files from `git archive HEAD` (committed bytes) into $stage,
# preserving their repo-relative paths. Immune to Yandex.Disk mid-sync corruption
# - git reads its immutable object store, not the working tree - the same
# hardening deploy.sh/install-from-mac.sh got. Throws if a path is not committed.
function Stage-FromGit([string[]]$rels) {
    $tmpzip = Join-Path $env:TEMP ("eclip-src-" + [guid]::NewGuid().ToString("N") + ".zip")
    & git -C $Repo archive --format=zip -o $tmpzip HEAD -- $rels
    if ($LASTEXITCODE -ne 0) { throw "git archive failed (exit $LASTEXITCODE) - a tracked path not committed at HEAD?" }
    Expand-Archive -LiteralPath $tmpzip -DestinationPath $stage -Force
    [IO.File]::Delete($tmpzip)
}

# 1) the eclipse icon (untracked / gitignored - generate if missing)
$ico = Join-Path $Self "eclip.ico"
if (-not (Test-Path $ico)) { & (Join-Path $Self "build-icon.ps1") }

# 2) TRACKED source -> staged from committed HEAD (git archive), NOT the working
# tree. This repo lives in a Yandex.Disk sync folder; copying a mid-sync
# (truncated) file into the bundle would ship broken code INSIDE the .exe - the
# exact hazard deploy.sh/install-from-mac.sh were hardened against. The shell
# source list comes from the engine ($EclipTextFiles = packaging/ship-files + UI)
# so it never drifts; the installer .ps1 scripts + manifest are added explicitly.
$tracked = @(
    "windows-installer/eclip-core.ps1",
    "windows-installer/install-eclipvpn.ps1",
    "windows-installer/install-eclipvpn-gui.ps1",
    "windows-installer/lang.ru.txt",
    "packaging/ship-files"
) + $EclipTextFiles

if ($env:ALLOW_DIRTY -eq "1") {
    Write-Host "ALLOW_DIRTY=1 -> staging tracked source from the WORKING TREE (includes uncommitted edits; NOT immune to mid-sync)" -ForegroundColor Yellow
    $tracked | ForEach-Object { Stage-File $_ }
} else {
    $dirty = & git -C $Repo status --porcelain --untracked-files=no -- $tracked
    if ($dirty) {
        Write-Host "WARNING: uncommitted changes in tracked source - the .exe is built from committed HEAD, so those edits are NOT in it. Commit them, or set ALLOW_DIRTY=1 to build the working tree." -ForegroundColor Yellow
    }
    Stage-FromGit $tracked
}
Write-Host ("source files staged: {0} (from {1})" -f $tracked.Count, $(if ($env:ALLOW_DIRTY -eq "1") {"working tree"} else {"committed HEAD"})) -ForegroundColor DarkGray

# 3) untracked / gitignored artifacts -> from the working tree (not in git):
#    the eclipse icon and the SSH.NET DLL.
"windows-installer/eclip.ico", "windows-installer/lib/Renci.SshNet.dll" | ForEach-Object { Stage-File $_ }

# 4) the per-arch static-binary payload (xray/sing-box/jq/curl/ca-bundle) - also
# gitignored, so staged from the working tree.
$payloadDst = Join-Path $stage "windows-installer\payload"
New-Item -ItemType Directory -Force $payloadDst | Out-Null
Copy-Item -Recurse -Force (Join-Path $Self "payload\*") $payloadDst
$binCount = (Get-ChildItem (Join-Path $payloadDst "bin") -Recurse -File).Count
Write-Host "payload binaries staged: $binCount" -ForegroundColor DarkGray

# build stamp baked into the bundle root so the installed router records which
# committed build this .exe carries (eclip-core writes it to /etc/eclipvpn/build).
# ECLIPVPN_VERSION is a constant; this is the real per-build id.
$bsha = (& git -C $Repo rev-parse --short HEAD).Trim()
$bdate = (& git -C $Repo show -s --format=%cd --date=short HEAD).Trim()
if (& git -C $Repo status --porcelain --untracked-files=no -- usr www etc) { $bsha = "$bsha+dirty" }
$bstamp = "$bsha $bdate via=installer.exe"
[IO.File]::WriteAllText((Join-Path $stage "build.txt"), $bstamp, (New-Object Text.UTF8Encoding($false)))
Write-Host "build stamp: $bstamp" -ForegroundColor DarkGray

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
