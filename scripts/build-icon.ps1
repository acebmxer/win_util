#Requires -Version 5.1
<#
.SYNOPSIS
    Regenerates assets/win_util.ico and its SHA256 manifest from a source image.

.DESCRIPTION
    Takes a high-resolution PNG (ideally 256x256 or larger) and builds a
    multi-resolution Windows .ico containing 16/24/32/48/64/128/256 variants,
    then writes the SHA256 of the resulting .ico to assets/win_util.ico.sha256.

    The script in win_util.ps1 reads that manifest on every launch and
    re-downloads the .ico when the hash changes, so existing installs pick
    up icon updates automatically once the new files land on main.

.PARAMETER Source
    Path to the source image. Defaults to the PozzaTech 512x512 favicon on
    the maintainer's desktop. Override with -Source <path> for any PNG.

.EXAMPLE
    .\scripts\build-icon.ps1
    .\scripts\build-icon.ps1 -Source 'C:\path\to\new-logo.png'
#>
[CmdletBinding()]
param(
    [string]$Source = "$env:USERPROFILE\Desktop\PozzaTech logo\pozzatech_favicon_512.png"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$repoRoot = Split-Path -Parent $PSScriptRoot
$icoPath  = Join-Path $repoRoot 'assets\win_util.ico'
$shaPath  = Join-Path $repoRoot 'assets\win_util.ico.sha256'
$sizes    = @(16, 24, 32, 48, 64, 128, 256)

if (-not (Test-Path $Source)) {
    throw "Source image not found: $Source"
}

Write-Host "Building $icoPath from $Source"

$img = [System.Drawing.Image]::FromFile($Source)
try {
    $pngBlobs = @{}
    foreach ($s in $sizes) {
        $bmp = [System.Drawing.Bitmap]::new([int]$s, [int]$s)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.DrawImage($img, 0, 0, $s, $s)
        } finally { $g.Dispose() }
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngBlobs[$s] = $ms.ToArray()
        $ms.Dispose()
        $bmp.Dispose()
    }

    $count = $sizes.Count
    $out = New-Object System.IO.MemoryStream
    $bw  = [System.IO.BinaryWriter]::new($out)

    # ICONDIR
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]$count)

    $dataOffset = 6 + (16 * $count)
    foreach ($s in $sizes) {
        $len = $pngBlobs[$s].Length
        $w = if ($s -ge 256) { [byte]0 } else { [byte]$s }
        $h = if ($s -ge 256) { [byte]0 } else { [byte]$s }
        $bw.Write([byte]$w)
        $bw.Write([byte]$h)
        $bw.Write([byte]0)
        $bw.Write([byte]0)
        $bw.Write([uint16]1)
        $bw.Write([uint16]32)
        $bw.Write([uint32]$len)
        $bw.Write([uint32]$dataOffset)
        $dataOffset += $len
    }
    foreach ($s in $sizes) { $bw.Write($pngBlobs[$s]) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($icoPath, $out.ToArray())
    $bw.Dispose()
    $out.Dispose()
} finally { $img.Dispose() }

$hash = (Get-FileHash -Path $icoPath -Algorithm SHA256).Hash.ToLower()
[System.IO.File]::WriteAllText($shaPath, $hash, [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "  .ico  -> $icoPath ($((Get-Item $icoPath).Length) bytes)" -ForegroundColor Green
Write-Host "  hash  -> $shaPath" -ForegroundColor Green
Write-Host "  sha256 = $hash" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Commit assets/win_util.ico and assets/win_util.ico.sha256 to main."
Write-Host "  Existing installs will pick up the new icon on their next launch."
