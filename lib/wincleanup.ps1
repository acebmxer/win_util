# WinCleanup -bundled disk cleanup script (vendored from
# https://github.com/acebmxer/wincleanup, author PozzaTech, MIT-equivalent
# permission granted by repo owner).
#
# Registered as a utility named "WinCleanup". Install drops the script and a
# Start Menu shortcut under %LOCALAPPDATA%\win_util\WinCleanup so users can
# rerun it on demand without re-fetching from GitHub.

$script:WinCleanupVersion   = "1.0"
$script:WinCleanupInstallDir = Join-Path $env:LOCALAPPDATA 'win_util\WinCleanup'
$script:WinCleanupScriptPath = Join-Path $script:WinCleanupInstallDir 'WinCleanup.ps1'
$script:WinCleanupShortcut   = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\WinCleanup.lnk'

# Bundled script body. Self-elevation block is stripped -shortcut launches an
# elevated PowerShell directly. Read-Host prompts are kept so the user can
# decide per run whether to disable hibernation, cap shadow storage, reboot.
$script:WinCleanupBody = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 11 Disk Cleanup Script
.DESCRIPTION
    Cleans up Windows Update remnants, temp files, hibernation file,
    Delivery Optimization cache, and manages shadow copy storage.
.NOTES
    Author  : PozzaTech
    Version : 1.0
    Source  : https://github.com/acebmxer/wincleanup
    Vendored into win_util.
#>

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

Write-Host ""
Write-Host "  WinCleanup  |  PozzaTech (vendored in win_util)" -ForegroundColor White
Write-Host "  Running as: $env:USERNAME on $env:COMPUTERNAME" -ForegroundColor DarkGray
Write-Host ""

Write-Section "Step 1 of 6 - DISM Health Check"
Write-Status "Checking Windows image health before cleanup..."
$dismCheck = dism /online /cleanup-image /checkhealth 2>&1
if ($dismCheck -match "No component store corruption detected") {
    Write-Status "Image is healthy. Proceeding." Green
} else {
    Write-Status "DISM health check returned warnings - review output below:" Yellow
    Write-Host ($dismCheck | Out-String) -ForegroundColor DarkYellow
}

Write-Section "Step 2 of 6 - Windows Update / Component Store Cleanup"
Write-Status "Running DISM component cleanup with /resetbase..."
Write-Status "This may take several minutes. Please wait." Yellow

dism /online /cleanup-image /startcomponentcleanup /resetbase | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Status "Component store cleanup completed successfully." Green
} else {
    Write-Status "DISM returned exit code $LASTEXITCODE - check Event Viewer if issues arise." Yellow
}

Write-Section "Step 3 of 6 - Temp File Cleanup"
Remove-ItemsSafely -Path $env:TEMP
Remove-ItemsSafely -Path "C:\Windows\Temp"
Remove-ItemsSafely -Path "C:\Windows\Prefetch"

Write-Section "Step 4 of 6 - Delivery Optimization Cache"
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

Write-Section "Step 5 of 6 - Hibernation File (hiberfil.sys)"
$hibernateEnabled = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
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

Write-Section "Step 6 of 6 - Shadow Copy Storage (System Restore)"
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

Write-Section "Bonus - Windows Disk Cleanup (cleanmgr)"
Write-Host ""
Write-Host "  Launching Disk Cleanup with all categories pre-selected." -ForegroundColor White
Write-Host "  Review selections and click OK to proceed." -ForegroundColor DarkGray
Write-Host ""
$cleanmgrKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
Get-ChildItem $cleanmgrKey | ForEach-Object {
    Set-ItemProperty -Path $_.PSPath -Name StateFlags0001 -Value 2 -Type DWord -ErrorAction SilentlyContinue
}
Start-Process -FilePath cleanmgr -ArgumentList "/sagerun:1" -Wait
Write-Status "Disk Cleanup completed." Green

Write-Host ""
Write-Host "===========================================" -ForegroundColor Green
Write-Host "  Cleanup Complete!" -ForegroundColor Green
Write-Host "  A reboot is recommended to finalize changes." -ForegroundColor Green
Write-Host "===========================================" -ForegroundColor Green
Write-Host ""
$reboot = Read-Host "  Reboot now? (Y/N)"
if ($reboot -match "^[Yy]$") {
    Restart-Computer -Force
} else {
    Write-Host "  Remember to reboot when convenient." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to exit"
}
'@

function Install-WinCleanup {
    try {
        if (-not (Test-Path $script:WinCleanupInstallDir)) {
            New-Item -ItemType Directory -Path $script:WinCleanupInstallDir -Force | Out-Null
        }
        # UTF-8 BOM keeps Windows PowerShell 5.1 happy with non-ASCII chars.
        [System.IO.File]::WriteAllText($script:WinCleanupScriptPath, $script:WinCleanupBody, [System.Text.UTF8Encoding]::new($true))
        # Stamp version next to the script so Get-Version can read it back.
        Set-Content -Path (Join-Path $script:WinCleanupInstallDir 'version.txt') -Value $script:WinCleanupVersion -Encoding ASCII

        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shell = New-Object -ComObject WScript.Shell
        $lnk   = $shell.CreateShortcut($script:WinCleanupShortcut)
        $lnk.TargetPath       = $psExe
        $lnk.Arguments        = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$script:WinCleanupScriptPath`""
        $lnk.WorkingDirectory = $script:WinCleanupInstallDir
        $lnk.IconLocation     = "$psExe,0"
        $lnk.Description      = 'Windows 11 Disk Cleanup Script (PozzaTech)'
        $lnk.Save()

        # Flip the "Run as administrator" flag (byte 0x15, bit 0x20) so the
        # shortcut triggers a UAC prompt -cleanmgr/DISM need elevation.
        try {
            $bytes = [System.IO.File]::ReadAllBytes($script:WinCleanupShortcut)
            if ($bytes.Length -gt 0x15 -and -not ($bytes[0x15] -band 0x20)) {
                $bytes[0x15] = $bytes[0x15] -bor 0x20
                [System.IO.File]::WriteAllBytes($script:WinCleanupShortcut, $bytes)
            }
        } catch {}

        Write-Host "  Installed to $script:WinCleanupScriptPath" -ForegroundColor Green
        Write-Host "  Start Menu shortcut: WinCleanup" -ForegroundColor Green
        $global:LASTEXITCODE = 0
    } catch {
        Write-Host "  WinCleanup install failed: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
    }
}

function Uninstall-WinCleanup {
    try {
        if (Test-Path $script:WinCleanupShortcut)   { Remove-Item $script:WinCleanupShortcut -Force }
        if (Test-Path $script:WinCleanupInstallDir) { Remove-Item $script:WinCleanupInstallDir -Recurse -Force }
        Write-Host "  WinCleanup removed." -ForegroundColor Green
        $global:LASTEXITCODE = 0
    } catch {
        Write-Host "  WinCleanup uninstall failed: $($_.Exception.Message)" -ForegroundColor Red
        $global:LASTEXITCODE = 1
    }
}

function Update-WinCleanup {
    # Reinstall overwrites with the current bundled version.
    Install-WinCleanup
}

function Test-WinCleanup {
    return (Test-Path $script:WinCleanupScriptPath)
}

function Get-WinCleanupVersion {
    $verFile = Join-Path $script:WinCleanupInstallDir 'version.txt'
    if (Test-Path $verFile) {
        return (Get-Content $verFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    }
    return $null
}
