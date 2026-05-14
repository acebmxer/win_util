#Requires -Version 5.1 # COMPILE:SKIP
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

# COMPILE:INSERT:LIBS

# COMPILE:SKIP:BEGIN
$ROOT = $PSScriptRoot
# COMPILE:SKIP:END

#region --- Bootstrap ---

function Show-Banner {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "     Windows Utilities Installer" -ForegroundColor White
    Write-Host "     Powered by winget  |  win_util v1.0" -ForegroundColor DarkGray
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host ""
}

# COMPILE:SKIP:BEGIN
# Dot-source at script scope so the lib functions are visible to the rest of the file.
# Wrapping these in a function would scope the definitions to that function and they would
# disappear on return, causing "Initialize-Logging not recognized" at the entry point.
. (Join-Path $ROOT "lib\logging.ps1")
. (Join-Path $ROOT "lib\utilities.ps1")
. (Join-Path $ROOT "lib\installers.ps1")
. (Join-Path $ROOT "lib\menu.ps1")
# COMPILE:SKIP:END

function Assert-Winget {
    if (-not (Test-WingetAvailable)) {
        Write-Host "  [ERROR] winget is not available on this system." -ForegroundColor Red
        Write-Host "  Install it from the Microsoft Store (App Installer) and try again." -ForegroundColor Red
        exit 1
    }
}

function New-DesktopShortcut {
    # Silently creates a "Win Util" desktop shortcut if one doesn't already exist.
    # Used so `irm .../win_util.ps1 | iex` self-installs on first run.
    $desktop      = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktop 'Win Util.lnk'
    if (Test-Path $shortcutPath) { return }

    try {
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $url   = 'https://raw.githubusercontent.com/acebmxer/win_util/main/dist/win_util.ps1'
        $cmd      = "& ([scriptblock]::Create((irm '$url')))"
        $psArgs   = "-NoExit -ExecutionPolicy Bypass -NoProfile -Command `"$cmd`""

        $shell    = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath       = $psExe
        $shortcut.Arguments        = $psArgs
        $shortcut.WorkingDirectory = $env:USERPROFILE
        $shortcut.IconLocation     = "$psExe,0"
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
