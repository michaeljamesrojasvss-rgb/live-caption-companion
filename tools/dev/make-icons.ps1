# make-icons.ps1 - draws the apps' icons into app\icons\*.ico (run by hand when an icon should change).
# Each icon = a rounded tile in the app's own colour with a white symbol from Windows' own
# "Segoe MDL2 Assets" font, at 16..256 px (PNG-compressed .ico, Windows Vista and later).
#   powershell -ExecutionPolicy Bypass -File tools\dev\make-icons.ps1 [-Preview out.png]
param([string]$Preview = "")
Add-Type -AssemblyName System.Drawing

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$out = Join-Path $root "app\icons"
New-Item -ItemType Directory -Force $out | Out-Null

# name, tile colour, glyph (Segoe MDL2 Assets code point)
$icons = @(
    @{ Name = "companion"; Color = "#2563EB"; Glyph = 0xE7F0 },   # ClosedCaption - the Companion (captions)
    @{ Name = "tasks";     Color = "#16A34A"; Glyph = 0xE73E },   # CheckMark     - Tasks
    @{ Name = "pool";      Color = "#7C3AED"; Glyph = 0xE8BD },   # Message       - Copilot pool
    @{ Name = "updater";   Color = "#475569"; Glyph = 0xE895 }    # Sync          - updater
)
$sizes = 16, 20, 24, 32, 40, 48, 64, 256

# The signature on every app's icon: a cyan rounded-square ring around the tile
$SIGNATURE = "#22D3EE"

function Round-Rect([single]$x, [single]$y, [single]$w, [single]$r) {
    $d = 2 * $r
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $w - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $w - $d, $d, $d, 90, 90); $p.CloseFigure()
    return $p
}

function Draw-Tile([int]$s, [string]$hex, [int]$glyph) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = "AntiAlias"; $g.TextRenderingHint = "AntiAliasGridFit"; $g.Clear([System.Drawing.Color]::Transparent)
    $cyan = [System.Drawing.ColorTranslator]::FromHtml($SIGNATURE)
    # the ring: thick enough to see at 16 px, with a see-through gap before the tile from 32 px up
    $ring = [single][Math]::Max(1.5, $s * $(if ($s -ge 64) { 0.05 } else { 0.07 }))
    $gap = if ($s -ge 32) { [single]($s * 0.045) } else { [single]0 }
    $half = $ring / 2
    $outer = Round-Rect $half $half ($s - $ring) ([single]([Math]::Max(3, $s * 0.26)))
    if ($s -ge 48) {                                   # a soft cyan glow outside the ring on big sizes
        foreach ($k in 3, 2, 1) {
            $glow = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(28, $cyan)), ([single]($ring + $k * $s * 0.012))
            $g.DrawPath($glow, $outer)
        }
    }
    $g.DrawPath((New-Object System.Drawing.Pen $cyan, $ring), $outer)
    # the app's tile inside the ring
    $in = $ring + $gap
    $tile = Round-Rect $in $in ($s - 2 * $in) ([single]([Math]::Max(2, ($s - 2 * $in) * 0.2)))
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($hex))), $tile)
    $font = New-Object System.Drawing.Font "Segoe MDL2 Assets", ([single](($s - 2 * $in) * $(if ($s -le 24) { 0.72 } else { 0.58 }))), ([System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = "Center"; $fmt.LineAlignment = "Center"
    $rect = New-Object System.Drawing.RectangleF $in, ([single]($in + ($s - 2 * $in) * 0.03)), ($s - 2 * $in), ($s - 2 * $in)
    $g.DrawString([string][char]$glyph, $font, [System.Drawing.Brushes]::White, $rect, $fmt)
    $g.Dispose(); return $bmp
}

$sheet = $null
if ($Preview) { $sw = [int](($sizes | Measure-Object -Sum).Sum + 8 * $sizes.Count + 8); $sh = [int](264 * $icons.Count); $sheet = New-Object System.Drawing.Bitmap -ArgumentList $sw, $sh; $sg = [System.Drawing.Graphics]::FromImage($sheet); $sg.Clear([System.Drawing.Color]::FromArgb(17, 21, 29)) }

$row = 0
foreach ($ic in $icons) {
    $pngs = @()
    $x = 4
    foreach ($s in $sizes) {
        $bmp = Draw-Tile $s $ic.Color $ic.Glyph
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngs += , $ms.ToArray()
        if ($sheet) { $sg.DrawImage($bmp, $x, 4 + 264 * $row); $x += $s + 8 }
        $bmp.Dispose()
    }
    # .ico = ICONDIR + one ICONDIRENTRY per size + the PNG data
    $f = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $f
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]; $len = $pngs[$i].Length
        $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s }))); $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
        $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$len); $bw.Write([uint32]$offset); $offset += $len
    }
    foreach ($b in $pngs) { $bw.Write($b) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes((Join-Path $out ($ic.Name + ".ico")), $f.ToArray())
    $row++
}
if ($sheet) { $sheet.Save($Preview, [System.Drawing.Imaging.ImageFormat]::Png); $sg.Dispose(); $sheet.Dispose() }
"made: " + (($icons | ForEach-Object { $_.Name + ".ico" }) -join ", ")
