<#
.SYNOPSIS
    Windows Utilities Installer - interactive multi-select TUI for installing,
    uninstalling, and updating common Windows software via winget.

.EXAMPLE
    .\win_util.ps1                             # Interactive menu
    .\win_util.ps1 --install   "Google Chrome" # Install by name
    .\win_util.ps1 --uninstall "7-Zip"
    .\win_util.ps1 --update    "VLC Media Player"
    .\win_util.ps1 --update-all
    .\win_util.ps1 --list
    .\win_util.ps1 --check     "Java Runtime Environment"
#>

param(
    [string] $Install     = "",
    [string] $Uninstall   = "",
    [string] $Update      = "",
    [switch] $UpdateAll,
    [switch] $List,
    [string] $Check       = "",
    [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


#region --- logging ---
# Logging module for win_util

$script:LogFile = $null

function Initialize-Logging {
    $logDir = if ($PSScriptRoot) {
        Join-Path $PSScriptRoot "..\logs"   # dev: lib\ -> win_util\logs\  |  dist: dist\ -> win_util\logs\
    } else {
        Join-Path $env:TEMP "win_util_logs" # scriptblock invocation: $PSScriptRoot is empty
    }
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Force $logDir | Out-Null
    }
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:LogFile = Join-Path $logDir "win_util_$timestamp.log"
    Write-Log "Session started" "INFO"
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue
    }
}

function Write-LogInfo  { param([string]$Message) Write-Log $Message "INFO" }
function Write-LogWarn  { param([string]$Message) Write-Log $Message "WARN" }
function Write-LogError { param([string]$Message) Write-Log $Message "ERROR" }

function Write-LogSummary {
    param(
        [int]$Succeeded,
        [int]$Failed,
        [string[]]$FailedNames = @()
    )
    Write-Log "--- Session Summary ---" "INFO"
    Write-Log "Succeeded: $Succeeded" "INFO"
    Write-Log "Failed:    $Failed" "INFO"
    if ($FailedNames.Count -gt 0) {
        Write-Log "Failed items: $($FailedNames -join ', ')" "ERROR"
    }
    Write-Log "Log file: $script:LogFile" "INFO"
}
#endregion

#region --- utilities ---
# Shared helper functions for win_util

function Test-WingetAvailable {
    return ($null -ne (Get-Command winget -ErrorAction SilentlyContinue))
}

function Test-WingetInstalled {
    param([string]$Id)
    $output = winget list --id $Id --exact --accept-source-agreements 2>&1 | Out-String
    return $output -match [regex]::Escape($Id)
}

function Get-WingetVersion {
    param([string]$Id)
    $lines = winget list --id $Id --exact --accept-source-agreements 2>&1
    foreach ($line in $lines) {
        if ($line -match [regex]::Escape($Id)) {
            # winget list columns: Name | Id | Version | Available | Source
            $parts = $line -split '\s{2,}'
            if ($parts.Count -ge 3) { return $parts[2].Trim() }
        }
    }
    return $null
}

function Invoke-WingetInstall {
    param([string]$Id)
    Write-LogInfo "Installing $Id via winget"
    winget install -e --id $Id --silent --accept-source-agreements --accept-package-agreements
    return $LASTEXITCODE
}

function Invoke-WingetUninstall {
    param([string]$Id)
    Write-LogInfo "Uninstalling $Id via winget"
    winget uninstall --id $Id --silent --accept-source-agreements
    return $LASTEXITCODE
}

function Invoke-WingetUpdate {
    param([string]$Id)
    Write-LogInfo "Updating $Id via winget"
    winget upgrade --id $Id --silent --accept-source-agreements --accept-package-agreements
    return $LASTEXITCODE
}
#endregion

#region --- installers ---
# Utility registry — defines Register-Utility and standard winget wrappers

$script:Registry = [System.Collections.Generic.List[hashtable]]::new()

function Register-Utility {
    param([hashtable]$Definition)
    $script:Registry.Add($Definition)
}

function Get-AllUtilities {
    return $script:Registry
}

function Get-UtilitiesByCategory {
    $grouped = [ordered]@{}
    foreach ($u in $script:Registry) {
        $cat = $u.Category
        if (-not $grouped.Contains($cat)) { $grouped[$cat] = [System.Collections.Generic.List[hashtable]]::new() }
        $grouped[$cat].Add($u)
    }
    return $grouped
}

function Get-UtilityFunctions {
    param([hashtable]$Utility)
    $id       = $Utility.Id
    $safeName = $Utility.Name -replace '[^A-Za-z0-9]', ''

    $customInstall    = Get-Command "Install-$safeName"      -ErrorAction SilentlyContinue
    $customUninstall  = Get-Command "Uninstall-$safeName"    -ErrorAction SilentlyContinue
    $customUpdate     = Get-Command "Update-$safeName"       -ErrorAction SilentlyContinue
    $customTest       = Get-Command "Test-$safeName"         -ErrorAction SilentlyContinue
    $customGetVersion = Get-Command "Get-${safeName}Version" -ErrorAction SilentlyContinue

    # GetNewClosure() does not let the scriptblock see script-scope functions (Test-WingetInstalled,
    # Invoke-Winget*, etc.) when invoked from another function. Bake the id into the source via
    # [scriptblock]::Create so command lookup happens in the caller's session state at invoke time.
    $idLit = "'" + ($id -replace "'", "''") + "'"

    return @{
        Install    = if ($customInstall)    { $customInstall }    else { [scriptblock]::Create("Invoke-WingetInstall   $idLit") }
        Uninstall  = if ($customUninstall)  { $customUninstall }  else { [scriptblock]::Create("Invoke-WingetUninstall $idLit") }
        Update     = if ($customUpdate)     { $customUpdate }     else { [scriptblock]::Create("Invoke-WingetUpdate    $idLit") }
        Test       = if ($customTest)       { $customTest }       else { [scriptblock]::Create("Test-WingetInstalled   $idLit") }
        GetVersion = if ($customGetVersion) { $customGetVersion } else { [scriptblock]::Create("Get-WingetVersion      $idLit") }
    }
}

# Load utility registrations
#endregion

#region --- utilities-list ---
# All registered utilities — add a Register-Utility line here to add a new tool.
# Custom install/uninstall/update/test logic: define Install-SafeName, etc. anywhere in the loaded files.

Register-Utility @{ Name = "Google Chrome";            Id = "Google.Chrome";                   Category = "Browsers" }

Register-Utility @{ Name = "7-Zip";                    Id = "7zip.7zip";                       Category = "Tools"    }

Register-Utility @{ Name = "VLC Media Player";         Id = "VideoLAN.VLC";                    Category = "Media"    }

Register-Utility @{ Name = "Java Runtime Environment"; Id = "Oracle.JavaRuntimeEnvironment";   Category = "Runtimes" }

Register-Utility @{ Name = "VCRedist 2015+ x64";       Id = "Microsoft.VCRedist.2015+.x64";   Category = "System"   }
#endregion

#region --- menu ---
# Interactive TUI menu for win_util
# Two-panel layout: categories (left) | items (right)
# Navigation: arrow keys, Space=toggle, Enter=apply, Q=quit

#region --- ANSI Colors & Box Drawing ---

$ESC  = [char]27
$R    = "${ESC}[0m"
$BOLD = "${ESC}[1m"

$FC   = "${ESC}[36m"      # cyan        - borders/structure
$FY   = "${ESC}[33m"      # yellow      - cursor/counts
$FG   = "${ESC}[32m"      # green       - selected
$FM   = "${ESC}[35m"      # magenta     - version tags
$FRed = "${ESC}[31m"      # red         - errors
$FW   = "${ESC}[97m"      # bright white - titles
$FDim = "${ESC}[2;37m"    # dim white   - inactive
$BH   = "${ESC}[48;5;236m" # row highlight bg

# Box-drawing chars as variables (safe: no raw non-ASCII bytes in strings)
$cTL = [char]0x2554  # top-left corner
$cTR = [char]0x2557  # top-right corner
$cBL = [char]0x255A  # bottom-left corner
$cBR = [char]0x255D  # bottom-right corner
$cHZ = [char]0x2550  # horizontal double
$cVT = [char]0x2551  # vertical double
$cML = [char]0x2560  # mid-left T
$cMR = [char]0x2563  # mid-right T
$cTT = [char]0x2566  # top T
$cBT = [char]0x2569  # bottom T
$cXX = [char]0x256C  # cross/intersection

function cH { param([int]$N) return ([string]$cHZ) * $N }  # repeat horizontal line

#endregion

#region --- Layout Constants ---

$CAT_WIDTH   = 18   # left panel inner width (excluding borders)
$MIN_COLS    = 72
$MIN_ROWS    = 20
$HEADER_ROWS = 6
$FOOTER_ROWS = 4

#endregion

#region --- State ---

$script:MenuState = @{
    Categories    = @()
    ByCategory    = @{}
    CatIndex      = 0
    ItemIndex     = 0
    Focus         = 'items'
    Selected      = @{}
    ScrollOffset  = 0
    StatusMessage = ""
    StatusColor   = $FW
}

#endregion

#region --- Helpers ---

function Write-At {
    param([int]$X, [int]$Y, [string]$Text)
    [Console]::SetCursorPosition($X, $Y)
    [Console]::Write($Text)
}

function Format-PadRight {
    param([string]$Text, [int]$Width)
    if ($Text.Length -ge $Width) { return $Text.Substring(0, $Width) }
    return $Text.PadRight($Width)
}

#endregion

#region --- Initialization ---

function Initialize-MenuState {
    param([System.Collections.IDictionary]$ByCategory)
    $s = $script:MenuState
    $s.ByCategory    = $ByCategory
    $s.Categories    = @($ByCategory.Keys)
    $s.CatIndex      = 0
    $s.ItemIndex     = 0
    $s.ScrollOffset  = 0
    $s.Focus         = 'items'
    $s.Selected      = @{}
    $s.StatusMessage = "Checking installed status..."
    $s.StatusColor   = $FY

    foreach ($cat in $s.Categories) {
        foreach ($util in $ByCategory[$cat]) {
            $fns = Get-UtilityFunctions $util
            $inst = if ($fns.Test) { & $fns.Test } else { $false }
            $util['_Installed'] = $inst
            $util['_Version']   = if ($inst -and $fns.GetVersion) { & $fns.GetVersion } else { $null }
            $s.Selected[$util.Id] = $false
        }
    }
    $s.StatusMessage = ""
}

#endregion

#region --- Drawing ---

function Get-TermSize {
    return @{ W = [Console]::WindowWidth; H = [Console]::WindowHeight }
}

function Show-Header {
    param([int]$W)
    $inner = $W - 2
    # Layout: col 0 = ║, cols 1..CAT_WIDTH+1 = cat panel inner (CAT_WIDTH+1 chars),
    # col CAT_WIDTH+2 = divider ║, cols (CAT_WIDTH+3)..(W-2) = items panel inner,
    # col W-1 = right ║. So divider sits at column CAT_WIDTH+2.
    $leftLen  = $CAT_WIDTH + 1                # ═ chars on left of ╦ in divider rows
    $rightLen = $inner - $leftLen - 1         # ═ chars on right of ╦

    $title   = Format-PadRight "  Windows Utilities Installer  |  win_util" $inner
    $subline = Format-PadRight "  Powered by winget  |  Use arrow keys to navigate" $inner

    $divLeft  = cH $leftLen
    $divRight = cH $rightLen

    Write-At 0 0 "${FC}${cTL}$(cH $inner)${cTR}${R}"
    Write-At 0 1 "${FC}${cVT}${R}${BOLD}${FW}${title}${R}${FC}${cVT}${R}"
    Write-At 0 2 "${FC}${cVT}${R}${FDim}${subline}${R}${FC}${cVT}${R}"
    Write-At 0 3 "${FC}${cML}${divLeft}${cTT}${divRight}${cMR}${R}"

    $catHdr  = Format-PadRight " CATEGORY" ($CAT_WIDTH + 1)
    $itemHdr = Format-PadRight " UTILITY" $rightLen
    Write-At 0 4 "${FC}${cVT}${R}${BOLD}${FY}${catHdr}${R}${FC}${cVT}${R}${BOLD}${FY}${itemHdr}${R}${FC}${cVT}${R}"
    Write-At 0 5 "${FC}${cML}${divLeft}${cXX}${divRight}${cMR}${R}"
}

function Show-Footer {
    param([int]$W, [int]$H)
    $inner = $W - 2
    $y     = $H - $FOOTER_ROWS
    $leftLen  = $CAT_WIDTH + 1
    $rightLen = $inner - $leftLen - 1

    $divLeft  = cH $leftLen
    $divRight = cH $rightLen

    $sel   = @($script:MenuState.Selected.Values | Where-Object { $_ }).Count
    $hint1 = Format-PadRight "  [SPACE] Toggle  [A] All  [D] None  [U] Update-All  [R] Refresh  [Q] Quit" $inner
    $hint2 = Format-PadRight "  [ENTER] Install/Uninstall selected  [$sel selected]" $inner

    Write-At 0 $y       "${FC}${cML}${divLeft}${cBT}${divRight}${cMR}${R}"
    Write-At 0 ($y + 1) "${FC}${cVT}${R}${FDim}${hint1}${R}${FC}${cVT}${R}"

    if ($script:MenuState.StatusMessage) {
        $msg = Format-PadRight "  $($script:MenuState.StatusMessage)" $inner
        Write-At 0 ($y + 2) "${FC}${cVT}${R}$($script:MenuState.StatusColor)${msg}${R}${FC}${cVT}${R}"
    } else {
        Write-At 0 ($y + 2) "${FC}${cVT}${R}${FW}${hint2}${R}${FC}${cVT}${R}"
    }

    Write-At 0 ($y + 3) "${FC}${cBL}$(cH $inner)${cBR}${R}"
}

function Show-Separator {
    param([int]$H)
    $rows   = $H - $HEADER_ROWS - $FOOTER_ROWS
    $startY = $HEADER_ROWS
    $x      = $CAT_WIDTH + 2

    for ($i = 0; $i -lt $rows; $i++) {
        Write-At $x ($startY + $i) "${FC}${cVT}${R}"
    }
}

function Show-Categories {
    param([int]$H)
    $s    = $script:MenuState
    $cats = $s.Categories
    $rows = $H - $HEADER_ROWS - $FOOTER_ROWS
    $y    = $HEADER_ROWS

    for ($i = 0; $i -lt $rows; $i++) {
        $ry = $y + $i
        if ($i -lt $cats.Count) {
            $cat   = $cats[$i]
            $label = Format-PadRight " $cat" ($CAT_WIDTH + 1)
            if ($i -eq $s.CatIndex -and $s.Focus -eq 'cats') {
                Write-At 0 $ry "${FC}${cVT}${R}${BH}${FY}${BOLD}${label}${R}${FC}${cVT}${R}"
            } elseif ($i -eq $s.CatIndex) {
                Write-At 0 $ry "${FC}${cVT}${R}${FY}${label}${R}${FC}${cVT}${R}"
            } else {
                Write-At 0 $ry "${FC}${cVT}${R}${FW}${label}${R}${FC}${cVT}${R}"
            }
        } else {
            Write-At 0 $ry "${FC}${cVT}${R}$(Format-PadRight '' ($CAT_WIDTH + 1))${FC}${cVT}${R}"
        }
    }
}

function Show-Items {
    param([int]$W, [int]$H)
    $s      = $script:MenuState
    # Layout: col 0 ║, cols 1..(CAT_WIDTH+1) cat panel, col (CAT_WIDTH+2) ║,
    # cols (CAT_WIDTH+3)..(W-2) items panel inner, col (W-1) ║.
    $startX = $CAT_WIDTH + 3
    $rightX = $W - 1
    $itemW  = $rightX - $startX           # inner width of items panel
    $rows   = $H - $HEADER_ROWS - $FOOTER_ROWS
    $startY = $HEADER_ROWS

    $cat   = if ($s.CatIndex -lt $s.Categories.Count) { $s.Categories[$s.CatIndex] } else { $null }
    $items = @()
    if ($cat -and $s.ByCategory[$cat]) { $items = @($s.ByCategory[$cat]) }

    if ($s.ItemIndex - $s.ScrollOffset -ge $rows) { $s.ScrollOffset = $s.ItemIndex - $rows + 1 }
    if ($s.ItemIndex -lt $s.ScrollOffset)          { $s.ScrollOffset = $s.ItemIndex }

    for ($i = 0; $i -lt $rows; $i++) {
        $ry  = $startY + $i
        $idx = $i + $s.ScrollOffset

        if ($idx -lt $items.Count) {
            $util      = $items[$idx]
            $id        = $util.Id
            $name      = $util.Name
            $installed = $util['_Installed']
            $version   = $util['_Version']
            $selected  = $s.Selected[$id]
            $isCur     = ($idx -eq $s.ItemIndex)

            $box      = if ($selected) { "[+]" } else { "[ ]" }
            $boxColor = if ($selected) { $FG } else { $FDim }

            $tagText  = if ($installed) { if ($version) { "v$version" } else { "installed" } } else { "not installed" }
            $tagColor = if ($installed) { $FM } else { $FDim }

            # Row content layout (itemW total chars): " [X] name <gap> tag "
            # Fixed overhead besides name+tag = 1 lead + 3 box + 1 + 1 + 1 trailing = 7
            $nameMax = $itemW - 7 - $tagText.Length
            if ($nameMax -lt 1) { $nameMax = 1 }
            if ($name.Length -gt $nameMax) { $name = $name.Substring(0, $nameMax - 1) + "~" }
            $gap = " " * ($nameMax - $name.Length)

            if ($isCur -and $s.Focus -eq 'items') {
                Write-At $startX $ry "${BH}${FY}${BOLD} ${box} ${name}${gap} ${tagText} ${R}"
            } else {
                Write-At $startX $ry " ${boxColor}${box}${R} ${FW}${name}${R}${gap} ${tagColor}${tagText}${R}"
            }
        } else {
            Write-At $startX $ry (" " * $itemW)
        }

        Write-At $rightX $ry "${FC}${cVT}${R}"
    }
}

function Show-Frame {
    $t = Get-TermSize
    $W = $t.W; $H = $t.H

    if ($W -lt $MIN_COLS -or $H -lt $MIN_ROWS) {
        [Console]::Clear()
        Write-At 0 0 "${FRed}Terminal too small. Please resize to at least ${MIN_COLS}x${MIN_ROWS}${R}"
        return
    }

    Show-Header    $W
    Show-Separator $H
    Show-Categories $H
    Show-Items      $W $H
    Show-Footer     $W $H
    [Console]::SetCursorPosition(0, $H - 1)
}

#endregion

#region --- Operations ---

function Invoke-Operation {
    param([string]$Mode)
    $s         = $script:MenuState
    $toProcess = [System.Collections.Generic.List[hashtable]]::new()

    if ($Mode -eq 'update-all') {
        foreach ($cat in $s.Categories) {
            foreach ($util in $s.ByCategory[$cat]) {
                if ($util['_Installed']) { $toProcess.Add($util) }
            }
        }
    } else {
        foreach ($cat in $s.Categories) {
            foreach ($util in $s.ByCategory[$cat]) {
                if ($s.Selected[$util.Id]) { $toProcess.Add($util) }
            }
        }
    }

    if ($toProcess.Count -eq 0) {
        $s.StatusMessage = if ($Mode -eq 'update-all') { "No installed utilities to update." } else { "Nothing selected." }
        $s.StatusColor   = $FY
        return
    }

    [Console]::Clear()
    [Console]::CursorVisible = $true

    $ok = 0; $fail = 0; $failNames = @()

    foreach ($util in $toProcess) {
        $fns = Get-UtilityFunctions $util
        Write-Host ""
        Write-Host "  ===> $($util.Name)" -ForegroundColor Cyan

        $exitCode = 0
        switch ($Mode) {
            'install'    { if ($fns.Install)   { & $fns.Install;   $exitCode = $LASTEXITCODE } }
            'uninstall'  { if ($fns.Uninstall) { & $fns.Uninstall; $exitCode = $LASTEXITCODE } }
            'update-all' { if ($fns.Update)    { & $fns.Update;    $exitCode = $LASTEXITCODE } }
        }

        if ($exitCode -eq 0) {
            Write-Host "  Done." -ForegroundColor Green
            Write-LogInfo "$($util.Name) - $Mode succeeded"
            $ok++
        } else {
            Write-Host "  Failed (exit $exitCode)" -ForegroundColor Red
            Write-LogError "$($util.Name) - $Mode failed (exit $exitCode)"
            $fail++
            $failNames += $util.Name
        }
    }

    Write-LogSummary $ok $fail $failNames

    Write-Host ""
    Write-Host "  Done.  Succeeded: $ok  Failed: $fail" -ForegroundColor White
    Write-Host ""
    Write-Host "  Press any key to return to the menu..."
    $null = [Console]::ReadKey($true)

    foreach ($util in $toProcess) {
        $fns = Get-UtilityFunctions $util
        if ($fns.Test) { $util['_Installed'] = & $fns.Test }
        if ($util['_Installed'] -and $fns.GetVersion) { $util['_Version'] = & $fns.GetVersion }
        $s.Selected[$util.Id] = $false
    }

    [Console]::CursorVisible = $false
    [Console]::Clear()
    $s.StatusMessage = "Last run: $ok succeeded, $fail failed."
    $s.StatusColor   = if ($fail -gt 0) { $FRed } else { $FG }
}

function Update-MenuStatus {
    $s = $script:MenuState
    $s.StatusMessage = "Refreshing..."
    $s.StatusColor   = $FY
    Show-Frame

    foreach ($cat in $s.Categories) {
        foreach ($util in $s.ByCategory[$cat]) {
            $fns = Get-UtilityFunctions $util
            if ($fns.Test) { $util['_Installed'] = & $fns.Test }
            if ($util['_Installed'] -and $fns.GetVersion) { $util['_Version'] = & $fns.GetVersion }
        }
    }
    $s.StatusMessage = "Status refreshed."
    $s.StatusColor   = $FG
}

#endregion

#region --- Main Loop ---

function Start-Menu {
    param([System.Collections.IDictionary]$ByCategory)

    Initialize-MenuState $ByCategory

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::CursorVisible  = $false
    [Console]::Clear()

    $s = $script:MenuState
    $lastW = 0; $lastH = 0

    while ($true) {
        $t = Get-TermSize
        if ($t.W -ne $lastW -or $t.H -ne $lastH) {
            [Console]::Clear()
            $lastW = $t.W; $lastH = $t.H
        }
        Show-Frame

        while (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 80
            $t = Get-TermSize
            if ($t.W -ne $lastW -or $t.H -ne $lastH) {
                [Console]::Clear()
                $lastW = $t.W; $lastH = $t.H
                Show-Frame
            }
        }
        $key = [Console]::ReadKey($true)
        $s.StatusMessage = ""

        switch ($key.Key) {
            'UpArrow' {
                if ($s.Focus -eq 'cats') {
                    if ($s.CatIndex -gt 0) { $s.CatIndex--; $s.ItemIndex = 0; $s.ScrollOffset = 0 }
                } else {
                    if ($s.ItemIndex -gt 0) { $s.ItemIndex-- }
                }
            }
            'DownArrow' {
                if ($s.Focus -eq 'cats') {
                    if ($s.CatIndex -lt ($s.Categories.Count - 1)) {
                        $s.CatIndex++; $s.ItemIndex = 0; $s.ScrollOffset = 0
                    }
                } else {
                    $cat   = $s.Categories[$s.CatIndex]
                    $count = if ($s.ByCategory[$cat]) { $s.ByCategory[$cat].Count } else { 0 }
                    if ($s.ItemIndex -lt ($count - 1)) { $s.ItemIndex++ }
                }
            }
            'LeftArrow'  { $s.Focus = 'cats' }
            'RightArrow' { $s.Focus = 'items' }
            'Tab'        { $s.Focus = if ($s.Focus -eq 'cats') { 'items' } else { 'cats' } }

            'Spacebar' {
                $cat   = $s.Categories[$s.CatIndex]
                $items = @()
                if ($s.ByCategory[$cat]) { $items = @($s.ByCategory[$cat]) }
                if ($items.Count -gt 0 -and $s.ItemIndex -lt $items.Count) {
                    $id = $items[$s.ItemIndex].Id
                    $s.Selected[$id] = -not $s.Selected[$id]
                }
            }
            'A' {
                $cat = $s.Categories[$s.CatIndex]
                if ($s.ByCategory[$cat]) {
                    foreach ($u in $s.ByCategory[$cat]) { $s.Selected[$u.Id] = $true }
                }
            }
            'D' {
                $cat = $s.Categories[$s.CatIndex]
                if ($s.ByCategory[$cat]) {
                    foreach ($u in $s.ByCategory[$cat]) { $s.Selected[$u.Id] = $false }
                }
            }
            'R' { Update-MenuStatus }
            'U' { Invoke-Operation 'update-all' }

            'Enter' {
                $anySelected = $s.Selected.Values | Where-Object { $_ }
                if ($anySelected) {
                    $allInstalled = $true
                    foreach ($cat in $s.Categories) {
                        foreach ($u in $s.ByCategory[$cat]) {
                            if ($s.Selected[$u.Id] -and -not $u['_Installed']) { $allInstalled = $false }
                        }
                    }
                    Invoke-Operation (if ($allInstalled) { 'uninstall' } else { 'install' })
                } else {
                    $s.StatusMessage = "Select items with [SPACE] first."
                    $s.StatusColor   = $FY
                }
            }

            'Q' {
                [Console]::CursorVisible = $true
                [Console]::Clear()
                return
            }
        }
    }
}

#endregion

#endregion

#region --- main ---


#region --- Bootstrap ---

function Show-Banner {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "     Windows Utilities Installer" -ForegroundColor White
    Write-Host "     Powered by winget  |  win_util v1.0" -ForegroundColor DarkGray
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host ""
}


function Assert-Winget {
    if (-not (Test-WingetAvailable)) {
        Write-Host "  [ERROR] winget is not available on this system." -ForegroundColor Red
        Write-Host "  Install it from the Microsoft Store (App Installer) and try again." -ForegroundColor Red
        exit 1
    }
}

function Sync-DesktopIcon {
    # Ensures %LOCALAPPDATA%\win_util\win_util.ico matches the upstream version
    # by comparing SHA256 with assets/win_util.ico.sha256 in the repo. Returns
    # the local icon path on success, or $null if the icon couldn't be fetched.
    #
    # Runs on every launch so icon changes propagate to existing installs without
    # any user action.
    $iconDir  = Join-Path $env:LOCALAPPDATA 'win_util'
    $iconPath = Join-Path $iconDir 'win_util.ico'
    $iconUrl  = 'https://raw.githubusercontent.com/acebmxer/win_util/main/assets/win_util.ico'
    $hashUrl  = 'https://raw.githubusercontent.com/acebmxer/win_util/main/assets/win_util.ico.sha256'

    try {
        if (-not (Test-Path $iconDir)) { New-Item -ItemType Directory -Path $iconDir -Force | Out-Null }

        $remoteHash = $null
        try {
            $remoteHash = (Invoke-WebRequest -Uri $hashUrl -UseBasicParsing -ErrorAction Stop).Content.Trim().ToLower()
        } catch {
            # If the manifest fetch fails (offline, GitHub down), keep whatever
            # icon we already have rather than aborting the shortcut entirely.
            if (Test-Path $iconPath) { return $iconPath } else { return $null }
        }

        $localHash = $null
        if (Test-Path $iconPath) {
            $localHash = (Get-FileHash -Path $iconPath -Algorithm SHA256).Hash.ToLower()
        }

        if ($localHash -ne $remoteHash) {
            Invoke-WebRequest -Uri $iconUrl -OutFile $iconPath -UseBasicParsing -ErrorAction Stop
        }
        return $iconPath
    } catch {
        if (Test-Path $iconPath) { return $iconPath } else { return $null }
    }
}

function New-DesktopShortcut {
    # Silently creates a "Win Util" desktop shortcut and keeps its icon in sync
    # with the upstream copy. Used so `irm .../win_util.ps1 | iex` self-installs.
    $desktop      = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktop 'Win Util.lnk'

    # Always sync the icon, even if the shortcut already exists, so icon updates
    # in the repo propagate on the next launch.
    $iconPath = Sync-DesktopIcon
    $iconLoc  = if ($iconPath) { "$iconPath,0" } else { $null }

    try {
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $url   = 'https://raw.githubusercontent.com/acebmxer/win_util/main/dist/win_util.ps1'
        $cmd      = "& ([scriptblock]::Create((irm '$url')))"
        $psArgs   = "-NoExit -ExecutionPolicy Bypass -NoProfile -Command `"$cmd`""

        $shell = New-Object -ComObject WScript.Shell

        if (Test-Path $shortcutPath) {
            # Shortcut exists. Update its icon reference if the icon location
            # has drifted (e.g. a previous run fell back to the powershell.exe
            # icon and now the .ico is available). Touching .Save() also bumps
            # the .lnk's mtime so Explorer re-reads the icon on next refresh.
            $existing = $shell.CreateShortcut($shortcutPath)
            $desired  = if ($iconLoc) { $iconLoc } else { "$psExe,0" }
            if ($existing.IconLocation -ne $desired) {
                $existing.IconLocation = $desired
                $existing.Save()
            }
            return
        }

        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath       = $psExe
        $shortcut.Arguments        = $psArgs
        $shortcut.WorkingDirectory = $env:USERPROFILE
        $shortcut.IconLocation     = if ($iconLoc) { $iconLoc } else { "$psExe,0" }
        $shortcut.Description      = 'Windows Utilities Installer (win_util)'
        $shortcut.Save()

        Write-Host "  [+] Created desktop shortcut: $shortcutPath" -ForegroundColor Green
    } catch {
        # Non-fatal: shortcut creation should never block the menu.
        Write-Host "  [!] Could not create desktop shortcut: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

#endregion

#region --- CLI Helpers ---

function Find-Utility {
    param([string]$Name)
    foreach ($u in Get-AllUtilities) {
        if ($u.Name -ieq $Name -or $u.Id -ieq $Name) { return $u }
    }
    return $null
}

function Show-Help {
    Write-Host ""
    Write-Host "  win_util - Windows Utilities Installer" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  USAGE:"
    Write-Host "    .\win_util.ps1                             Interactive menu"
    Write-Host "    .\win_util.ps1 --install   [name/id]      Install a utility"
    Write-Host "    .\win_util.ps1 --uninstall [name/id]      Uninstall a utility"
    Write-Host "    .\win_util.ps1 --update    [name/id]      Update a utility"
    Write-Host "    .\win_util.ps1 --update-all               Update all installed utilities"
    Write-Host "    .\win_util.ps1 --list                     List all available utilities"
    Write-Host "    .\win_util.ps1 --check     [name/id]      Check installation status"
    Write-Host "    .\win_util.ps1 --help                     Show this help"
    Write-Host ""
    Write-Host "  MENU KEYS:"
    Write-Host "    Arrow keys    Navigate categories and items"
    Write-Host "    Tab           Switch between panels"
    Write-Host "    Space         Toggle selection"
    Write-Host "    A             Select all in category"
    Write-Host "    D             Deselect all in category"
    Write-Host "    Enter         Install / Uninstall selected"
    Write-Host "    U             Update all installed"
    Write-Host "    R             Refresh installed status"
    Write-Host "    Q             Quit"
    Write-Host ""
}

function Show-List {
    $grouped = Get-UtilitiesByCategory
    Write-Host ""
    foreach ($cat in $grouped.Keys) {
        Write-Host "  [$cat]" -ForegroundColor Yellow
        foreach ($u in $grouped[$cat]) {
            $installed = if ((Test-WingetInstalled $u.Id)) { " [installed]" } else { "" }
            Write-Host ("    {0,-30} {1}{2}" -f $u.Name, $u.Id, $installed) -ForegroundColor White
        }
        Write-Host ""
    }
}

function Invoke-CLIInstall {
    param([string]$Name)
    $u = Find-Utility $Name
    if (-not $u) { Write-Host "  Unknown utility: '$Name'" -ForegroundColor Red; exit 1 }
    Write-Host "  Installing $($u.Name)..." -ForegroundColor Cyan
    $fns = Get-UtilityFunctions $u
    if ($fns.Install) { & $fns.Install } else { Invoke-WingetInstall $u.Id }
}

function Invoke-CLIUninstall {
    param([string]$Name)
    $u = Find-Utility $Name
    if (-not $u) { Write-Host "  Unknown utility: '$Name'" -ForegroundColor Red; exit 1 }
    Write-Host "  Uninstalling $($u.Name)..." -ForegroundColor Cyan
    $fns = Get-UtilityFunctions $u
    if ($fns.Uninstall) { & $fns.Uninstall } else { Invoke-WingetUninstall $u.Id }
}

function Invoke-CLIUpdate {
    param([string]$Name)
    $u = Find-Utility $Name
    if (-not $u) { Write-Host "  Unknown utility: '$Name'" -ForegroundColor Red; exit 1 }
    Write-Host "  Updating $($u.Name)..." -ForegroundColor Cyan
    $fns = Get-UtilityFunctions $u
    if ($fns.Update) { & $fns.Update } else { Invoke-WingetUpdate $u.Id }
}

function Invoke-CLIUpdateAll {
    foreach ($u in Get-AllUtilities) {
        $fns = Get-UtilityFunctions $u
        $installed = if ($fns.Test) { & $fns.Test } else { Test-WingetInstalled $u.Id }
        if ($installed) {
            Write-Host "  Updating $($u.Name)..." -ForegroundColor Cyan
            if ($fns.Update) { & $fns.Update } else { Invoke-WingetUpdate $u.Id }
        }
    }
}

function Invoke-CLICheck {
    param([string]$Name)
    $u = Find-Utility $Name
    if (-not $u) { Write-Host "  Unknown utility: '$Name'" -ForegroundColor Red; exit 1 }
    $fns       = Get-UtilityFunctions $u
    $installed = if ($fns.Test) { & $fns.Test } else { Test-WingetInstalled $u.Id }
    $version   = if ($installed -and $fns.GetVersion) { & $fns.GetVersion } else { $null }
    $status    = if ($installed) { "installed" } else { "not installed" }
    $color     = if ($installed) { "Green" } else { "Red" }
    Write-Host "  $($u.Name): " -NoNewline
    Write-Host $status -ForegroundColor $color
    if ($version) { Write-Host "  Version: $version" -ForegroundColor Magenta }
}

#endregion

#region --- Entry Point ---

Initialize-Logging
Assert-Winget

if ($Help)      { Show-Banner; Show-Help;                       exit 0 }
if ($List)      { Show-Banner; Show-List;                       exit 0 }
if ($Install)   { Show-Banner; Invoke-CLIInstall   $Install;    exit 0 }
if ($Uninstall) { Show-Banner; Invoke-CLIUninstall $Uninstall;  exit 0 }
if ($Update)    { Show-Banner; Invoke-CLIUpdate     $Update;    exit 0 }
if ($UpdateAll) { Show-Banner; Invoke-CLIUpdateAll;             exit 0 }
if ($Check)     { Show-Banner; Invoke-CLICheck      $Check;     exit 0 }

# Default: interactive menu
Show-Banner
New-DesktopShortcut
Write-Host "  Loading utilities..." -ForegroundColor DarkGray
$grouped = Get-UtilitiesByCategory
Start-Menu $grouped

#endregion
#endregion
