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

#region --- sysinfo ---
# System information helpers for the menu sidebar.
#
# Get-SystemInfo returns a hashtable with short, sidebar-friendly strings:
#   Host, OS, Kernel, CPU, Mem, Disk, Uptime
# All lookups are wrapped in try/catch and default to "Unknown" so a missing
# WMI provider never blocks the menu from rendering.

function Format-Bytes {
    param([double]$Bytes, [int]$Digits = 1)
    if ($Bytes -ge 1TB) { return ("{0:N$Digits}T" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N$Digits}G" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N$Digits}M" -f ($Bytes / 1MB)) }
    return ("{0:N0}B" -f $Bytes)
}

function Get-SystemInfo {
    $info = [ordered]@{
        Host   = "Unknown"
        OS     = "Unknown"
        Kernel = "Unknown"
        CPU    = "Unknown"
        Mem    = "Unknown"
        Disk   = "Unknown"
        Uptime = "Unknown"
    }

    try { $info.Host = [Environment]::MachineName } catch {}

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $caption = ($os.Caption -replace '^Microsoft\s+', '').Trim()
        $info.OS     = $caption
        $info.Kernel = $os.Version
        try {
            $boot   = $os.LastBootUpTime
            $span   = (Get-Date) - $boot
            $info.Uptime = if ($span.Days -gt 0) {
                "{0}d {1}h" -f $span.Days, $span.Hours
            } elseif ($span.Hours -gt 0) {
                "{0}h {1}m" -f $span.Hours, $span.Minutes
            } else {
                "{0}m" -f $span.Minutes
            }
        } catch {}

        $totalBytes = [double]$os.TotalVisibleMemorySize * 1KB
        $freeBytes  = [double]$os.FreePhysicalMemory     * 1KB
        $usedBytes  = $totalBytes - $freeBytes
        $info.Mem   = "{0}/{1}" -f (Format-Bytes $usedBytes), (Format-Bytes $totalBytes)
    } catch {}

    try {
        $cpu  = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $name = $cpu.Name
        # Tidy common patterns to fit a narrow sidebar
        $name = $name -replace '\(R\)|\(TM\)', ''
        $name = $name -replace '\s+CPU\s+@.*$', ''
        $name = $name -replace 'Intel Core ', ''
        $name = $name -replace 'AMD Ryzen ', 'Ryzen '
        $info.CPU = $name.Trim()
    } catch {}

    try {
        $sysDrive = ($env:SystemDrive).TrimEnd(':')
        $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
        if ($vol) {
            $size = [double]$vol.Size
            $free = [double]$vol.FreeSpace
            $used = $size - $free
            $info.Disk = "{0}/{1} ({2}:)" -f (Format-Bytes $used), (Format-Bytes $size), $sysDrive
        }
    } catch {}

    return $info
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
    # winget aligns columns with single spaces when content fits tightly, so splitting
    # on >=2 spaces collapses Name+Id+Version into one field. Anchor on the Id token
    # and grab the next whitespace-separated token, which is always the version.
    $pattern = '\b' + [regex]::Escape($Id) + '\s+(\S+)'
    $lines = winget list --id $Id --exact --accept-source-agreements 2>&1
    foreach ($line in $lines) {
        if ($line -match $pattern) { return $Matches[1].Trim() }
    }
    return $null
}

# Single-shot bulk scan: one 'winget list' call returns every installed package.
# Build a map of Id -> Version so the menu can look up status without spawning a
# winget process per utility (which is the cause of the multi-minute startup).
# Returns $null if winget is unavailable or the output can't be parsed.
function Get-WingetInstalledMap {
    if (-not (Test-WingetAvailable)) { return $null }

    $lines = winget list --accept-source-agreements 2>&1 | ForEach-Object { [string]$_ }
    if (-not $lines) { return @{} }

    # Find the header row ("Name  Id  Version  ...") and the underline row beneath it.
    # Column boundaries come from the underline's run lengths; this is the same
    # trick used by other winget parsers and is resilient to localized headers.
    $headerIdx = -1
    for ($i = 0; $i -lt $lines.Count - 1; $i++) {
        if ($lines[$i + 1] -match '^-{3,}') { $headerIdx = $i; break }
    }
    if ($headerIdx -lt 0) { return @{} }

    $header = $lines[$headerIdx]

    # winget's underline is a single unbroken run of dashes, so we can't use it
    # to find column boundaries. Derive them from the header instead: each
    # column starts at a non-space character that follows whitespace.
    $cols = [System.Collections.Generic.List[hashtable]]::new()
    $inWord = $false
    $wordStart = 0
    $wordChars = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $header.Length; $i++) {
        $ch = $header[$i]
        if ($ch -ne ' ' -and -not $inWord) {
            $inWord = $true
            $wordStart = $i
            [void]$wordChars.Clear()
            [void]$wordChars.Append($ch)
        } elseif ($ch -ne ' ' -and $inWord) {
            [void]$wordChars.Append($ch)
        } elseif ($ch -eq ' ' -and $inWord) {
            $cols.Add(@{ Start = $wordStart; Name = $wordChars.ToString() })
            $inWord = $false
        }
    }
    if ($inWord) { $cols.Add(@{ Start = $wordStart; Name = $wordChars.ToString() }) }
    if ($cols.Count -lt 3) { return @{} }

    # Fill in Length for each column = (next column's Start) - this Start.
    # Last column extends to end of line.
    for ($c = 0; $c -lt $cols.Count - 1; $c++) {
        $cols[$c].Length = $cols[$c + 1].Start - $cols[$c].Start
    }
    $cols[$cols.Count - 1].Length = [int]::MaxValue

    $idCol  = -1
    $verCol = -1
    for ($c = 0; $c -lt $cols.Count; $c++) {
        if ($cols[$c].Name -ieq 'Id')      { $idCol  = $c }
        elseif ($cols[$c].Name -ieq 'Version') { $verCol = $c }
    }
    if ($idCol -lt 0 -or $verCol -lt 0) { return @{} }

    $map = @{}
    for ($r = $headerIdx + 2; $r -lt $lines.Count; $r++) {
        $row = $lines[$r]
        if ([string]::IsNullOrWhiteSpace($row)) { continue }
        # Skip progress / spinner / status lines that don't span all columns.
        if ($row.Length -lt $cols[$idCol].Start) { continue }

        $idStart = $cols[$idCol].Start
        $idLen   = [Math]::Min($cols[$idCol].Length, $row.Length - $idStart)
        if ($idLen -le 0) { continue }
        $id = $row.Substring($idStart, $idLen).Trim()
        if (-not $id) { continue }

        $verStart = $cols[$verCol].Start
        $version  = $null
        if ($row.Length -gt $verStart) {
            $verLen = [Math]::Min($cols[$verCol].Length, $row.Length - $verStart)
            if ($verLen -gt 0) { $version = $row.Substring($verStart, $verLen).Trim() }
        }

        $map[$id] = $version
    }
    return $map
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
# Utility registry -defines Register-Utility and standard winget wrappers

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

#region --- wincleanup ---
# WinCleanup -bundled disk cleanup script (vendored from
# https://github.com/acebmxer/wincleanup, author PozzaTech, MIT-equivalent
# permission granted by repo owner).
#
# Registered as a utility named "WinCleanup". Selecting it from the menu runs
# the cleanup inline in the (already-elevated) win_util session. There is no
# install/uninstall step and no on-disk artifact -Test-WinCleanup always
# reports "not installed" so Enter routes to the run action every time.

$script:WinCleanupBody = @'
#Requires -Version 5.1

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "===========================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "===========================================" -ForegroundColor Cyan
}

function Write-Status {
    param([string]$Message, [string]$Color = "White")
    Write-Host "  > $Message" -ForegroundColor $Color
}

function Remove-ItemsSafely {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Status "Cleaned: $Path" Green
        } catch {
            Write-Status "Partial clean (some files in use): $Path" Yellow
        }
    } else {
        Write-Status "Path not found, skipping: $Path" DarkGray
    }
}

# Run a long-running native command as a background job while showing a spinner
# and elapsed seconds, so the user can see work is happening. The Action
# scriptblock must end with `$LASTEXITCODE` so the job's last output is the
# exit code -that's what we read back. Used for DISM, which can take minutes.
function Invoke-WithSpinner {
    param(
        [string]$Label,
        [scriptblock]$Action
    )
    $start  = Get-Date
    $job    = Start-Job -ScriptBlock $Action
    $frames = @('|','/','-','\')
    $i = 0
    try {
        while ($job.State -eq 'Running') {
            $elapsed = (Get-Date) - $start
            $line = "  {0} {1}... {2:N0}:{3:D2} elapsed" -f $frames[$i % $frames.Length], $Label, [Math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds
            # \r to overwrite the same line; pad in case the prior line was longer.
            Write-Host ("`r" + $line.PadRight(78)) -NoNewline -ForegroundColor Cyan
            $i++
            Start-Sleep -Milliseconds 250
        }
    } finally {
        Write-Host ("`r" + (' ' * 80) + "`r") -NoNewline
    }
    $output = Receive-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    # Last numeric output from the job is the exit code (Action ends with $LASTEXITCODE).
    $exit = 0
    if ($output) {
        $last = @($output)[-1]
        if ($last -is [int]) { $exit = $last }
    }
    if ($job.State -eq 'Failed') { $exit = 1 }
    $total = (Get-Date) - $start
    Write-Status ("{0} finished in {1:N0}m {2:D2}s." -f $Label, [Math]::Floor($total.TotalMinutes), $total.Seconds) DarkGray
    return $exit
}

$script:OverallStart = Get-Date
function Get-Elapsed {
    $e = (Get-Date) - $script:OverallStart
    return ("{0:N0}:{1:D2}" -f [Math]::Floor($e.TotalMinutes), $e.Seconds)
}

Write-Host ""
Write-Host "  WinCleanup  |  PozzaTech (vendored in win_util)" -ForegroundColor White
Write-Host "  Running as: $env:USERNAME on $env:COMPUTERNAME" -ForegroundColor DarkGray
Write-Host "  Started at: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor DarkGray
Write-Host ""

Write-Section "[1/6 | $(Get-Elapsed)] DISM Health Check"
Write-Status "Checking Windows image health before cleanup..."
$dismExit = Invoke-WithSpinner -Label "DISM /checkhealth" -Action {
    dism /online /cleanup-image /checkhealth | Out-Null
    $LASTEXITCODE
}
if ($dismExit -eq 0) {
    Write-Status "Image is healthy. Proceeding." Green
} else {
    Write-Status "DISM health check returned warnings - continuing anyway." Yellow
}

Write-Section "[2/6 | $(Get-Elapsed)] Windows Update / Component Store Cleanup"
Write-Status "Running DISM component cleanup with /resetbase..." Yellow
Write-Status "This is the long step -typically 1-5 minutes." DarkGray

$dismExit = Invoke-WithSpinner -Label "DISM /startcomponentcleanup /resetbase" -Action {
    dism /online /cleanup-image /startcomponentcleanup /resetbase | Out-Null
    $LASTEXITCODE
}

if ($dismExit -eq 0) {
    Write-Status "Component store cleanup completed successfully." Green
} else {
    Write-Status "DISM returned exit code $dismExit - check Event Viewer if issues arise." Yellow
}

Write-Section "[3/6 | $(Get-Elapsed)] Temp File Cleanup"
Remove-ItemsSafely -Path $env:TEMP
Remove-ItemsSafely -Path "C:\Windows\Temp"
Remove-ItemsSafely -Path "C:\Windows\Prefetch"

Write-Section "[4/6 | $(Get-Elapsed)] Delivery Optimization Cache"
Write-Status "Clearing Delivery Optimization cache..."
$doCmd = Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue
if ($doCmd) {
    try {
        & $doCmd -Force -ErrorAction Stop
        Write-Status "Delivery Optimization cache cleared." Green
    } catch {
        Remove-ItemsSafely -Path "C:\Windows\SoftwareDistribution\DeliveryOptimization"
    }
} else {
    Remove-ItemsSafely -Path "C:\Windows\SoftwareDistribution\DeliveryOptimization"
}

Write-Status "Stopping Windows Update service to clear download cache..."
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Remove-ItemsSafely -Path "C:\Windows\SoftwareDistribution\Download"
Start-Service -Name wuauserv -ErrorAction SilentlyContinue
Write-Status "Windows Update service restarted." Green

Write-Section "[5/6 | $(Get-Elapsed)] Hibernation File (hiberfil.sys)"
# Defensive read: on some systems (esp. desktops without hibernate hardware)
# the HibernateEnabled value is missing entirely, which used to crash with
# "property cannot be found on this object". Treat missing/unreadable as "off".
$hibernateEnabled = 0
try {
    $hibernateEnabled = Get-ItemPropertyValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name HibernateEnabled -ErrorAction Stop
} catch {
    $hibernateEnabled = 0
}
if ($hibernateEnabled -eq 1) {
    Write-Host ""
    Write-Host "  Hibernation is currently ENABLED." -ForegroundColor Yellow
    Write-Host "  Disabling it will delete hiberfil.sys and free ~12+ GiB." -ForegroundColor Yellow
    Write-Host "  Sleep/restart are NOT affected - only hibernate (Shut down > Hibernate)." -ForegroundColor DarkGray
    Write-Host ""
    $confirm = Read-Host "  Disable hibernation and reclaim disk space? (Y/N)"
    if ($confirm -match "^[Yy]$") {
        powercfg /hibernate off
        Write-Status "Hibernation disabled. hiberfil.sys removed." Green
    } else {
        Write-Status "Skipped - hibernation left enabled." DarkGray
    }
} else {
    Write-Status "Hibernation is already disabled. No action needed." DarkGray
}

Write-Section "[6/6 | $(Get-Elapsed)] Shadow Copy Storage (System Restore)"
$vssadmin = "$env:SystemRoot\System32\vssadmin.exe"
if (-not (Test-Path $vssadmin)) {
    Write-Status "vssadmin.exe not available on this system - skipping shadow copy management." Yellow
} else {
    Write-Status "Current shadow storage allocation:"
    $shadowOutput = & $vssadmin list shadowstorage 2>&1
    $shadowLines  = $shadowOutput | Where-Object { $_ -match "Maximum|Used|Allocated" }
    if (-not $shadowLines) {
        Write-Status "No shadow storage configured for this volume - System Restore may be disabled." DarkGray
    } else {
        $shadowLines | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host ""
        Write-Host "  Recommend capping shadow storage at 5 GiB to limit growth." -ForegroundColor Yellow
        $confirmVss = Read-Host "  Set maximum shadow copy storage to 5 GiB? (Y/N)"
        if ($confirmVss -match "^[Yy]$") {
            & $vssadmin resize shadowstorage /for=C: /on=C: /maxsize=5GB
            Write-Status "Shadow copy storage capped at 5 GiB." Green
        } else {
            Write-Status "Skipped - shadow copy storage unchanged." DarkGray
        }
    }
}

Write-Section "[Bonus | $(Get-Elapsed)] Windows Disk Cleanup (cleanmgr)"
Write-Host ""
Write-Host "  Launching Disk Cleanup with all categories pre-selected." -ForegroundColor White
Write-Host "  Review selections and click OK to proceed." -ForegroundColor DarkGray
Write-Host ""
$cleanmgrKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
Get-ChildItem $cleanmgrKey | ForEach-Object {
    Set-ItemProperty -Path $_.PSPath -Name StateFlags0001 -Value 2 -Type DWord -ErrorAction SilentlyContinue
}
$cleanmgrStart = Get-Date
$cleanmgrProc  = Start-Process -FilePath cleanmgr -ArgumentList "/sagerun:1" -PassThru
$frames = @('|','/','-','\')
$i = 0
while (-not $cleanmgrProc.HasExited) {
    $e = (Get-Date) - $cleanmgrStart
    $line = "  {0} Waiting for cleanmgr... {1:N0}:{2:D2} elapsed (interact with the cleanmgr window)" -f $frames[$i % $frames.Length], [Math]::Floor($e.TotalMinutes), $e.Seconds
    Write-Host ("`r" + $line.PadRight(78)) -NoNewline -ForegroundColor Cyan
    Start-Sleep -Milliseconds 300
    $i++
}
Write-Host ("`r" + (' ' * 80) + "`r") -NoNewline
Write-Status "Disk Cleanup completed." Green

$totalElapsed = (Get-Date) - $script:OverallStart
Write-Host ""
Write-Host "===========================================" -ForegroundColor Green
Write-Host "  Cleanup Complete!" -ForegroundColor Green
Write-Host ("  Total time: {0:N0}m {1:D2}s" -f [Math]::Floor($totalElapsed.TotalMinutes), $totalElapsed.Seconds) -ForegroundColor Green
Write-Host "===========================================" -ForegroundColor Green
Write-Host ""
'@

function Invoke-WinCleanup {
    try {
        # Run the body in a fresh scriptblock scope so its helper functions
        # (Write-Section, Write-Status, Remove-ItemsSafely) don't leak into
        # the menu session.
        $sb = [scriptblock]::Create($script:WinCleanupBody)
        & $sb
        $global:LASTEXITCODE = 0
    } catch {
        Write-Host "  WinCleanup failed: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
    }
}

# Menu plumbing: the Enter handler picks 'install' when an item is not
# installed, so Test always reports false and Install does the run.
function Install-WinCleanup   { Invoke-WinCleanup }
function Update-WinCleanup    { Invoke-WinCleanup }
function Uninstall-WinCleanup { Invoke-WinCleanup }
function Test-WinCleanup      { return $false }

# One-shot upgrade cleanup: earlier versions dropped a script at
# %LOCALAPPDATA%\win_util\WinCleanup and a Start Menu shortcut. The new model
# runs inline with no on-disk artifacts, so remove the stragglers silently.
$legacyDir   = Join-Path $env:LOCALAPPDATA 'win_util\WinCleanup'
$legacyShort = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\WinCleanup.lnk'
if (Test-Path $legacyShort) { Remove-Item $legacyShort -Force -ErrorAction SilentlyContinue }
if (Test-Path $legacyDir)   { Remove-Item $legacyDir -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Variable legacyDir, legacyShort -ErrorAction SilentlyContinue
#endregion

#region --- snapshots ---
# Snapshot / restore-point / backup actions backed by built-in Windows tooling.
#
# Each Install-* function below runs an inline action and never produces an
# on-disk artifact, so the matching Test-* always returns $false -the menu
# routes Enter to "install" (i.e. run) every time. Same pattern as WinCleanup.
#
# Utility mapping (also stated in each item's Description so it's visible in
# the menu's description pane):
#
#   Create Restore Point      -> Checkpoint-Computer  (System Restore / VSS)
#   List Restore Points       -> Get-ComputerRestorePoint
#   Open System Protection    -> SystemPropertiesProtection.exe
#   Create Shadow Copy        -> Win32_ShadowCopy::Create  (VSS, WMI)
#   List Shadow Copies        -> vssadmin list shadows
#   Delete Oldest Shadow Copy -> vssadmin delete shadows /oldest
#   Open File History         -> control /name Microsoft.FileHistory
#   Run File History Backup   -> FhManagew.exe -fullbackup
#   System Image Backup       -> wbadmin start backup
#   List wbadmin Backups      -> wbadmin get versions

#region --- System Restore (Checkpoint-Computer) ---

function Invoke-CreateRestorePoint {
    # System Restore caps creation to once every 24h by default. Bump the
    # frequency to 0 for this session so back-to-back runs aren't silently
    # discarded. Registry value is read at point creation, not at boot.
    try {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name 'SystemRestorePointCreationFrequency' `
            -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null

        # System Restore must be enabled on the system drive for Checkpoint-Computer
        # to do anything. Enable-ComputerRestore is idempotent.
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue

        $desc = "win_util manual checkpoint $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Host "  [Checkpoint-Computer] Creating restore point: $desc" -ForegroundColor Cyan
        Checkpoint-Computer -Description $desc -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Host "  Restore point created." -ForegroundColor Green
        $global:LASTEXITCODE = 0
    } catch {
        Write-Host "  Failed to create restore point: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Tip: enable System Protection in SystemPropertiesProtection first." -ForegroundColor DarkYellow
        $global:LASTEXITCODE = 1
    }
}

function Invoke-ListRestorePoints {
    try {
        Write-Host "  [Get-ComputerRestorePoint] System Restore points:" -ForegroundColor Cyan
        $points = Get-ComputerRestorePoint -ErrorAction Stop
        if (-not $points) {
            Write-Host "  No restore points found." -ForegroundColor Yellow
        } else {
            $points | Format-Table SequenceNumber, `
                @{ N='Created'; E={ $_.ConvertToDateTime($_.CreationTime) } }, `
                Description, RestorePointType -AutoSize
        }
        $global:LASTEXITCODE = 0
    } catch {
        Write-Host "  Failed to list restore points: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Tip: System Protection may be disabled on this drive." -ForegroundColor DarkYellow
        $global:LASTEXITCODE = 1
    }
}

function Invoke-OpenSystemProtection {
    try {
        Write-Host "  [SystemPropertiesProtection.exe] Opening System Protection dialog..." -ForegroundColor Cyan
        Start-Process -FilePath 'SystemPropertiesProtection.exe' -ErrorAction Stop
        $global:LASTEXITCODE = 0
    } catch {
        Write-Host "  Could not open System Protection: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
    }
}

#endregion

#region --- Volume Shadow Copy Service (vssadmin / WMI) ---

function Invoke-CreateShadowCopy {
    # vssadmin create shadow only works on Windows Server SKUs. On client
    # Windows, use the WMI Win32_ShadowCopy::Create method, which is the
    # documented workaround and works on Win10/11 Pro and up. Persistent
    # shadows on client SKUs are still subject to the usual cleanup rules
    # (max-size, age), so this is closer to a manual VSS snapshot than a
    # snapper-style retention chain.
    Write-Host "  [Win32_ShadowCopy::Create]  VSS shadow copy" -ForegroundColor Cyan
    $drive = Read-Host "  Volume to snapshot (e.g. C:) [default: $env:SystemDrive]"
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = $env:SystemDrive }
    if ($drive -notmatch ':$') { $drive = $drive.TrimEnd('\') + ':' }

    try {
        $shadow = (Get-WmiObject -List Win32_ShadowCopy).Create("$drive\", 'ClientAccessible')
        if ($shadow.ReturnValue -eq 0) {
            Write-Host "  Shadow copy created. ShadowID: $($shadow.ShadowID)" -ForegroundColor Green
            $global:LASTEXITCODE = 0
        } else {
            # Common return codes: 1=access denied, 2=invalid argument, 3=volume not supported,
            # 5=unsupported shadow copy context, 12=volume not found.
            Write-Host "  Win32_ShadowCopy::Create returned $($shadow.ReturnValue) (non-zero = failure)." -ForegroundColor Red
            $global:LASTEXITCODE = $shadow.ReturnValue
        }
    } catch {
        Write-Host "  Failed: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
    }
}

function Invoke-ListShadowCopies {
    try {
        Write-Host "  [vssadmin list shadows]" -ForegroundColor Cyan
        & vssadmin list shadows
        $global:LASTEXITCODE = $LASTEXITCODE
    } catch {
        Write-Host "  vssadmin failed: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
    }
}

function Invoke-DeleteOldestShadowCopy {
    Write-Host "  [vssadmin delete shadows /oldest]  Delete the oldest shadow copy" -ForegroundColor Cyan
    $drive = Read-Host "  Volume (e.g. C:) [default: $env:SystemDrive]"
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = $env:SystemDrive }
    if ($drive -notmatch ':$') { $drive = $drive.TrimEnd('\') + ':' }

    try {
        & vssadmin delete shadows /for=$drive /oldest /quiet
        $global:LASTEXITCODE = $LASTEXITCODE
    } catch {
        Write-Host "  vssadmin failed: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
    }
}

#endregion

#region --- File History (FhManagew / control panel) ---

function Invoke-OpenFileHistory {
    # File History's modern Settings page was removed in Win11; the classic
    # Control Panel applet is still the supported way to configure it.
    try {
        Write-Host "  [control /name Microsoft.FileHistory] Opening File History..." -ForegroundColor Cyan
        Start-Process -FilePath 'control.exe' -ArgumentList '/name','Microsoft.FileHistory' -ErrorAction Stop
        $global:LASTEXITCODE = 0
    } catch {
        Write-Host "  Could not open File History: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
    }
}

function Invoke-RunFileHistoryBackup {
    # FhManagew.exe -fullbackup forces an immediate File History run. Requires
    # File History to already be configured with a target drive.
    try {
        Write-Host "  [FhManagew.exe -fullbackup] Triggering File History backup now..." -ForegroundColor Cyan
        & FhManagew.exe -fullbackup
        $global:LASTEXITCODE = $LASTEXITCODE
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  FhManagew exited $LASTEXITCODE (configure File History target first if it's never been set up)." -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "  FhManagew failed: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
    }
}

#endregion

#region --- wbadmin (Windows Backup) ---

function Invoke-WbadminSystemImage {
    # wbadmin start backup creates a full system image. Requires a separate
    # target volume (cannot be a source volume). -quiet suppresses confirmation.
    Write-Host "  [wbadmin start backup]  Full system image backup" -ForegroundColor Cyan
    Write-Host "  Note: target must be a separate local drive (e.g. E:) or a UNC share." -ForegroundColor DarkGray
    $target = Read-Host "  Backup target (e.g. E: or \\server\share)"
    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Host "  No target provided, aborting." -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        return
    }

    try {
        & wbadmin start backup -backupTarget:$target -include:"$env:SystemDrive" -allCritical -quiet
        $global:LASTEXITCODE = $LASTEXITCODE
    } catch {
        Write-Host "  wbadmin failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Tip: 'Windows Server Backup' / 'Windows Backup' feature must be installed." -ForegroundColor DarkYellow
        $global:LASTEXITCODE = 1
    }
}

function Invoke-WbadminListBackups {
    try {
        Write-Host "  [wbadmin get versions]" -ForegroundColor Cyan
        & wbadmin get versions
        $global:LASTEXITCODE = $LASTEXITCODE
    } catch {
        Write-Host "  wbadmin failed: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
    }
}

#endregion

#region --- Menu plumbing ---

# Action-type utilities re-use install/uninstall/update slots. Test always
# returns $false so Enter routes to Install (= run the action).

function Install-CreateRestorePoint     { Invoke-CreateRestorePoint }
function Update-CreateRestorePoint      { Invoke-CreateRestorePoint }
function Uninstall-CreateRestorePoint   { Invoke-CreateRestorePoint }
function Test-CreateRestorePoint        { return $false }

function Install-ListRestorePoints      { Invoke-ListRestorePoints }
function Update-ListRestorePoints       { Invoke-ListRestorePoints }
function Uninstall-ListRestorePoints    { Invoke-ListRestorePoints }
function Test-ListRestorePoints         { return $false }

function Install-OpenSystemProtection   { Invoke-OpenSystemProtection }
function Update-OpenSystemProtection    { Invoke-OpenSystemProtection }
function Uninstall-OpenSystemProtection { Invoke-OpenSystemProtection }
function Test-OpenSystemProtection      { return $false }

# Function names below must match the Utility.Name with non-alphanumerics
# stripped (see Get-UtilityFunctions in installers.ps1). e.g. the menu entry
# named "Create Shadow Copy (VSS)" resolves to safeName "CreateShadowCopyVSS",
# so the handlers must be Install-CreateShadowCopyVSS / Test-... / etc.
function Install-CreateShadowCopyVSS    { Invoke-CreateShadowCopy }
function Update-CreateShadowCopyVSS     { Invoke-CreateShadowCopy }
function Uninstall-CreateShadowCopyVSS  { Invoke-CreateShadowCopy }
function Test-CreateShadowCopyVSS       { return $false }

function Install-ListShadowCopiesVSS    { Invoke-ListShadowCopies }
function Update-ListShadowCopiesVSS     { Invoke-ListShadowCopies }
function Uninstall-ListShadowCopiesVSS  { Invoke-ListShadowCopies }
function Test-ListShadowCopiesVSS       { return $false }

function Install-DeleteOldestShadowVSS    { Invoke-DeleteOldestShadowCopy }
function Update-DeleteOldestShadowVSS     { Invoke-DeleteOldestShadowCopy }
function Uninstall-DeleteOldestShadowVSS  { Invoke-DeleteOldestShadowCopy }
function Test-DeleteOldestShadowVSS       { return $false }

function Install-OpenFileHistory        { Invoke-OpenFileHistory }
function Update-OpenFileHistory         { Invoke-OpenFileHistory }
function Uninstall-OpenFileHistory      { Invoke-OpenFileHistory }
function Test-OpenFileHistory           { return $false }

function Install-RunFileHistoryBackup   { Invoke-RunFileHistoryBackup }
function Update-RunFileHistoryBackup    { Invoke-RunFileHistoryBackup }
function Uninstall-RunFileHistoryBackup { Invoke-RunFileHistoryBackup }
function Test-RunFileHistoryBackup      { return $false }

function Install-SystemImageBackup      { Invoke-WbadminSystemImage }
function Update-SystemImageBackup       { Invoke-WbadminSystemImage }
function Uninstall-SystemImageBackup    { Invoke-WbadminSystemImage }
function Test-SystemImageBackup         { return $false }

function Install-ListwbadminBackups     { Invoke-WbadminListBackups }
function Update-ListwbadminBackups      { Invoke-WbadminListBackups }
function Uninstall-ListwbadminBackups   { Invoke-WbadminListBackups }
function Test-ListwbadminBackups        { return $false }

#endregion
#endregion

#region --- utilities-list ---
# All registered utilities -add a Register-Utility line to add a new tool.
# Custom install/uninstall/update/test logic: define Install-SafeName, etc. anywhere in the loaded files.
#
# Fields: Name, Id (winget package id), Category, Description (one-line)

# ── Browsers ──────────────────────────────────────────────────────────────
Register-Utility @{ Name = "Google Chrome";            Id = "Google.Chrome";                          Category = "Browsers";    Description = "Google's browser with sync and developer tools" }
Register-Utility @{ Name = "Mozilla Firefox";          Id = "Mozilla.Firefox";                        Category = "Browsers";    Description = "Mozilla's open-source browser" }
Register-Utility @{ Name = "Microsoft Edge";           Id = "Microsoft.Edge";                         Category = "Browsers";    Description = "Microsoft's Chromium-based browser" }
Register-Utility @{ Name = "Brave Browser";            Id = "Brave.Brave";                            Category = "Browsers";    Description = "Privacy-focused Chromium browser with built-in ad blocking" }
Register-Utility @{ Name = "Vivaldi";                  Id = "Vivaldi.Vivaldi";                        Category = "Browsers";    Description = "Highly customizable Chromium browser" }
Register-Utility @{ Name = "LibreWolf";                Id = "LibreWolf.LibreWolf";                    Category = "Browsers";    Description = "Privacy-hardened Firefox fork" }
Register-Utility @{ Name = "Tor Browser";              Id = "TorProject.TorBrowser";                  Category = "Browsers";    Description = "Anonymous browsing via the Tor network" }

# ── Development ───────────────────────────────────────────────────────────
Register-Utility @{ Name = "Visual Studio Code";       Id = "Microsoft.VisualStudioCode";             Category = "Development"; Description = "Microsoft's extensible code editor" }
Register-Utility @{ Name = "Cursor";                   Id = "Anysphere.Cursor";                       Category = "Development"; Description = "AI-powered code editor built on VS Code" }
Register-Utility @{ Name = "Git";                      Id = "Git.Git";                                Category = "Development"; Description = "Distributed version control system" }
Register-Utility @{ Name = "GitHub CLI";               Id = "GitHub.cli";                             Category = "Development"; Description = "Official CLI for GitHub -repos, issues, PRs, workflows" }
Register-Utility @{ Name = "GitHub Desktop";           Id = "GitHub.GitHubDesktop";                   Category = "Development"; Description = "GUI client for managing GitHub repositories" }
Register-Utility @{ Name = "Docker Desktop";           Id = "Docker.DockerDesktop";                   Category = "Development"; Description = "Container platform for Windows with WSL2 backend" }
Register-Utility @{ Name = "Node.js LTS";              Id = "OpenJS.NodeJS.LTS";                      Category = "Development"; Description = "JavaScript runtime -LTS release" }
Register-Utility @{ Name = "Python 3";                 Id = "Python.Python.3.12";                     Category = "Development"; Description = "Python programming language runtime" }
Register-Utility @{ Name = "Go SDK";                   Id = "GoLang.Go";                              Category = "Development"; Description = "Official Go programming language toolchain" }
Register-Utility @{ Name = "Rustup";                   Id = "Rustlang.Rustup";                        Category = "Development"; Description = "Rust toolchain installer and version manager" }
Register-Utility @{ Name = "Neovim";                   Id = "Neovim.Neovim";                          Category = "Development"; Description = "Extensible Vim-based text editor" }
Register-Utility @{ Name = "Windows Terminal";         Id = "Microsoft.WindowsTerminal";              Category = "Development"; Description = "Modern terminal emulator with tabs and profiles" }
Register-Utility @{ Name = "PowerShell 7";             Id = "Microsoft.PowerShell";                   Category = "Development"; Description = "Cross-platform PowerShell (pwsh)" }
Register-Utility @{ Name = "DBeaver";                  Id = "dbeaver.dbeaver";                        Category = "Development"; Description = "Universal database management tool" }
Register-Utility @{ Name = "Postman";                  Id = "Postman.Postman";                        Category = "Development"; Description = "API development and testing platform" }
Register-Utility @{ Name = "JetBrains Toolbox";        Id = "JetBrains.Toolbox";                      Category = "Development"; Description = "Manager for JetBrains IDEs" }

# ── Internet / Communication ──────────────────────────────────────────────
Register-Utility @{ Name = "Discord";                  Id = "Discord.Discord";                        Category = "Internet";    Description = "Voice, video, and text communication platform" }
Register-Utility @{ Name = "Slack";                    Id = "SlackTechnologies.Slack";                Category = "Internet";    Description = "Team messaging and collaboration platform" }
Register-Utility @{ Name = "Microsoft Teams";          Id = "Microsoft.Teams";                        Category = "Internet";    Description = "Workplace chat, meetings, and collaboration" }
Register-Utility @{ Name = "Zoom";                     Id = "Zoom.Zoom";                              Category = "Internet";    Description = "Video conferencing and collaboration platform" }
Register-Utility @{ Name = "Signal";                   Id = "OpenWhisperSystems.Signal";              Category = "Internet";    Description = "End-to-end encrypted messaging" }
Register-Utility @{ Name = "Telegram";                 Id = "Telegram.TelegramDesktop";               Category = "Internet";    Description = "Cloud-based messaging with groups and channels" }
Register-Utility @{ Name = "Thunderbird";              Id = "Mozilla.Thunderbird";                    Category = "Internet";    Description = "Mozilla's email client with calendar and PGP" }
Register-Utility @{ Name = "FileZilla";                Id = "TimKosse.FileZilla.Client";              Category = "Internet";    Description = "FTP, FTPS, and SFTP client" }
Register-Utility @{ Name = "qBittorrent";              Id = "qBittorrent.qBittorrent";                Category = "Internet";    Description = "Open-source BitTorrent client" }
Register-Utility @{ Name = "ProtonVPN";                Id = "Proton.ProtonVPN";                       Category = "Internet";    Description = "Free and open-source VPN by Proton" }
Register-Utility @{ Name = "Tailscale";                Id = "tailscale.tailscale";                    Category = "Internet";    Description = "Zero-config mesh VPN built on WireGuard" }
Register-Utility @{ Name = "AnyDesk";                  Id = "AnyDeskSoftwareGmbH.AnyDesk";            Category = "Internet";    Description = "Remote desktop application" }
Register-Utility @{ Name = "RustDesk";                 Id = "RustDesk.RustDesk";                      Category = "Internet";    Description = "Open-source remote desktop and remote assistance tool" }

# ── Media ─────────────────────────────────────────────────────────────────
Register-Utility @{ Name = "VLC Media Player";         Id = "VideoLAN.VLC";                           Category = "Media";       Description = "Versatile media player supporting virtually all formats" }
Register-Utility @{ Name = "Spotify";                  Id = "Spotify.Spotify";                        Category = "Media";       Description = "Music streaming service" }
Register-Utility @{ Name = "OBS Studio";               Id = "OBSProject.OBSStudio";                   Category = "Media";       Description = "Video recording and live streaming" }
Register-Utility @{ Name = "Audacity";                 Id = "Audacity.Audacity";                      Category = "Media";       Description = "Open-source audio editor and recorder" }
Register-Utility @{ Name = "HandBrake";                Id = "HandBrake.HandBrake";                    Category = "Media";       Description = "Open-source video transcoder" }
Register-Utility @{ Name = "GIMP";                     Id = "GIMP.GIMP";                              Category = "Media";       Description = "GNU Image Manipulation Program" }
Register-Utility @{ Name = "Inkscape";                 Id = "Inkscape.Inkscape";                      Category = "Media";       Description = "Professional vector graphics editor" }
Register-Utility @{ Name = "Krita";                    Id = "KDE.Krita";                              Category = "Media";       Description = "Professional digital painting application" }
Register-Utility @{ Name = "Blender";                  Id = "BlenderFoundation.Blender";              Category = "Media";       Description = "Open-source 3D creation suite" }

# ── Productivity ──────────────────────────────────────────────────────────
Register-Utility @{ Name = "LibreOffice";              Id = "TheDocumentFoundation.LibreOffice";      Category = "Productivity"; Description = "Open-source office suite" }
Register-Utility @{ Name = "OnlyOffice";               Id = "ONLYOFFICE.DesktopEditors";              Category = "Productivity"; Description = "Office suite with MS Office format compatibility" }
Register-Utility @{ Name = "Notepad++";                Id = "Notepad++.Notepad++";                    Category = "Productivity"; Description = "Source-code editor with syntax highlighting" }
Register-Utility @{ Name = "Obsidian";                 Id = "Obsidian.Obsidian";                      Category = "Productivity"; Description = "Markdown-based knowledge base with graphs and plugins" }
Register-Utility @{ Name = "Joplin";                   Id = "Joplin.Joplin";                          Category = "Productivity"; Description = "Note-taking app with Markdown and sync" }
Register-Utility @{ Name = "Logseq";                   Id = "Logseq.Logseq";                          Category = "Productivity"; Description = "Privacy-first knowledge management and outliner" }
Register-Utility @{ Name = "Bitwarden";                Id = "Bitwarden.Bitwarden";                    Category = "Productivity"; Description = "Open-source password manager" }
Register-Utility @{ Name = "Nextcloud Desktop";        Id = "Nextcloud.NextcloudDesktop";             Category = "Productivity"; Description = "Sync client for self-hosted Nextcloud storage" }
Register-Utility @{ Name = "ShareX";                   Id = "ShareX.ShareX";                          Category = "Productivity"; Description = "Screenshot and screen recording tool" }

# ── Gaming ────────────────────────────────────────────────────────────────
Register-Utility @{ Name = "Steam";                    Id = "Valve.Steam";                            Category = "Gaming";      Description = "Valve's gaming platform" }
Register-Utility @{ Name = "Epic Games Launcher";      Id = "EpicGames.EpicGamesLauncher";            Category = "Gaming";      Description = "Epic Games store and launcher" }
Register-Utility @{ Name = "GOG Galaxy";               Id = "GOG.Galaxy";                             Category = "Gaming";      Description = "GOG.com client and unified game library" }
Register-Utility @{ Name = "Heroic Games Launcher";    Id = "HeroicGamesLauncher.HeroicGamesLauncher"; Category = "Gaming";     Description = "Open-source launcher for Epic, GOG, and Amazon Prime Gaming" }
Register-Utility @{ Name = "Ubisoft Connect";          Id = "Ubisoft.Connect";                        Category = "Gaming";      Description = "Ubisoft's game launcher and store" }
Register-Utility @{ Name = "Battle.net";               Id = "Blizzard.BattleNet";                     Category = "Gaming";      Description = "Blizzard's game launcher and store" }

# ── System Tools ──────────────────────────────────────────────────────────
Register-Utility @{ Name = "7-Zip";                    Id = "7zip.7zip";                              Category = "System Tools"; Description = "File archiver with high compression ratio" }
Register-Utility @{ Name = "WinRAR";                   Id = "RARLab.WinRAR";                          Category = "System Tools"; Description = "Archive manager for RAR and ZIP files" }
Register-Utility @{ Name = "PowerToys";                Id = "Microsoft.PowerToys";                    Category = "System Tools"; Description = "Microsoft's productivity utilities (FancyZones, PowerRename, etc.)" }
Register-Utility @{ Name = "Sysinternals Suite";       Id = "Microsoft.Sysinternals.Suite";           Category = "System Tools"; Description = "Microsoft's collection of Windows diagnostic utilities" }
Register-Utility @{ Name = "Everything";               Id = "voidtools.Everything";                   Category = "System Tools"; Description = "Instant file and folder search by name" }
Register-Utility @{ Name = "CPU-Z";                    Id = "CPUID.CPU-Z";                            Category = "System Tools"; Description = "CPU, memory, and motherboard information utility" }
Register-Utility @{ Name = "GPU-Z";                    Id = "TechPowerUp.GPU-Z";                      Category = "System Tools"; Description = "GPU information and monitoring utility" }
Register-Utility @{ Name = "HWiNFO";                   Id = "REALiX.HWiNFO";                          Category = "System Tools"; Description = "Comprehensive hardware analysis and monitoring" }

# ── Disk Utilities ────────────────────────────────────────────────────────
Register-Utility @{ Name = "WizTree";                  Id = "AntibodySoftware.WizTree";               Category = "Disk Utilities"; Description = "Fast disk space analyzer reading the MFT directly" }
Register-Utility @{ Name = "WinDirStat";               Id = "WinDirStat.WinDirStat";                  Category = "Disk Utilities"; Description = "Disk usage statistics and cleanup tool" }
Register-Utility @{ Name = "WinCleanup";               Id = "PozzaTech.WinCleanup";                   Category = "Disk Utilities"; Action = $true; Description = "Bundled cleanup script -DISM, temp files, hibernation, shadow copies (PozzaTech)" }

# ── Bootable Media ────────────────────────────────────────────────────────
Register-Utility @{ Name = "Rufus";                    Id = "Rufus.Rufus";                            Category = "Bootable Media"; Description = "Create bootable USB drives from ISOs" }
Register-Utility @{ Name = "Ventoy";                   Id = "Ventoy.Ventoy";                          Category = "Bootable Media"; Description = "Bootable USB tool -boot multiple ISOs from one drive" }

# ── Snapshots & Backup ────────────────────────────────────────────────────
# Built-in action entries (no install) wrapping native Windows snapshot/backup
# tools. Each description names the underlying utility so it's visible in the
# menu's description pane. Veeam is the third-party image-backup pick.
#
# System Restore (Checkpoint-Computer / VSS):
Register-Utility @{ Name = "Create Restore Point";       Id = "WinUtil.CreateRestorePoint";       Category = "Snapshots & Backup"; Action = $true; Description = "System Restore: create a checkpoint via Checkpoint-Computer (built-in)" }
Register-Utility @{ Name = "List Restore Points";        Id = "WinUtil.ListRestorePoints";        Category = "Snapshots & Backup"; Action = $true; Description = "System Restore: list checkpoints via Get-ComputerRestorePoint (built-in)" }
Register-Utility @{ Name = "Open System Protection";     Id = "WinUtil.OpenSystemProtection";     Category = "Snapshots & Backup"; Action = $true; Description = "Launches SystemPropertiesProtection.exe to enable/configure System Restore" }
# Volume Shadow Copy Service (vssadmin / WMI):
Register-Utility @{ Name = "Create Shadow Copy (VSS)";   Id = "WinUtil.CreateShadowCopy";         Category = "Snapshots & Backup"; Action = $true; Description = "VSS: create a shadow copy via Win32_ShadowCopy::Create (WMI; client-SKU compatible)" }
Register-Utility @{ Name = "List Shadow Copies (VSS)";   Id = "WinUtil.ListShadowCopies";         Category = "Snapshots & Backup"; Action = $true; Description = "VSS: 'vssadmin list shadows' (built-in)" }
Register-Utility @{ Name = "Delete Oldest Shadow (VSS)"; Id = "WinUtil.DeleteOldestShadowCopy";   Category = "Snapshots & Backup"; Action = $true; Description = "VSS: 'vssadmin delete shadows /oldest /quiet' for chosen volume (built-in)" }
# File History (FhManagew / control panel):
Register-Utility @{ Name = "Open File History";          Id = "WinUtil.OpenFileHistory";          Category = "Snapshots & Backup"; Action = $true; Description = "File History: opens 'control /name Microsoft.FileHistory' (built-in)" }
Register-Utility @{ Name = "Run File History Backup";    Id = "WinUtil.RunFileHistoryBackup";     Category = "Snapshots & Backup"; Action = $true; Description = "File History: trigger an immediate backup via FhManagew.exe -fullbackup (built-in)" }
# wbadmin (Windows Server Backup / Windows Backup feature):
Register-Utility @{ Name = "System Image Backup";        Id = "WinUtil.WbadminSystemImage";       Category = "Snapshots & Backup"; Action = $true; Description = "wbadmin start backup -allCritical -quiet (built-in; prompts for target volume)" }
Register-Utility @{ Name = "List wbadmin Backups";       Id = "WinUtil.WbadminListBackups";       Category = "Snapshots & Backup"; Action = $true; Description = "wbadmin get versions (built-in; lists available backup catalog entries)" }
# Third-party:
Register-Utility @{ Name = "Veeam Agent for Windows";    Id = "Veeam.VeeamAgent";                 Category = "Snapshots & Backup"; Description = "Veeam Agent for Microsoft Windows (Free): image-level backup & bare-metal restore" }

# ── Runtimes ──────────────────────────────────────────────────────────────
Register-Utility @{ Name = "Java Runtime Environment"; Id = "Oracle.JavaRuntimeEnvironment";          Category = "Runtimes";    Description = "Oracle Java Runtime Environment" }
Register-Utility @{ Name = "OpenJDK 21";               Id = "Microsoft.OpenJDK.21";                   Category = "Runtimes";    Description = "Microsoft Build of OpenJDK 21 (LTS)" }
Register-Utility @{ Name = ".NET 8 SDK";               Id = "Microsoft.DotNet.SDK.8";                 Category = "Runtimes";    Description = "Microsoft .NET 8 SDK" }
Register-Utility @{ Name = "VCRedist 2015+ x64";       Id = "Microsoft.VCRedist.2015+.x64";           Category = "Runtimes";    Description = "Visual C++ Redistributable for 2015-2022 (x64)" }
Register-Utility @{ Name = "DirectX End-User Runtime"; Id = "Microsoft.DirectX";                      Category = "Runtimes";    Description = "DirectX End-User Runtime web installer" }
#endregion

#region --- profiles ---
# Profile registry -curated presets that pre-populate the install queue.
#
# Each profile is a hashtable with Name, Description, and Items (an array of
# utility names that match Register-Utility entries). Profiles are applied
# from the menu sidebar: focus PROFILES, choose one, and press Enter.

$script:ProfileRegistry = [System.Collections.Generic.List[hashtable]]::new()

function Register-Profile {
    param([hashtable]$Definition)
    $script:ProfileRegistry.Add($Definition)
}

function Get-AllProfiles {
    return $script:ProfileRegistry
}

function Find-Profile {
    param([string]$Name)
    foreach ($p in $script:ProfileRegistry) {
        if ($p.Name -ieq $Name) { return $p }
    }
    return $null
}

# Resolve a profile's item names against the live utility registry and
# return matching utility hashtables. Names that don't resolve are ignored
# silently -useful when a profile lists optional packages.
function Resolve-ProfileItems {
    param([hashtable]$Profile)
    $resolved = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($name in $Profile.Items) {
        foreach ($u in Get-AllUtilities) {
            if ($u.Name -ieq $name) { $resolved.Add($u); break }
        }
    }
    return $resolved
}

# ── Curated Profiles ──────────────────────────────────────────────────────

Register-Profile @{
    Name        = "Run Me First"
    Description = "Baseline tools every Windows install benefits from"
    Items       = @(
        "7-Zip",
        "PowerToys",
        "Windows Terminal",
        "Microsoft Edge"
    )
}

Register-Profile @{
    Name        = "Default Physical PC"
    Description = "Desktop essentials - browser, archiver, media, system tools"
    Items       = @(
        "Google Chrome",
        "7-Zip",
        "VLC Media Player",
        "PowerToys",
        "Windows Terminal",
        "Notepad++",
        "ShareX",
        "Everything",
        "Spotify"
    )
}

Register-Profile @{
    Name        = "Developer Workstation"
    Description = "Editors, runtimes, version control, and container tooling"
    Items       = @(
        "Visual Studio Code",
        "Git",
        "GitHub CLI",
        "Windows Terminal",
        "PowerShell 7",
        "Docker Desktop",
        "Node.js LTS",
        "Python 3",
        "Postman",
        "DBeaver",
        "7-Zip",
        "PowerToys"
    )
}

Register-Profile @{
    Name        = "Home Desktop"
    Description = "Browser, office, messaging, media, and privacy tools"
    Items       = @(
        "Mozilla Firefox",
        "Thunderbird",
        "LibreOffice",
        "VLC Media Player",
        "Signal",
        "Bitwarden",
        "qBittorrent",
        "ProtonVPN",
        "Obsidian",
        "7-Zip",
        "ShareX"
    )
}

Register-Profile @{
    Name        = "Gaming Rig"
    Description = "Game launchers, voice chat, and performance tools"
    Items       = @(
        "Steam",
        "Epic Games Launcher",
        "GOG Galaxy",
        "Discord",
        "OBS Studio",
        "HWiNFO",
        "GPU-Z",
        "7-Zip"
    )
}
#endregion

#region --- menu ---
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

$CAT_WIDTH    = 30   # left sidebar inner width
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

    $map = Get-WingetInstalledMap
    foreach ($cat in $s.Categories) {
        foreach ($util in $ByCategory[$cat]) {
            Update-UtilityStatus $util $map
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
            $lines.Add(@{ Type='info'; Text=("{0}: {1}" -f $p.K, $p.V) })
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

            # Action-typed items (e.g. WinCleanup) are run-on-enter scripts
            # rather than installable packages -hide the install status tag.
            $isAction = $util.ContainsKey('Action') -and $util.Action
            if ($isAction) {
                $tagText  = ""
                $tagColor = $FDim
            } else {
                $tagText  = if ($installed) { if ($version) { "v$version" } else { "installed" } } else { "not installed" }
                $tagColor = if ($installed) { $FM } else { $FDim }
            }

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

    $map = Get-WingetInstalledMap
    foreach ($util in $toProcess) {
        Update-UtilityStatus $util $map
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

    $map = Get-WingetInstalledMap
    foreach ($cat in $s.Categories) {
        foreach ($util in $s.ByCategory[$cat]) {
            Update-UtilityStatus $util $map
        }
    }
    $s.SysInfo = Get-SystemInfo
    $s.StatusMessage = "Status refreshed."
    $s.StatusColor   = $FG
}

# Resolve a single utility's installed/version state. If $Map (from
# Get-WingetInstalledMap) is provided, look the Id up there -no per-utility
# winget process. Falls back to per-utility scriptblocks when the utility has
# custom Test-/Get-Version overrides, or when the bulk scan failed.
function Update-UtilityStatus {
    param([hashtable]$Utility, [hashtable]$Map)

    $safeName = $Utility.Name -replace '[^A-Za-z0-9]', ''
    $hasCustomTest    = $null -ne (Get-Command "Test-$safeName"         -ErrorAction SilentlyContinue)
    $hasCustomVersion = $null -ne (Get-Command "Get-${safeName}Version" -ErrorAction SilentlyContinue)

    if ($null -ne $Map -and -not $hasCustomTest -and -not $hasCustomVersion) {
        if ($Map.ContainsKey($Utility.Id)) {
            $Utility['_Installed'] = $true
            $Utility['_Version']   = $Map[$Utility.Id]
        } else {
            $Utility['_Installed'] = $false
            $Utility['_Version']   = $null
        }
        return
    }

    $fns  = Get-UtilityFunctions $Utility
    $inst = if ($fns.Test) { & $fns.Test } else { $false }
    $Utility['_Installed'] = $inst
    $Utility['_Version']   = if ($inst -and $fns.GetVersion) { & $fns.GetVersion } else { $null }
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
#endregion
