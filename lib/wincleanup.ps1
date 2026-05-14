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
