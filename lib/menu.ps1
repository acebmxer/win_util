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

function cH { param([int]$N) return ([string]$cHZ) * $N }  # repeat horizontal line

#endregion

#region --- Layout Constants ---

$CAT_WIDTH   = 18   # left panel inner width (excluding borders)
$MIN_COLS    = 72
$MIN_ROWS    = 20
$HEADER_ROWS = 5
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
    $catW  = $CAT_WIDTH + 2

    $title   = Format-PadRight "  Windows Utilities Installer  |  win_util" $inner
    $subline = Format-PadRight "  Powered by winget  |  Use arrow keys to navigate" $inner

    $divLeft  = cH $catW
    $divRight = cH ($inner - $catW)

    Write-At 0 0 "${FC}${cTL}$(cH $inner)${cTR}${R}"
    Write-At 0 1 "${FC}${cVT}${R}${BOLD}${FW}${title}${R}${FC}${cVT}${R}"
    Write-At 0 2 "${FC}${cVT}${R}${FDim}${subline}${R}${FC}${cVT}${R}"
    Write-At 0 3 "${FC}${cML}${divLeft}${cTT}${divRight}${cMR}${R}"

    $catHdr  = Format-PadRight " CATEGORY" ($CAT_WIDTH + 1)
    $itemHdr = Format-PadRight " UTILITY" ($inner - $catW - 1)
    Write-At 0 4 "${FC}${cVT}${R}${BOLD}${FY}${catHdr}${R}${FC}${cVT}${R} ${BOLD}${FY}${itemHdr}${R}${FC}${cVT}${R}"
}

function Show-Footer {
    param([int]$W, [int]$H)
    $inner = $W - 2
    $y     = $H - $FOOTER_ROWS
    $catW  = $CAT_WIDTH + 2

    $divLeft  = cH $catW
    $divRight = cH ($inner - $catW)

    $sel   = ($script:MenuState.Selected.Values | Where-Object { $_ }).Count
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
    $rows   = $H - $HEADER_ROWS - $FOOTER_ROWS - 1
    $startY = $HEADER_ROWS + 1
    $x      = $CAT_WIDTH + 2

    for ($i = 0; $i -lt $rows; $i++) {
        Write-At $x ($startY + $i) "${FC}${cVT}${R}"
    }
}

function Show-Categories {
    param([int]$H)
    $s    = $script:MenuState
    $cats = $s.Categories
    $rows = $H - $HEADER_ROWS - $FOOTER_ROWS - 1
    $y    = $HEADER_ROWS + 1

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
    $catW   = $CAT_WIDTH + 2
    $itemW  = $W - $catW - 3
    $rows   = $H - $HEADER_ROWS - $FOOTER_ROWS - 1
    $startY = $HEADER_ROWS + 1
    $startX = $catW + 1

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

            $box = if ($selected) { "[+]" } else { "[ ]" }
            $boxColor = if ($selected) { $FG } else { $FDim }

            $tagText  = if ($installed) { if ($version) { "v$version" } else { "installed" } } else { "not installed" }
            $tagColor = if ($installed) { $FM } else { $FDim }

            $nameMax = $itemW - 6 - $tagText.Length
            if ($nameMax -lt 1) { $nameMax = 1 }
            if ($name.Length -gt $nameMax) { $name = $name.Substring(0, $nameMax - 1) + "~" }
            $gap = " " * ($nameMax - $name.Length)

            if ($isCur -and $s.Focus -eq 'items') {
                Write-At $startX $ry "${BH}${FY}${BOLD} ${box} ${name}${gap} ${tagText} ${R}"
            } else {
                Write-At $startX $ry " ${boxColor}${box}${R} ${FW}${name}${R}${gap} ${tagColor}${tagText}${R}"
            }
        } else {
            Write-At $startX $ry (" " * ($itemW + 1))
        }
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

    while ($true) {
        Show-Frame
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

