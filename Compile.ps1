#Requires -Version 5.1
<#
.SYNOPSIS  Bundles all source files into a single dist/win_util.ps1 for remote scriptblock deployment.
.EXAMPLE   .\Compile.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ROOT = $PSScriptRoot
$OUT  = Join-Path $ROOT "dist\win_util.ps1"

New-Item -ItemType Directory -Force (Split-Path $OUT) | Out-Null

$sb = [System.Text.StringBuilder]::new()

function Write-Line { param([string]$L) [void]$sb.AppendLine($L) }

# Write a file's lines, honouring COMPILE:SKIP markers but NOT the INSERT:LIBS marker
# (that is only meaningful when processing win_util.ps1 in two passes).
function Write-FileStripped {
    param([string]$Path)
    $skipping = $false
    foreach ($line in (Get-Content $Path)) {
        if ($line -match '#\s*COMPILE:SKIP:BEGIN')  { $skipping = $true;  continue }
        if ($line -match '#\s*COMPILE:SKIP:END')    { $skipping = $false; continue }
        if ($skipping)                              { continue }
        if ($line -match '#\s*COMPILE:SKIP\b')      { continue }
        Write-Line $line
    }
}

function Write-Lib {
    param([string]$RelPath, [string]$Label)
    Write-Line ""
    Write-Line "#region --- $Label ---"
    Write-FileStripped (Join-Path $ROOT $RelPath)
    Write-Line "#endregion"
}

# ── 1. Preamble: win_util.ps1 up to (but not including) COMPILE:INSERT:LIBS ──
foreach ($line in (Get-Content (Join-Path $ROOT "win_util.ps1"))) {
    if ($line -match '#\s*COMPILE:INSERT:LIBS') { break }
    if ($line -match '#\s*COMPILE:SKIP\b')      { continue }
    Write-Line $line
}

# ── 2. Lib files inlined in dependency order ──
Write-Lib "lib\logging.ps1"        "logging"
Write-Lib "lib\utilities.ps1"      "utilities"
Write-Lib "lib\installers.ps1"     "installers"
Write-Lib "lib\utilities-list.ps1" "utilities-list"
Write-Lib "lib\menu.ps1"           "menu"

# ── 3. Body: rest of win_util.ps1 with COMPILE:SKIP blocks removed ──
Write-Line ""
Write-Line "#region --- main ---"

$capturing = $false
$skipping  = $false
foreach ($line in (Get-Content (Join-Path $ROOT "win_util.ps1"))) {
    if (-not $capturing) {
        if ($line -match '#\s*COMPILE:INSERT:LIBS') { $capturing = $true }
        continue
    }
    if ($line -match '#\s*COMPILE:SKIP:BEGIN') { $skipping = $true;  continue }
    if ($line -match '#\s*COMPILE:SKIP:END')   { $skipping = $false; continue }
    if ($skipping)                             { continue }
    if ($line -match '#\s*COMPILE:SKIP\b')     { continue }
    Write-Line $line
}

Write-Line "#endregion"

# ── Write output ──
[System.IO.File]::WriteAllText($OUT, $sb.ToString(), [System.Text.Encoding]::UTF8)

Write-Host ""
Write-Host "  Compiled -> $OUT" -ForegroundColor Green
Write-Host ""
Write-Host "  & ([scriptblock]::Create((irm '<raw-url>/dist/win_util.ps1')))" -ForegroundColor DarkGray
Write-Host ""
