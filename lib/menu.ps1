# Interactive TUI menu for win_util
#
# Layout (mirrors linux_util):
#
#   ┌──────────────────────┬──────────────────────────────────────────────────┐
#   │ Header                                                                  │
#   ├──────────────────────┼──────────────────────────────────────────────────┤
#   │ CATEGORIES           │ <current section header>                         │
#   │   > Browsers         │   [ ]  Item Name              not installed      │
#   │     Development      │   [+]  Item Name              v1.2.3             │
#   │     ...              │                                                  │
#   ├──────────────────────┤                                                  │
#   │ PROFILES             │                                                  │
#   │     Run Me First     │                                                  │
#   │     Developer WS.    │                                                  │
#   │     ...              │                                                  │
#   ├──────────────────────┤                                                  │
#   │ SYSTEM Details       │                                                  │
#   │   Host: ...          │                                                  │
#   │   OS:   ...          ├──────────────────────────────────────────────────┤
#   │   CPU:  ...          │ <description pane>                               │
#   ├──────────────────────┴──────────────────────────────────────────────────┤
#   │ Footer / keybinds                                                       │
#   └─────────────────────────────────────────────────────────────────────────┘

#region --- ANSI Colors & Box Drawing ---

$ESC  = [char]27
$R    = "${ESC}[0m"
$BOLD = "${ESC}[1m"

$FC   = "${ESC}[36m"       # cyan        - borders/structure
$FY   = "${ESC}[33m"       # yellow      - cursor/counts
$FG   = "${ESC}[32m"       # green       - selected / success
$FM   = "${ESC}[35m"       # magenta     - version tags
$FRed = "${ESC}[31m"       # red         - errors
$FW   = "${ESC}[97m"       # bright white - titles
$FDim = "${ESC}[2;37m"     # dim white   - inactive
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

function cH { param([int]$N) return ([string]$cHZ) * $N }

#endregion

#region --- Layout Constants ---

$CAT_WIDTH    = 22   # left sidebar inner width
$MIN_COLS     = 78
$MIN_ROWS     = 24
$HEADER_ROWS  = 6
$FOOTER_ROWS  = 4
$DESC_ROWS    = 4    # description pane height (right side, bottom)

#endregion

#region --- State ---

$script:MenuState = @{
    Categories    = @()         # category names
    ByCategory    = @{}         # name -> list of utility hashtables
    Profiles      = @()         # profile hashtables
    SysInfo       = $null       # hashtable from Get-SystemInfo

    # Sidebar focus model: which sidebar section is active, and the row index
    # inside it. 'cats' / 'profiles' / 'items' for focus.
    Section       = 'cats'      # which sidebar section the cursor sits in
    CatIndex      = 0
    ProfileIndex  = 0
    ItemIndex     = 0
    Focus         = 'items'     # 'items' or 'sidebar'
    Selected      = @{}         # utility Id -> bool
    ScrollOffset  = 0
    StatusMessage = ""
    StatusColor   = $null       # set after $FW is defined
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

function Get-TermSize {
    return @{ W = [Console]::WindowWidth; H = [Console]::WindowHeight }
}

# Current items panel ("Browsers", "Development", or a profile preview).
function Get-CurrentItems {
    $s = $script:MenuState
    if ($s.Categories.Count -eq 0) { return @() }
    $cat = $s.Categories[$s.CatIndex]
    if ($s.ByCategory[$cat]) { return @($s.ByCategory[$cat]) }
    return @()
}

function Get-CurrentSectionTitle {
    $s = $script:MenuState
    if ($s.Categories.Count -eq 0) { return "" }
    return $s.Categories[$s.CatIndex]
}

#endregion

#region --- Initialization ---

function Initialize-MenuState {
    param([System.Collections.IDictionary]$ByCategory)
    $s = $script:MenuState
    $s.ByCategory    = $ByCategory
    $s.Categories    = @($ByCategory.Keys)
    $s.Profiles      = @(Get-AllProfiles)
    $s.SysInfo       = Get-SystemInfo
    $s.Section       = 'cats'
    $s.CatIndex      = 0
    $s.ProfileIndex  = 0
    $s.ItemIndex     = 0
    $s.ScrollOffset  = 0
    $s.Focus         = 'items'
    $s.Selected      = @{}
    $s.StatusMessage = "Checking installed status..."
    $s.StatusColor   = $FY

    foreach ($cat in $s.Categories) {
        foreach ($util in $ByCategory[$cat]) {
            $fns  = Get-UtilityFunctions $util
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

function Show-Header {
    param([int]$W)
    $inner    = $W - 2
    $leftLen  = $CAT_WIDTH + 1
    $rightLen = $inner - $leftLen - 1

    $title   = Format-PadRight "  Windows Utilities Installer  |  win_util" $inner
    $subline = Format-PadRight "  Powered by winget  |  Tab=switch focus  |  Q=quit" $inner

    $divLeft  = cH $leftLen
    $divRight = cH $rightLen

    Write-At 0 0 "${FC}${cTL}$(cH $inner)${cTR}${R}"
    Write-At 0 1 "${FC}${cVT}${R}${BOLD}${FW}${title}${R}${FC}${cVT}${R}"
    Write-At 0 2 "${FC}${cVT}${R}${FDim}${subline}${R}${FC}${cVT}${R}"
    Write-At 0 3 "${FC}${cML}${divLeft}${cTT}${divRight}${cMR}${R}"

    $catHdr  = Format-PadRight " SIDEBAR" ($CAT_WIDTH + 1)
    $itemHdr = Format-PadRight (" " + (Get-CurrentSectionTitle)) $rightLen
    Write-At 0 4 "${FC}${cVT}${R}${BOLD}${FY}${catHdr}${R}${FC}${cVT}${R}${BOLD}${FY}${itemHdr}${R}${FC}${cVT}${R}"
    Write-At 0 5 "${FC}${cML}${divLeft}${cXX}${divRight}${cMR}${R}"
}

function Show-Footer {
    param([int]$W, [int]$H)
    $inner    = $W - 2
    $y        = $H - $FOOTER_ROWS
    $leftLen  = $CAT_WIDTH + 1
    $rightLen = $inner - $leftLen - 1

    $divLeft  = cH $leftLen
    $divRight = cH $rightLen

    $sel = @($script:MenuState.Selected.Values | Where-Object { $_ }).Count

    $hint1 = Format-PadRight "  [SPACE] Toggle  [A] All  [D] None  [U] Update-All  [R] Refresh  [Q] Quit" $inner
    $hint2 = Format-PadRight "  [ENTER] Install/Uninstall (or apply profile)  [$sel selected]" $inner

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

# Build the sidebar as an ordered list of "lines", each tagged with type:
#   header        -section heading (CATEGORIES / PROFILES / SYSTEM Details)
#   sep           -horizontal separator line
#   cat           -selectable category row (Index = $s.CatIndex)
#   profile       -selectable profile row (Index = $s.ProfileIndex)
#   info          -read-only system info row
#   blank         -empty padding
#
# This lets us render and navigate the sidebar uniformly.
function Get-SidebarLines {
    $s     = $script:MenuState
    $lines = [System.Collections.Generic.List[hashtable]]::new()

    $lines.Add(@{ Type='header'; Text='CATEGORIES' })
    $lines.Add(@{ Type='sep' })
    for ($i = 0; $i -lt $s.Categories.Count; $i++) {
        $lines.Add(@{ Type='cat'; Text=$s.Categories[$i]; Index=$i })
    }

    $lines.Add(@{ Type='blank' })
    $lines.Add(@{ Type='header'; Text='PROFILES' })
    $lines.Add(@{ Type='sep' })
    for ($i = 0; $i -lt $s.Profiles.Count; $i++) {
        $lines.Add(@{ Type='profile'; Text=$s.Profiles[$i].Name; Index=$i })
    }

    $lines.Add(@{ Type='blank' })
    $lines.Add(@{ Type='header'; Text='SYSTEM Details' })
    $lines.Add(@{ Type='sep' })
    if ($s.SysInfo) {
        $pairs = @(
            @{ K='Host';   V=$s.SysInfo.Host   },
            @{ K='OS';     V=$s.SysInfo.OS     },
            @{ K='Kernel'; V=$s.SysInfo.Kernel },
            @{ K='CPU';    V=$s.SysInfo.CPU    },
            @{ K='Mem';    V=$s.SysInfo.Mem    },
            @{ K='Disk';   V=$s.SysInfo.Disk   },
            @{ K='Uptime'; V=$s.SysInfo.Uptime }
        )
        foreach ($p in $pairs) {
            $lines.Add(@{ Type='info'; Text=("{0,7}: {1}" -f $p.K, $p.V) })
        }
    }

    return $lines
}

function Show-Sidebar {
    param([int]$H)
    $s     = $script:MenuState
    $lines = @(Get-SidebarLines)
    $rows  = $H - $HEADER_ROWS - $FOOTER_ROWS
    $y     = $HEADER_ROWS
    $width = $CAT_WIDTH + 1

    for ($i = 0; $i -lt $rows; $i++) {
        $ry = $y + $i
        if ($i -lt $lines.Count) {
            $line = $lines[$i]
            switch ($line.Type) {
                'header'  {
                    $label = Format-PadRight (" " + $line.Text) $width
                    Write-At 0 $ry "${FC}${cVT}${R}${BOLD}${FY}${label}${R}${FC}${cVT}${R}"
                }
                'sep'     {
                    Write-At 0 $ry "${FC}${cVT}${R}${FDim}$(cH $width)${R}${FC}${cVT}${R}"
                }
                'blank'   {
                    Write-At 0 $ry "${FC}${cVT}${R}$(Format-PadRight '' $width)${FC}${cVT}${R}"
                }
                'info'    {
                    $label = Format-PadRight (" " + $line.Text) $width
                    Write-At 0 $ry "${FC}${cVT}${R}${FDim}${label}${R}${FC}${cVT}${R}"
                }
                'cat'     {
                    $isSel = ($s.Section -eq 'cats' -and $line.Index -eq $s.CatIndex)
                    $label = Format-PadRight ("   " + $line.Text) $width
                    if ($isSel -and $s.Focus -eq 'sidebar') {
                        Write-At 0 $ry "${FC}${cVT}${R}${BH}${FY}${BOLD}${label}${R}${FC}${cVT}${R}"
                    } elseif ($isSel) {
                        Write-At 0 $ry "${FC}${cVT}${R}${FY}${label}${R}${FC}${cVT}${R}"
                    } else {
                        Write-At 0 $ry "${FC}${cVT}${R}${FW}${label}${R}${FC}${cVT}${R}"
                    }
                }
                'profile' {
                    $isSel = ($s.Section -eq 'profiles' -and $line.Index -eq $s.ProfileIndex)
                    $label = Format-PadRight ("   " + $line.Text) $width
                    if ($isSel -and $s.Focus -eq 'sidebar') {
                        Write-At 0 $ry "${FC}${cVT}${R}${BH}${FG}${BOLD}${label}${R}${FC}${cVT}${R}"
                    } elseif ($isSel) {
                        Write-At 0 $ry "${FC}${cVT}${R}${FG}${label}${R}${FC}${cVT}${R}"
                    } else {
                        Write-At 0 $ry "${FC}${cVT}${R}${FW}${label}${R}${FC}${cVT}${R}"
                    }
                }
            }
        } else {
            Write-At 0 $ry "${FC}${cVT}${R}$(Format-PadRight '' $width)${FC}${cVT}${R}"
        }
    }
}

function Show-Items {
    param([int]$W, [int]$H)
    $s        = $script:MenuState
    $startX   = $CAT_WIDTH + 3
    $rightX   = $W - 1
    $itemW    = $rightX - $startX
    $totalRows = $H - $HEADER_ROWS - $FOOTER_ROWS
    $descTop   = $HEADER_ROWS + $totalRows - $DESC_ROWS
    $listRows  = $totalRows - $DESC_ROWS - 1   # minus 1 for the divider row
    $startY    = $HEADER_ROWS

    $items = Get-CurrentItems

    if ($s.ItemIndex - $s.ScrollOffset -ge $listRows) { $s.ScrollOffset = $s.ItemIndex - $listRows + 1 }
    if ($s.ItemIndex -lt $s.ScrollOffset)             { $s.ScrollOffset = $s.ItemIndex }

    for ($i = 0; $i -lt $listRows; $i++) {
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

    # Divider between item list and description pane.
    $divY = $startY + $listRows
    Write-At $startX $divY "${FC}${FDim}$(cH $itemW)${R}"
    Write-At $rightX $divY "${FC}${cVT}${R}"

    # Description pane: show description of the currently focused item or profile.
    $descLines = @(Get-DescriptionLines $itemW $DESC_ROWS)
    for ($i = 0; $i -lt $DESC_ROWS; $i++) {
        $ry = $descTop + $i
        $text = if ($i -lt $descLines.Count) { $descLines[$i] } else { "" }
        Write-At $startX $ry (Format-PadRight ("  " + $text) $itemW)
        Write-At $rightX $ry "${FC}${cVT}${R}"
    }
}

# Returns word-wrapped description lines for the focused element.
function Get-DescriptionLines {
    param([int]$Width, [int]$MaxRows)
    $s = $script:MenuState
    $text = ""

    if ($s.Section -eq 'profiles' -and $s.Focus -eq 'sidebar') {
        if ($s.ProfileIndex -lt $s.Profiles.Count) {
            $p = $s.Profiles[$s.ProfileIndex]
            $text = "$($p.Description) -$($p.Items.Count) items"
        }
    } else {
        $items = Get-CurrentItems
        if ($items.Count -gt 0 -and $s.ItemIndex -lt $items.Count) {
            $util = $items[$s.ItemIndex]
            if ($util.ContainsKey('Description') -and $util.Description) {
                $text = $util.Description
            } else {
                $text = $util.Id
            }
        }
    }

    return (Format-WrappedText $text ($Width - 2) $MaxRows)
}

function Format-WrappedText {
    param([string]$Text, [int]$Width, [int]$MaxLines)
    if (-not $Text -or $Width -lt 1) { return @() }
    $words = $Text -split '\s+'
    $lines = [System.Collections.Generic.List[string]]::new()
    $cur = ""
    foreach ($w in $words) {
        if ($cur.Length -eq 0) {
            $cur = $w
        } elseif (($cur.Length + 1 + $w.Length) -le $Width) {
            $cur = "$cur $w"
        } else {
            $lines.Add($cur)
            if ($lines.Count -ge $MaxLines) { return $lines }
            $cur = $w
        }
    }
    if ($cur.Length -gt 0 -and $lines.Count -lt $MaxLines) { $lines.Add($cur) }
    return $lines
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
    Show-Sidebar   $H
    Show-Items     $W $H
    Show-Footer    $W $H
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

function Invoke-ProfileApply {
    param([hashtable]$ProfileDef)
    $s        = $script:MenuState
    $resolved = Resolve-ProfileItems $ProfileDef
    $missing  = @()

    # Clear current selections, then mark profile items.
    foreach ($id in @($s.Selected.Keys)) { $s.Selected[$id] = $false }
    foreach ($util in $resolved) { $s.Selected[$util.Id] = $true }

    foreach ($name in $ProfileDef.Items) {
        $found = $false
        foreach ($r in $resolved) {
            if ($r.Name -ieq $name) { $found = $true; break }
        }
        if (-not $found) { $missing += $name }
    }

    $count = $resolved.Count
    if ($missing.Count -gt 0) {
        $s.StatusMessage = "Profile '$($ProfileDef.Name)' applied: $count selected, $($missing.Count) missing."
        $s.StatusColor   = $FY
    } else {
        $s.StatusMessage = "Profile '$($ProfileDef.Name)' applied: $count items selected."
        $s.StatusColor   = $FG
    }
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
    $s.SysInfo = Get-SystemInfo
    $s.StatusMessage = "Status refreshed."
    $s.StatusColor   = $FG
}

#endregion

#region --- Navigation Helpers ---

# Cycle the sidebar focus through cats -> profiles -> (and back).
function Move-Sidebar {
    param([int]$Direction)   # +1 down, -1 up
    $s = $script:MenuState
    if ($s.Section -eq 'cats') {
        $next = $s.CatIndex + $Direction
        if ($next -lt 0) {
            # Wrap up: move into profiles at the last index.
            if ($s.Profiles.Count -gt 0) {
                $s.Section = 'profiles'
                $s.ProfileIndex = $s.Profiles.Count - 1
            }
        } elseif ($next -ge $s.Categories.Count) {
            # Wrap down: move into profiles at index 0.
            if ($s.Profiles.Count -gt 0) {
                $s.Section = 'profiles'
                $s.ProfileIndex = 0
            }
        } else {
            $s.CatIndex = $next
            $s.ItemIndex = 0; $s.ScrollOffset = 0
        }
    } elseif ($s.Section -eq 'profiles') {
        $next = $s.ProfileIndex + $Direction
        if ($next -lt 0) {
            if ($s.Categories.Count -gt 0) {
                $s.Section = 'cats'
                $s.CatIndex = $s.Categories.Count - 1
                $s.ItemIndex = 0; $s.ScrollOffset = 0
            }
        } elseif ($next -ge $s.Profiles.Count) {
            if ($s.Categories.Count -gt 0) {
                $s.Section = 'cats'
                $s.CatIndex = 0
                $s.ItemIndex = 0; $s.ScrollOffset = 0
            }
        } else {
            $s.ProfileIndex = $next
        }
    }
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
                if ($s.Focus -eq 'sidebar') {
                    Move-Sidebar -1
                } else {
                    if ($s.ItemIndex -gt 0) { $s.ItemIndex-- }
                }
            }
            'DownArrow' {
                if ($s.Focus -eq 'sidebar') {
                    Move-Sidebar 1
                } else {
                    $items = Get-CurrentItems
                    if ($s.ItemIndex -lt ($items.Count - 1)) { $s.ItemIndex++ }
                }
            }
            'LeftArrow'  { $s.Focus = 'sidebar' }
            'RightArrow' { $s.Focus = 'items' }
            'Tab'        { $s.Focus = if ($s.Focus -eq 'sidebar') { 'items' } else { 'sidebar' } }

            'Spacebar' {
                if ($s.Focus -eq 'items') {
                    $items = Get-CurrentItems
                    if ($items.Count -gt 0 -and $s.ItemIndex -lt $items.Count) {
                        $id = $items[$s.ItemIndex].Id
                        $s.Selected[$id] = -not $s.Selected[$id]
                    }
                }
            }
            'A' {
                $items = Get-CurrentItems
                foreach ($u in $items) { $s.Selected[$u.Id] = $true }
            }
            'D' {
                $items = Get-CurrentItems
                foreach ($u in $items) { $s.Selected[$u.Id] = $false }
            }
            'R' { Update-MenuStatus }
            'U' { Invoke-Operation 'update-all' }

            'Enter' {
                if ($s.Focus -eq 'sidebar' -and $s.Section -eq 'profiles') {
                    if ($s.ProfileIndex -lt $s.Profiles.Count) {
                        Invoke-ProfileApply $s.Profiles[$s.ProfileIndex]
                        $s.Focus = 'items'
                    }
                } else {
                    $anySelected = $s.Selected.Values | Where-Object { $_ }
                    if ($anySelected) {
                        $allInstalled = $true
                        foreach ($cat in $s.Categories) {
                            foreach ($u in $s.ByCategory[$cat]) {
                                if ($s.Selected[$u.Id] -and -not $u['_Installed']) { $allInstalled = $false }
                            }
                        }
                        $op = if ($allInstalled) { 'uninstall' } else { 'install' }
                        Invoke-Operation $op
                    } else {
                        $s.StatusMessage = "Select items with [SPACE] first, or pick a Profile."
                        $s.StatusColor   = $FY
                    }
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
