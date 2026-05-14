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
