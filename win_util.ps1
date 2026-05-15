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
    [string] $ApplyProfile = "",
    [switch] $ListProfiles,
    [switch] $SysInfo,
    [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Self-elevation ---

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-ForwardArgs {
    # Reconstructs a CLI-style argument list from both bound named parameters
    # ($PSBoundParameters) and any unbound positional/double-dash args ($args).
    # Quotes values that contain whitespace so they survive the relaunch.
    param([hashtable]$Bound, [object[]]$Extra)

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($v -is [switch]) {
            if ($v.IsPresent) { $out.Add("-$k") }
        } else {
            $out.Add("-$k")
            $sv = "$v"
            if ($sv -match '\s') { $out.Add('"' + ($sv -replace '"','`"') + '"') }
            else                 { $out.Add($sv) }
        }
    }
    if ($Extra) {
        foreach ($a in $Extra) {
            $sa = "$a"
            if ($sa -match '\s') { $out.Add('"' + ($sa -replace '"','`"') + '"') }
            else                 { $out.Add($sa) }
        }
    }
    return $out.ToArray()
}

function Invoke-SelfElevate {
    # Relaunches the current script elevated. When invoked from a file on disk
    # (PSCommandPath set), relaunches that same file with the same args. When
    # invoked via `irm | iex` (no PSCommandPath), re-fetches the dist script in
    # the elevated process. Exits the current (non-elevated) process on success.
    param([string[]]$ForwardArgs)

    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) {
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    $fromFile = $PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)

    if ($fromFile) {
        $argList = @('-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath)
        if ($ForwardArgs) { $argList += $ForwardArgs }
    } else {
        # TrimStart strips the UTF-8 BOM (U+FEFF) that `irm` leaves at the start
        # of the response; without it PS 5.1's [scriptblock]::Create misparses
        # the script's param() defaults and errors out.
        $url = 'https://raw.githubusercontent.com/acebmxer/win_util/main/dist/win_util.ps1'
        $cmd = "& ([scriptblock]::Create((irm '$url').TrimStart([char]0xFEFF)))"
        $argList = @('-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-Command', $cmd)
    }

    try {
        Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "  [ERROR] Elevation was declined or failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  win_util needs administrator rights to install software via winget." -ForegroundColor Red
        Write-Host "  Right-click PowerShell and choose 'Run as administrator', then try again." -ForegroundColor Red
        exit 1
    }
    exit 0
}

if (-not (Test-IsAdmin)) {
    Write-Host ""
    Write-Host "  win_util requires administrator privileges. Relaunching elevated..." -ForegroundColor Yellow
    $fwd = Get-ForwardArgs -Bound $PSBoundParameters -Extra $args
    Invoke-SelfElevate -ForwardArgs $fwd
}

#endregion

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
. (Join-Path $ROOT "lib\sysinfo.ps1")
. (Join-Path $ROOT "lib\utilities.ps1")
. (Join-Path $ROOT "lib\installers.ps1")
. (Join-Path $ROOT "lib\wincleanup.ps1")
. (Join-Path $ROOT "lib\snapshots.ps1")
. (Join-Path $ROOT "lib\shares.ps1")
. (Join-Path $ROOT "lib\profiles.ps1")
. (Join-Path $ROOT "lib\menu.ps1")
# COMPILE:SKIP:END

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

function Set-ShortcutRunAsAdmin {
    # Flips bit 0x20 of the .lnk flags byte at offset 0x15 to mark the shortcut
    # as "Run as administrator". The WScript.Shell COM API doesn't expose this
    # property, so the .lnk has to be edited in place after Save().
    param([string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -gt 0x15 -and -not ($bytes[0x15] -band 0x20)) {
            $bytes[0x15] = $bytes[0x15] -bor 0x20
            [System.IO.File]::WriteAllBytes($Path, $bytes)
        }
    } catch {
        # Non-fatal: the shortcut still works, it just won't auto-elevate.
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
        $cmd      = "& ([scriptblock]::Create((irm '$url').TrimStart([char]0xFEFF)))"
        $psArgs   = "-NoExit -ExecutionPolicy Bypass -NoProfile -Command `"$cmd`""

        $shell = New-Object -ComObject WScript.Shell

        if (Test-Path $shortcutPath) {
            # Shortcut exists. Refresh its icon and Arguments so older shortcuts
            # pick up upstream fixes (e.g. the BOM-stripping TrimStart added to
            # the elevation command) without users having to recreate them.
            # Touching .Save() also bumps the .lnk's mtime so Explorer re-reads
            # the icon on next refresh.
            $existing = $shell.CreateShortcut($shortcutPath)
            $desired  = if ($iconLoc) { $iconLoc } else { "$psExe,0" }
            $changed  = $false
            if ($existing.IconLocation -ne $desired) {
                $existing.IconLocation = $desired
                $changed = $true
            }
            if ($existing.Arguments -ne $psArgs) {
                $existing.Arguments = $psArgs
                $changed = $true
            }
            if ($changed) { $existing.Save() }
            # Ensure pre-existing shortcuts (from older win_util versions) also
            # get the Run-as-admin flag so users don't have to recreate them.
            Set-ShortcutRunAsAdmin $shortcutPath
            return
        }

        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath       = $psExe
        $shortcut.Arguments        = $psArgs
        $shortcut.WorkingDirectory = $env:USERPROFILE
        $shortcut.IconLocation     = if ($iconLoc) { $iconLoc } else { "$psExe,0" }
        $shortcut.Description      = 'Windows Utilities Installer (win_util)'
        $shortcut.Save()
        Set-ShortcutRunAsAdmin $shortcutPath

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
    Write-Host "    .\win_util.ps1 --apply-profile [name]     Install every utility in a profile"
    Write-Host "    .\win_util.ps1 --list-profiles            List curated profiles"
    Write-Host "    .\win_util.ps1 --sys-info                 Print system details"
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

function Show-Profiles {
    Write-Host ""
    foreach ($p in Get-AllProfiles) {
        Write-Host ("  [{0}]" -f $p.Name) -ForegroundColor Yellow
        Write-Host ("    {0}" -f $p.Description) -ForegroundColor DarkGray
        foreach ($name in $p.Items) {
            Write-Host ("      - {0}" -f $name) -ForegroundColor White
        }
        Write-Host ""
    }
}

function Invoke-CLIApplyProfile {
    param([string]$Name)
    $p = Find-Profile $Name
    if (-not $p) { Write-Host "  Unknown profile: '$Name'" -ForegroundColor Red; exit 1 }
    Write-Host "  Applying profile '$($p.Name)'..." -ForegroundColor Cyan
    $resolved = Resolve-ProfileItems $p
    $ok = 0; $fail = 0
    foreach ($u in $resolved) {
        $fns       = Get-UtilityFunctions $u
        $installed = if ($fns.Test) { & $fns.Test } else { Test-WingetInstalled $u.Id }
        if ($installed) {
            Write-Host "  $($u.Name) already installed - skipping." -ForegroundColor DarkGray
            continue
        }
        Write-Host "  ===> Installing $($u.Name)" -ForegroundColor Cyan
        if ($fns.Install) { & $fns.Install } else { Invoke-WingetInstall $u.Id }
        if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail++ }
    }
    Write-Host ""
    Write-Host "  Profile complete.  Succeeded: $ok  Failed: $fail" -ForegroundColor White
}

function Show-SysInfo {
    $info = Get-SystemInfo
    Write-Host ""
    foreach ($k in $info.Keys) {
        Write-Host ("  {0,7}: {1}" -f $k, $info[$k]) -ForegroundColor White
    }
    Write-Host ""
}

#endregion

#region --- Entry Point ---

Initialize-Logging
Assert-Winget

if ($Help)         { Show-Banner; Show-Help;                          exit 0 }
if ($List)         { Show-Banner; Show-List;                          exit 0 }
if ($ListProfiles) { Show-Banner; Show-Profiles;                      exit 0 }
if ($SysInfo)      { Show-Banner; Show-SysInfo;                       exit 0 }
if ($Install)      { Show-Banner; Invoke-CLIInstall      $Install;    exit 0 }
if ($Uninstall)    { Show-Banner; Invoke-CLIUninstall    $Uninstall;  exit 0 }
if ($Update)       { Show-Banner; Invoke-CLIUpdate       $Update;     exit 0 }
if ($UpdateAll)    { Show-Banner; Invoke-CLIUpdateAll;                exit 0 }
if ($Check)        { Show-Banner; Invoke-CLICheck        $Check;      exit 0 }
if ($ApplyProfile) { Show-Banner; Invoke-CLIApplyProfile $ApplyProfile; exit 0 }

# Default: interactive menu
Show-Banner
New-DesktopShortcut
Write-Host "  Loading utilities..." -ForegroundColor DarkGray
$grouped = Get-UtilitiesByCategory
Start-Menu $grouped

#endregion
