param(
    [string]$InputDir = "png",
    [string]$OutputDir = "src\assets",
    # basenames stored as RGB323 (8-bit) instead of RGB565 (16-bit)
    [string[]]$Sprites8bit = @("player_right_32", "player_skill_32"),
    # Object sprites, in gameplay type order 0..7, packed (RGB323) into one atlas
    # ROM instead of one .mem each. Written to $ObjAtlasFile; not emitted singly.
    [string[]]$ObjAtlas = @("obj_plus1_16", "obj_plus3_16", "obj_plus5_16", "obj_minus3_16", "obj_minus5_16", "obj_time_16", "obj_charge_16", "obj_minustime_16"),
    [string]$ObjAtlasFile = "obj_atlas.mem",
    # Stage backgrounds, in stage order 1..3, packed (RGB565) into one ROM as
    # fixed-size slots so bg_layer can address them as {stage, offset}. Each is
    # stretched to $BgSlotW x $BgSlotH and zero-padded up to $BgSlotDepth.
    [string[]]$BgSlots = @("background", "background2", "background3"),
    [string]$BgSlotFile = "background.mem",
    [int]$BgSlotW = 40,
    [int]$BgSlotH = 25,
    [int]$BgSlotDepth = 1024,
    # Target sprite box size (N x N) is taken from the trailing "_<N>" in the
    # base name (e.g. obj_plus1_16 -> 16, player_right_32 -> 32); any-size source
    # art is scaled to fit (aspect-preserved, transparent pad). This map is an
    # override for bases that have no size suffix.
    [hashtable]$FitSize = @{ },
    # Big-image mode: bases here are STRETCHED to exactly W x H (aspect ratio NOT
    # preserved, no transparent pad). Used for the full-screen background tiles.
    [hashtable]$StretchSize = @{ }
)

# Every background slot is stretched to the slot size; register them up front so
# Load-Sprite treats them as big images rather than N x N sprite boxes.
foreach ($bgBase in $BgSlots) { $StretchSize[$bgBase] = @($BgSlotW, $BgSlotH) }

Add-Type -AssemblyName System.Drawing

$ROOT = Split-Path -Parent $PSScriptRoot

function Resolve-LocalPath {
    param([string]$PathValue)
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }
    return Join-Path $ROOT $PathValue
}

$InputPath = Resolve-LocalPath $InputDir
$OutputPath = Resolve-LocalPath $OutputDir

if (!(Test-Path $InputPath -PathType Container)) {
    throw "Input folder not found: $InputPath"
}

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

$pngFiles = Get-ChildItem -Path $InputPath -Filter "*.png" -File | Sort-Object Name

if ($pngFiles.Count -eq 0) {
    throw "No .png files found in: $InputPath"
}

# Scale a bitmap to fit an N x N box, keeping aspect ratio, centered, with a
# transparent background (32bpp ARGB, high-quality downscale).
function Fit-Bitmap {
    param($src, [int]$n)
    $dst = New-Object System.Drawing.Bitmap($n, $n, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $scale = [Math]::Min($n / $src.Width, $n / $src.Height)
    $w = [int][Math]::Round($src.Width * $scale)
    $h = [int][Math]::Round($src.Height * $scale)
    if ($w -lt 1) { $w = 1 }
    if ($h -lt 1) { $h = 1 }
    $ox = [int](($n - $w) / 2)
    $oy = [int](($n - $h) / 2)
    $g.DrawImage($src, $ox, $oy, $w, $h)
    $g.Dispose()
    return $dst
}

# Stretch a bitmap to exactly W x H, ignoring aspect ratio (accepts distortion).
# Shrinking by a large factor (a photo down to the 40x25 background slot) is done
# by averaging every source pixel that lands in a destination cell -- bicubic
# samples too few points at that ratio and the result sparkles with aliasing.
function Stretch-Bitmap {
    param($src, [int]$w, [int]$h)

    if ($src.Width -ge $w * 2 -and $src.Height -ge $h * 2) {
        $sw = $src.Width
        $sh = $src.Height
        $dst = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)

        $rect = New-Object System.Drawing.Rectangle(0, 0, $sw, $sh)
        $data = $src.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                              [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $stride = $data.Stride
        $bytes = New-Object byte[] ($stride * $sh)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $src.UnlockBits($data)

        for ($y = 0; $y -lt $h; $y++) {
            $y0 = [int]([Math]::Floor($y * $sh / $h))
            $y1 = [int]([Math]::Floor(($y + 1) * $sh / $h))
            if ($y1 -le $y0) { $y1 = $y0 + 1 }

            for ($x = 0; $x -lt $w; $x++) {
                $x0 = [int]([Math]::Floor($x * $sw / $w))
                $x1 = [int]([Math]::Floor(($x + 1) * $sw / $w))
                if ($x1 -le $x0) { $x1 = $x0 + 1 }

                $sr = 0.0; $sg = 0.0; $sb = 0.0; $n = 0
                for ($yy = $y0; $yy -lt $y1; $yy++) {
                    $row = $yy * $stride
                    for ($xx = $x0; $xx -lt $x1; $xx++) {
                        $i = $row + $xx * 4
                        $sb += $bytes[$i]
                        $sg += $bytes[$i + 1]
                        $sr += $bytes[$i + 2]
                        $n++
                    }
                }
                $dst.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255,
                    [int]($sr / $n), [int]($sg / $n), [int]($sb / $n)))
            }
        }
        return $dst
    }

    $dst = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($src, 0, 0, $w, $h)
    $g.Dispose()
    return $dst
}

# Target N x N box for a base: explicit override, else trailing "_<N>", else 0 (none).
function Get-TargetSize {
    param([string]$base)
    if ($FitSize.ContainsKey($base)) { return [int]$FitSize[$base] }
    if ($base -match '_(\d+)$') { return [int]$Matches[1] }
    return 0
}

# Load a sprite bitmap for the given base: stretch to W x H if listed in
# $StretchSize, else fit (aspect-preserved) to its N x N target box if any.
function Load-Sprite {
    param([string]$path, [string]$base)
    $bmp = [System.Drawing.Bitmap]::new($path)
    if ($StretchSize.ContainsKey($base)) {
        $wh = $StretchSize[$base]
        $w = [int]$wh[0]; $h = [int]$wh[1]
        if ($bmp.Width -ne $w -or $bmp.Height -ne $h) {
            $stretched = Stretch-Bitmap $bmp $w $h
            $bmp.Dispose()
            return $stretched
        }
        return $bmp
    }
    $n = Get-TargetSize $base
    if ($n -gt 0 -and ($bmp.Width -ne $n -or $bmp.Height -ne $n)) {
        $fitted = Fit-Bitmap $bmp $n
        $bmp.Dispose()
        return $fitted
    }
    return $bmp
}

# Write one bitmap's pixels (row-major) to an open StreamWriter.
function Write-Pixels {
    param($bmp, $writer, [bool]$use8bit)
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        for ($x = 0; $x -lt $bmp.Width; $x++) {
            $color = $bmp.GetPixel($x, $y)
            if ($use8bit) {
                # RGB323: transparency comes ONLY from PNG alpha; an opaque pixel
                # never emits the 0x00 sentinel (near-black is bumped to 0x01).
                if ([int]$color.A -eq 0) {
                    $writer.WriteLine("00")
                }
                else {
                    $r = [int]$color.R; $g = [int]$color.G; $b = [int]$color.B
                    $val8 = (($r -shr 5) -shl 5) -bor (($g -shr 6) -shl 3) -bor ($b -shr 5)
                    if ($val8 -eq 0) { $val8 = 1 }
                    $writer.WriteLine("{0:X2}" -f $val8)
                }
            }
            else {
                # RGB565 has no alpha channel: transparency comes from PNG alpha
                # (A==0 -> 0x0000). Only the opaque background layer uses this format.
                $r = [int]$color.R; $g = [int]$color.G; $b = [int]$color.B
                if ([int]$color.A -eq 0) { $r = 0; $g = 0; $b = 0 }
                $val16 = (($r -shr 3) -shl 11) -bor (($g -shr 2) -shl 5) -bor ($b -shr 3)
                $writer.WriteLine("{0:X4}" -f $val16)
            }
        }
    }
}

# Classify: "<base>.<N>" is frame N of animation group <base>; else standalone.
$groups = @{}
$singles = @()
foreach ($png in $pngFiles) {
    if ($png.BaseName -match '^(.+)\.(\d+)$') {
        $base = $Matches[1]
        $idx = [int]$Matches[2]
        if (-not $groups.ContainsKey($base)) { $groups[$base] = @() }
        $groups[$base] += [pscustomobject]@{ Idx = $idx; File = $png }
    }
    else {
        $singles += $png
    }
}

$convertedCount = 0

foreach ($png in $singles) {
    $base = $png.BaseName
    if ($ObjAtlas -contains $base) { continue }   # packed into the atlas below, not emitted singly
    if ($BgSlots -contains $base) { continue }    # packed into the background ROM below
    $use8bit = $Sprites8bit -contains $base
    if ($use8bit) { $fmt = "RGB323" } else { $fmt = "RGB565" }
    $memPath = Join-Path $OutputPath ($base + ".mem")
    $bmp = Load-Sprite $png.FullName $base
    $w = $bmp.Width; $h = $bmp.Height
    $writer = [System.IO.StreamWriter]::new($memPath, $false, [System.Text.Encoding]::ASCII)
    try {
        Write-Pixels $bmp $writer $use8bit
    }
    finally {
        $writer.Dispose()
        $bmp.Dispose()
    }
    $convertedCount++
    Write-Host "$($png.Name) -> $base.mem ($w x $h, $fmt)"
}

foreach ($base in ($groups.Keys | Sort-Object)) {
    $frames = $groups[$base] | Sort-Object Idx
    $use8bit = $Sprites8bit -contains $base
    if ($use8bit) { $fmt = "RGB323" } else { $fmt = "RGB565" }
    $memPath = Join-Path $OutputPath ($base + ".mem")
    $writer = [System.IO.StreamWriter]::new($memPath, $false, [System.Text.Encoding]::ASCII)
    try {
        foreach ($fr in $frames) {
            $bmp = Load-Sprite $fr.File.FullName $base
            try { Write-Pixels $bmp $writer $use8bit }
            finally { $bmp.Dispose() }
        }
    }
    finally {
        $writer.Dispose()
    }
    $convertedCount++
    Write-Host "$base.{$(($frames | ForEach-Object { $_.Idx }) -join ',')} -> $base.mem ($($frames.Count) frames, $fmt)"
}

# Object atlas: concatenate the object sprites (RGB323) in type order 0..6 into a
# single .mem so obj_layer can read them from one ROM addressed by {type, y, x}.
if ($ObjAtlas.Count -gt 0) {
    $atlasPath = Join-Path $OutputPath $ObjAtlasFile
    $writer = [System.IO.StreamWriter]::new($atlasPath, $false, [System.Text.Encoding]::ASCII)
    try {
        foreach ($base in $ObjAtlas) {
            $png = $singles | Where-Object { $_.BaseName -eq $base } | Select-Object -First 1
            if (-not $png) { throw "Atlas member PNG not found in ${InputPath}: $base.png" }
            $bmp = Load-Sprite $png.FullName $base
            try { Write-Pixels $bmp $writer $true } finally { $bmp.Dispose() }
        }
    }
    finally {
        $writer.Dispose()
    }
    $convertedCount++
    Write-Host "$($ObjAtlas -join ',') -> $ObjAtlasFile ($($ObjAtlas.Count) sprites, RGB323 atlas)"
}

# Stage backgrounds: concatenate each stage image (RGB565) into one .mem as
# fixed-size slots, so bg_layer reads them from one ROM addressed by
# {stage, src_y*W + src_x}. Each slot is padded to $BgSlotDepth entries.
if ($BgSlots.Count -gt 0) {
    $bgPath = Join-Path $OutputPath $BgSlotFile
    $used = $BgSlotW * $BgSlotH
    if ($used -gt $BgSlotDepth) {
        throw "Background slot $BgSlotW x $BgSlotH ($used) exceeds slot depth $BgSlotDepth"
    }
    $writer = [System.IO.StreamWriter]::new($bgPath, $false, [System.Text.Encoding]::ASCII)
    try {
        foreach ($base in $BgSlots) {
            $png = $singles | Where-Object { $_.BaseName -eq $base } | Select-Object -First 1
            if (-not $png) { throw "Background slot PNG not found in ${InputPath}: $base.png" }
            $bmp = Load-Sprite $png.FullName $base
            try { Write-Pixels $bmp $writer $false } finally { $bmp.Dispose() }
            for ($pad = $used; $pad -lt $BgSlotDepth; $pad++) { $writer.WriteLine("0000") }
        }
    }
    finally {
        $writer.Dispose()
    }
    $convertedCount++
    Write-Host "$($BgSlots -join ',') -> $BgSlotFile ($($BgSlots.Count) slots, ${BgSlotW}x${BgSlotH} RGB565, slot depth $BgSlotDepth)"
}

Write-Host "Converted $convertedCount item(s)."
Write-Host "Input dir : $InputPath"
Write-Host "Output dir: $OutputPath"
