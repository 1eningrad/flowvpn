# build-icon.ps1 - generate eclip.ico, the EclipVPN eclipse mark.
#
# Draws a violet disc with a crescent carved out (an eclipse) via System.Drawing,
# supersampled then downscaled to every icon size, packed into a single
# multi-resolution .ico (PNG-compressed frames, Vista+). One asset, used by the
# GUI header, the window icon, and the .exe file icon. No external design tools.
#
# Run:  powershell -ExecutionPolicy Bypass -File build-icon.ps1

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$Self = $PSScriptRoot
$out  = Join-Path $Self "eclip.ico"

# Render the eclipse at a high resolution so anti-aliasing (including the carved
# crescent, which needs SourceCopy and thus no per-pixel AA) comes out clean
# after downscaling.
function New-Master([int]$S) {
    $bmp = New-Object Drawing.Bitmap($S, $S, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([Drawing.Color]::Transparent)
    $pad = [double]$S * 0.07
    $d   = [double]$S - 2 * $pad
    # main violet disc
    $br = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 124, 108, 247))
    $g.FillEllipse($br, $pad, $pad, $d, $d)
    # carve the crescent: punch a transparent disc offset up-right
    $g.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
    $clear = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(0, 0, 0, 0))
    $cd = $d * 0.82
    $cx = $pad + $d * 0.30
    $cy = $pad - $d * 0.10
    $g.FillEllipse($clear, $cx, $cy, $cd, $cd)
    $g.Dispose(); $br.Dispose(); $clear.Dispose()
    return $bmp
}

function Resize-Bmp($src, [int]$sz) {
    $b = New-Object Drawing.Bitmap($sz, $sz, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($b)
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([Drawing.Color]::Transparent)
    $g.DrawImage($src, 0, 0, $sz, $sz)
    $g.Dispose()
    return $b
}

$master = New-Master 512
$sizes  = 16, 24, 32, 48, 64, 128, 256
$frames = @()
foreach ($s in $sizes) {
    $bm = Resize-Bmp $master $s
    $ms = New-Object IO.MemoryStream
    $bm.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $frames += , @{ size = $s; bytes = $ms.ToArray() }
    $ms.Dispose(); $bm.Dispose()
}
$master.Dispose()

# assemble the .ico (ICONDIR + entries + PNG blobs)
$fs = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter($fs)
$bw.Write([uint16]0)              # reserved
$bw.Write([uint16]1)              # type = icon
$bw.Write([uint16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
    $wh = if ($f.size -ge 256) { [byte]0 } else { [byte]$f.size }
    $bw.Write([byte]$wh)          # width  (0 = 256)
    $bw.Write([byte]$wh)          # height
    $bw.Write([byte]0)            # palette count
    $bw.Write([byte]0)            # reserved
    $bw.Write([uint16]1)          # color planes
    $bw.Write([uint16]32)         # bits per pixel
    $bw.Write([uint32]$f.bytes.Length)
    $bw.Write([uint32]$offset)
    $offset += $f.bytes.Length
}
foreach ($f in $frames) { $bw.Write($f.bytes) }
$bw.Flush()
[IO.File]::WriteAllBytes($out, $fs.ToArray())
$bw.Dispose(); $fs.Dispose()

Write-Host ("eclip.ico written: {0:n0} bytes, sizes: {1}" -f (Get-Item $out).Length, ($sizes -join ',')) -ForegroundColor Green
