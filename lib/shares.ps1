# Network share actions: map SMB, mount NFS, list, disconnect.
#
# All entries are Action-type utilities (run-on-Enter scripts). Test-* always
# returns $false so the menu always routes Enter to Install (= run the action).
#
# Utility mapping:
#
#   Map SMB Share      -> New-SmbMapping -Persistent + cmdkey for stored creds
#   Mount NFS Share    -> mount.exe (from "Services for NFS / Client for NFS")
#   List Shares        -> Get-SmbMapping  +  mount.exe (no args)
#   Disconnect Share   -> Remove-SmbMapping  /  umount.exe
#
# Function names below must match the Utility.Name with non-alphanumerics
# stripped (see Get-UtilityFunctions in installers.ps1). e.g. "Map SMB Share"
# resolves to safeName "MapSMBShare" -> Install-MapSMBShare / Test-... / etc.

#region --- helpers ---

function Read-NonEmptyHost {
    param([string]$Prompt, [string]$Default = '')
    while ($true) {
        $hint = if ($Default) { " [$Default]" } else { '' }
        $v = Read-Host "  $Prompt$hint"
        if ([string]::IsNullOrWhiteSpace($v) -and $Default) { return $Default }
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
        Write-Host "  Value cannot be empty." -ForegroundColor Red
    }
}

function Get-AvailableDriveLetter {
    # Returns the first free drive letter from Z: backward, or $null if none.
    $used = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name) +
            @((Get-SmbMapping -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.LocalPath) { $_.LocalPath.TrimEnd(':','\') }
            }))
    foreach ($c in [char[]]('ZYXWVUTSRQPONMLKJIHGFED')) {
        if ($used -notcontains "$c") { return "$c`:" }
    }
    return $null
}

function Test-DriveLetterFree {
    param([string]$Letter)
    $clean = $Letter.TrimEnd(':','\').ToUpper()
    if ($clean.Length -ne 1) { return $false }
    return -not (Test-Path "$clean`:\")
}

function Update-ShellDriveView {
    # Tell Explorer that drives were *removed* so their icons drop off any
    # open "This PC" window immediately.
    #
    # This is reliable for removal only. SHChangeNotify with SHCNE_DRIVEREMOVED
    # and SHCNF_FLUSH makes a running Explorer drop a stale drive icon. The
    # mirror-image SHCNE_DRIVEADD does NOT reliably make Explorer pick up a
    # newly mapped *network* drive -Explorer caches its network-drive list and
    # only re-reads it on a new process or manual refresh. So for the "add"
    # case callers use Restart-ExplorerForDrives instead.
    #
    #   SHCNE_DRIVEREMOVED (0x00000080) - a drive went away
    #   SHCNF_PATHW        (0x00000005) - item args are wide-string paths
    #   SHCNF_FLUSH        (0x00001000) - deliver synchronously
    #
    # $Letters is a list like 'X:','Y:'.
    param([string[]]$Letters)
    if (-not $Letters -or $Letters.Count -eq 0) { return }
    try {
        $sig = '[DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern void SHChangeNotify(int eventId, int flags, string item1, string item2);'
        $sh = Add-Type -MemberDefinition $sig -Name 'WinUtilShellDrive' `
                       -Namespace 'WinUtil' -PassThru -ErrorAction Stop
        $flags = 0x00000005 -bor 0x00001000   # SHCNF_PATHW | SHCNF_FLUSH
        foreach ($l in $Letters) {
            $root = ($l.TrimEnd(':','\').ToUpper()) + ':\'
            $sh::SHChangeNotify(0x00000080, $flags, $root, $null)   # SHCNE_DRIVEREMOVED
        }
        $sh::SHChangeNotify(0x08000000, 0x00001000, $null, $null)   # SHCNE_ASSOCCHANGED
    } catch {
        # Non-fatal: the drives are still gone; Explorer may just need a
        # manual F5 or reopen to notice.
    }
}

function Restart-ExplorerForDrives {
    # Restart explorer.exe so newly mapped network drives appear immediately.
    #
    # Explorer caches its network-drive list; a freshly mapped drive does not
    # show in an already-open window via any SHChangeNotify event (tested).
    # The only reliable way to surface it without the user navigating/F5-ing
    # is a fresh Explorer process. This closes open File Explorer windows and
    # briefly reloads the taskbar/desktop (~2s); it is not a sign-out.
    Write-Host "  Restarting Explorer so the new drives appear..." -ForegroundColor DarkGray
    try {
        Stop-Process -Name explorer -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
        }
        return $true
    } catch {
        Write-Host "  Could not restart Explorer: $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-Host "  The drives are mapped -press F5 in Explorer or reopen the window." -ForegroundColor DarkYellow
        return $false
    }
}

function Get-NfsMountExe {
    # Resolve the Windows "Client for NFS" mount.exe specifically.
    #
    # Get-Command 'mount.exe' is unreliable here: if Git for Windows is
    # installed, its MSYS mount.exe (C:\Program Files\Git\usr\bin\mount.exe)
    # often shadows the real one on PATH. The MSYS tool prints fstab-style
    # lines ("X: on /x type nfs ...") that the NFS-output parser cannot read,
    # so disconnect/list silently miss every mounted NFS drive.
    #
    # The genuine NFS client always lives at %WINDIR%\System32\mount.exe.
    $sys32 = Join-Path $env:WINDIR 'System32\mount.exe'
    if (Test-Path $sys32) { return $sys32 }
    # Fall back to PATH lookup only if System32 copy is absent.
    $cmd = Get-Command 'mount.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

#endregion

#region --- SMB ---

function Invoke-MapSmbShare {
    Write-Host "  [New-SmbMapping]  Map an SMB / CIFS share" -ForegroundColor Cyan

    # If we're running elevated, Explorer / normal shells will not see the
    # mapped drives unless EnableLinkedConnections is set. New-SmbMapping
    # creates the mapping in the *elevated* token's drive namespace; the
    # interactive (non-elevated) token Explorer uses gets a separate one.
    # Offer to fix it now so the user doesn't map shares and then wonder
    # why they never appear in Explorer.
    if ((Test-IsElevated) -and -not (Test-LinkedConnectionsEnabled)) {
        Write-Host ""
        Write-Host "  Note: this session is elevated. Drives mapped from an elevated" -ForegroundColor Yellow
        Write-Host "  shell are hidden from Explorer and normal shells unless the" -ForegroundColor Yellow
        Write-Host "  EnableLinkedConnections registry value is set." -ForegroundColor Yellow
        $ans = Read-Host "  Enable cross-session drive visibility now? [Y/n]"
        if ($ans -notmatch '^(n|no)$') {
            if (Enable-LinkedConnections) {
                Write-Host "  EnableLinkedConnections set. Sign out / reboot to take effect." -ForegroundColor Green
                Write-Host "  (Mappings you create now appear in Explorer after the next sign-in;" -ForegroundColor DarkGray
                Write-Host "   make them persistent below so they survive the sign-out.)" -ForegroundColor DarkGray
            }
        }
        Write-Host ""
    }

    $server = Read-NonEmptyHost -Prompt 'SMB server (IP or hostname)'

    Write-Host "  Querying shares on \\$server ..." -ForegroundColor DarkGray
    $shareList = $null
    try {
        # net view enumerates browseable shares. May fail if the host blocks SMB1
        # browsing or requires credentials -that's fine, the user can type the
        # share name manually below.
        $netview = & net view "\\$server" 2>$null
        if ($LASTEXITCODE -eq 0 -and $netview) {
            $shareList = @($netview |
                Where-Object { $_ -match '^\S+\s+Disk' } |
                ForEach-Object { ($_ -split '\s{2,}')[0] } |
                Where-Object { $_ -and $_ -notmatch '\$$' })
        }
    } catch { }

    $selectedShares = @()
    if ($shareList -and $shareList.Count -gt 0) {
        Write-Host ""
        Write-Host "  Available shares:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $shareList.Count; $i++) {
            Write-Host ("    {0}) {1}" -f ($i + 1), $shareList[$i])
        }
        Write-Host ""
        Write-Host "  Tip: select multiple with commas/ranges (e.g. 1,3,5 or 2-4), or 'all'." -ForegroundColor DarkGray
        $sel = Read-Host "  Select share number(s), or type a custom share name"
        $selectedShares = @(Resolve-IndexSelection -Selection $sel -Items $shareList)
    } else {
        Write-Host "  (Could not enumerate shares automatically -enter manually.)" -ForegroundColor DarkYellow
        $manual = Read-NonEmptyHost -Prompt 'Share name (e.g. data)'
        $selectedShares = @($manual)
    }

    # Normalize share names.
    $selectedShares = @($selectedShares |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().TrimStart('\','/') })

    if ($selectedShares.Count -eq 0) {
        Write-Host "  No share selected, aborting." -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        return
    }

    # Prompt for a drive letter per share. The suggested default is the next
    # free letter scanning Z -> D, skipping ones already chosen in this run.
    $assignments = @()
    $usedLetters = @()
    foreach ($sh in $selectedShares) {
        $suggested = $null
        foreach ($c in [char[]]('ZYXWVUTSRQPONMLKJIHGFED')) {
            $cand = "$c"
            if ($usedLetters -notcontains $cand -and (Test-DriveLetterFree "$cand`:")) {
                $suggested = $cand; break
            }
        }
        if (-not $suggested) {
            Write-Host "  Ran out of available drive letters." -ForegroundColor Red
            $global:LASTEXITCODE = 1
            return
        }

        while ($true) {
            $letterIn = Read-Host ("  Drive letter for \\{0}\{1} [default: {2}:]" -f $server, $sh, $suggested)
            if ([string]::IsNullOrWhiteSpace($letterIn)) { $letterIn = $suggested }
            $letter = $letterIn.TrimEnd(':','\').ToUpper()
            if ($letter.Length -ne 1 -or $letter -notmatch '^[A-Z]$') {
                Write-Host "  Invalid drive letter '$letterIn'." -ForegroundColor Red
                continue
            }
            if ($usedLetters -contains $letter) {
                Write-Host "  $letter`: already chosen for another share in this run." -ForegroundColor Red
                continue
            }
            if (-not (Test-DriveLetterFree "$letter`:")) {
                Write-Host "  Drive $letter`: is already in use on this system." -ForegroundColor Red
                continue
            }
            break
        }

        $usedLetters += $letter
        $assignments += [pscustomobject]@{
            Share      = $sh
            Letter     = $letter
            LocalPath  = "$letter`:"
            RemotePath = "\\$server\$sh"
        }
    }

    $user = Read-Host "  Username (DOMAIN\user or user; blank for current login)"
    $cred = $null
    $passPlain = $null
    if (-not [string]::IsNullOrWhiteSpace($user)) {
        $sec = Read-Host "  Password" -AsSecureString
        $cred = New-Object System.Management.Automation.PSCredential ($user, $sec)
        $passPlain = [System.Net.NetworkCredential]::new('', $sec).Password
    }

    $persistAns = Read-Host "  Reconnect at sign-in? [Y/n]"
    $persistent = -not ($persistAns -match '^(n|no)$')

    Write-Host ""
    Write-Host "  Server:     $server"
    Write-Host "  Persistent: $persistent"
    Write-Host "  User:       $(if ($user) { $user } else { '(current login)' })"
    Write-Host "  Mounts:"
    foreach ($a in $assignments) {
        Write-Host ("    {0}  <-  {1}" -f $a.LocalPath, $a.RemotePath)
    }
    Write-Host ""
    $confirm = Read-Host "  Proceed? [y/N]"
    if ($confirm -notmatch '^(y|yes)$') {
        Write-Host "  Aborted." -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        return
    }

    # Store credentials in Windows Credential Manager so the persistent mapping
    # can reconnect at login without prompting. cmdkey writes to the user's
    # vault; the entry is keyed on the server name (shared across all shares).
    if ($cred -and $persistent) {
        try {
            & cmdkey /add:$server /user:$user /pass:$passPlain | Out-Null
            Write-Host "  Stored credentials in Credential Manager for $server." -ForegroundColor DarkGray
        } catch {
            Write-Host "  Warning: cmdkey failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    $ok = 0
    $fail = 0
    $addedLetters = @()   # drives actually mapped, for the Explorer refresh
    try {
        foreach ($a in $assignments) {
            Write-Host ""
            Write-Host ("  Mapping {0} -> {1}" -f $a.RemotePath, $a.LocalPath) -ForegroundColor Cyan
            try {
                $params = @{
                    LocalPath   = $a.LocalPath
                    RemotePath  = $a.RemotePath
                    Persistent  = $persistent
                    ErrorAction = 'Stop'
                }
                if ($cred) { $params.UserName = $user; $params.Password = $passPlain }
                New-SmbMapping @params | Out-Null
                Write-Host "  Mapped $($a.RemotePath) to $($a.LocalPath)." -ForegroundColor Green
                $addedLetters += $a.LocalPath
                $ok++
            } catch {
                Write-Host "  New-SmbMapping failed: $($_.Exception.Message)" -ForegroundColor Red
                $fail++
            }
        }
    } finally {
        # Best-effort scrub of the plaintext password from memory.
        if ($passPlain) { $passPlain = $null }
    }

    Write-Host ""
    Write-Host ("  Done. Mapped: {0}  Failed: {1}" -f $ok, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
    if ($fail -gt 0) {
        Write-Host "  Tip: verify the server is reachable and credentials are correct." -ForegroundColor DarkYellow
    }

    if ($ok -gt 0) {
        Show-NewDriveExplorerHelp -Letters $addedLetters
    }
    $global:LASTEXITCODE = if ($fail -eq 0) { 0 } else { 1 }
}

function Show-NewDriveExplorerHelp {
    # After a successful mount, make the new drives visible in Explorer.
    #
    # Three cases:
    #   * Non-elevated session  -the mapping is in the same token Explorer
    #     uses; a quick Explorer restart surfaces it. (SHChangeNotify alone
    #     does not -Explorer caches its network-drive list.)
    #   * Elevated + EnableLinkedConnections set -the mapping will mirror to
    #     the interactive token, but only at the next sign-in. Restarting
    #     Explorer now won't help; tell the user to sign out/in.
    #   * Elevated + the value not set -the drive is stuck in the elevated
    #     token. Point the user at the 'Enable Linked Connections' utility.
    param([string[]]$Letters)

    $list = if ($Letters) { ($Letters -join ', ') } else { 'the new drives' }

    if (Test-IsElevated) {
        Write-Host ""
        if (Test-LinkedConnectionsEnabled) {
            Write-Host "  Mapped from an elevated shell: $list appear in Explorer" -ForegroundColor DarkYellow
            Write-Host "  after your next sign-in (EnableLinkedConnections applies per" -ForegroundColor DarkYellow
            Write-Host "  logon). Sign out and back in to see them now." -ForegroundColor DarkYellow
        } else {
            Write-Host "  Mapped from an elevated shell: $list won't be visible in" -ForegroundColor DarkYellow
            Write-Host "  Explorer. Run the 'Enable Linked Connections' utility, then" -ForegroundColor DarkYellow
            Write-Host "  sign out and back in." -ForegroundColor DarkYellow
        }
        return
    }

    # Non-elevated: a freshly mapped network drive does not show in an open
    # Explorer window until Explorer is restarted (it caches the drive list).
    # Offer it -a restart closes any open File Explorer windows.
    Write-Host ""
    Write-Host "  $list mapped. Explorer must restart to show new network drives" -ForegroundColor DarkYellow
    Write-Host "  (open File Explorer windows will close; ~2s)." -ForegroundColor DarkGray
    $ans = Read-Host "  Restart Explorer now? [Y/n]"
    if ($ans -match '^(n|no)$') {
        Write-Host "  Skipped. Press F5 in Explorer or reopen the window to see them." -ForegroundColor DarkGray
        return
    }
    Restart-ExplorerForDrives | Out-Null
}

#endregion

#region --- NFS ---

function Test-NfsClientInstalled {
    # mount.exe shipped with Services for NFS lives under %WINDIR%\System32.
    # Get-WindowsOptionalFeature is the authoritative check but is slow; do the
    # cheap path test first.
    if (Get-Command 'mount.exe' -ErrorAction SilentlyContinue) { return $true }
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName 'ServicesForNFS-ClientOnly' -ErrorAction Stop
        return $f.State -eq 'Enabled'
    } catch {
        return $false
    }
}

function Enable-NfsClient {
    Write-Host "  [Enable-WindowsOptionalFeature]  Installing 'Services for NFS / Client for NFS'..." -ForegroundColor Cyan
    Write-Host "  This may take a minute and could require a reboot to complete." -ForegroundColor DarkGray
    try {
        # ClientForNFS-Infrastructure pulls in mount.exe / nfsclnt; ServicesForNFS-ClientOnly
        # is the umbrella feature that enables both client pieces on client SKUs.
        Enable-WindowsOptionalFeature -Online -FeatureName 'ServicesForNFS-ClientOnly' -All -NoRestart -ErrorAction Stop | Out-Null
        Enable-WindowsOptionalFeature -Online -FeatureName 'ClientForNFS-Infrastructure' -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  NFS client enabled. A reboot may be required before mount.exe is available." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  Failed to enable NFS client: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Enable it manually: Settings -Optional features -'Services for NFS'." -ForegroundColor DarkYellow
        return $false
    }
}

# Drives mapped from an elevated token (Administrator) are not visible to the
# matching non-elevated token (Explorer, normal shells). EnableLinkedConnections
# tells Windows to mirror mappings between the linked tokens of one user.
# See: https://learn.microsoft.com/troubleshoot/windows-client/networking/mapped-drives-not-available-from-elevated-command
function Test-LinkedConnectionsEnabled {
    try {
        $v = Get-ItemPropertyValue `
                -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
                -Name 'EnableLinkedConnections' -ErrorAction Stop
        return [int]$v -eq 1
    } catch {
        return $false
    }
}

function Test-IsElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Enable-LinkedConnections {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    try {
        if (-not (Test-Path $key)) {
            New-Item -Path $key -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -Path $key -Name 'EnableLinkedConnections' `
            -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Host "  Failed to set EnableLinkedConnections: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Invoke-EnableLinkedConnections {
    Write-Host "  [Registry]  EnableLinkedConnections (cross-session drive visibility)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Drives mapped from an elevated (Administrator) shell are hidden from"
    Write-Host "  Explorer and normal shells, because each token gets its own drive"
    Write-Host "  namespace. Setting EnableLinkedConnections=1 mirrors mappings between"
    Write-Host "  the elevated and non-elevated tokens of the same user."
    Write-Host ""
    Write-Host "  Registry: HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ForegroundColor DarkGray
    Write-Host "  Value:    EnableLinkedConnections (DWORD) = 1" -ForegroundColor DarkGray
    Write-Host ""

    if (Test-LinkedConnectionsEnabled) {
        Write-Host "  Already enabled. If drives still aren't visible, sign out and back in." -ForegroundColor Green
        $global:LASTEXITCODE = 0
        return
    }

    $ans = Read-Host "  Enable now? [Y/n]"
    if ($ans -match '^(n|no)$') {
        Write-Host "  Aborted." -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        return
    }

    if (Enable-LinkedConnections) {
        Write-Host "  EnableLinkedConnections set to 1." -ForegroundColor Green
        Write-Host "  Sign out and back in (or reboot) for it to take effect." -ForegroundColor Yellow
        $global:LASTEXITCODE = 0
    } else {
        $global:LASTEXITCODE = 1
    }
}

function Invoke-MountNfsShare {
    Write-Host "  [mount.exe]  Mount an NFS export" -ForegroundColor Cyan

    if (-not (Test-NfsClientInstalled)) {
        Write-Host "  NFS client is not installed on this system." -ForegroundColor Yellow
        $ans = Read-Host "  Install 'Services for NFS / Client for NFS' now? [Y/n]"
        if ($ans -match '^(n|no)$') {
            Write-Host "  Aborted -NFS client required." -ForegroundColor Yellow
            $global:LASTEXITCODE = 1
            return
        }
        if (-not (Enable-NfsClient)) { $global:LASTEXITCODE = 1; return }
        if (-not (Get-Command 'mount.exe' -ErrorAction SilentlyContinue)) {
            Write-Host "  mount.exe not yet on PATH -reboot, then run this option again." -ForegroundColor Yellow
            $global:LASTEXITCODE = 0
            return
        }
    }

    # If we're running elevated, Explorer / normal shells will not see the
    # mounted drives unless EnableLinkedConnections is set. Offer to fix it
    # now so the user doesn't mount three shares and then wonder where they went.
    if ((Test-IsElevated) -and -not (Test-LinkedConnectionsEnabled)) {
        Write-Host ""
        Write-Host "  Note: this session is elevated. Drives mounted from an elevated" -ForegroundColor Yellow
        Write-Host "  shell are hidden from Explorer and normal shells unless the" -ForegroundColor Yellow
        Write-Host "  EnableLinkedConnections registry value is set." -ForegroundColor Yellow
        $ans = Read-Host "  Enable cross-session drive visibility now? [Y/n]"
        if ($ans -notmatch '^(n|no)$') {
            if (Enable-LinkedConnections) {
                Write-Host "  EnableLinkedConnections set. Sign out / reboot to take effect." -ForegroundColor Green
                Write-Host "  (Mounts you create now will appear after the next sign-in.)" -ForegroundColor DarkGray
            }
        }
        Write-Host ""
    }

    $server = Read-NonEmptyHost -Prompt 'NFS server (IP or hostname)'

    # showmount -e is available on Windows when NFS client is installed.
    Write-Host "  Querying exports on $server ..." -ForegroundColor DarkGray
    $exports = $null
    try {
        $raw = & showmount.exe -e $server 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $exports = @($raw |
                Select-Object -Skip 1 |
                ForEach-Object { ($_ -split '\s+')[0] } |
                Where-Object { $_ })
        }
    } catch { }

    $selectedExports = @()
    if ($exports -and $exports.Count -gt 0) {
        Write-Host ""
        Write-Host "  Available exports:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $exports.Count; $i++) {
            Write-Host ("    {0}) {1}" -f ($i + 1), $exports[$i])
        }
        Write-Host ""
        Write-Host "  Tip: select multiple with commas/ranges (e.g. 1,3,5 or 2-4), or 'all'." -ForegroundColor DarkGray
        $sel = Read-Host "  Select export number(s), or type a custom export path"

        $selectedExports = @(Resolve-IndexSelection -Selection $sel -Items $exports)
    } else {
        Write-Host "  (Could not enumerate exports -enter manually.)" -ForegroundColor DarkYellow
        $manual = Read-NonEmptyHost -Prompt 'Export path (e.g. /mnt/data)'
        $selectedExports = @($manual.Trim())
    }

    if ($selectedExports.Count -eq 0) {
        Write-Host "  No export selected, aborting." -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        return
    }

    # Prompt for a drive letter per export. The suggested default is the next
    # free letter scanning Z -> D, skipping ones already chosen in this run.
    $assignments = @()
    $usedLetters = @()
    foreach ($exp in $selectedExports) {
        $unc = "\\$server" + ($exp -replace '/', '\')

        $suggested = $null
        foreach ($c in [char[]]('ZYXWVUTSRQPONMLKJIHGFED')) {
            $cand = "$c"
            if ($usedLetters -notcontains $cand -and (Test-DriveLetterFree "$cand`:")) {
                $suggested = $cand; break
            }
        }
        if (-not $suggested) {
            Write-Host "  Ran out of available drive letters." -ForegroundColor Red
            $global:LASTEXITCODE = 1
            return
        }

        while ($true) {
            $letterIn = Read-Host ("  Drive letter for {0} [default: {1}:]" -f $unc, $suggested)
            if ([string]::IsNullOrWhiteSpace($letterIn)) { $letterIn = $suggested }
            $letter = $letterIn.TrimEnd(':','\').ToUpper()
            if ($letter.Length -ne 1 -or $letter -notmatch '^[A-Z]$') {
                Write-Host "  Invalid drive letter '$letterIn'." -ForegroundColor Red
                continue
            }
            if ($usedLetters -contains $letter) {
                Write-Host "  $letter`: already chosen for another export in this run." -ForegroundColor Red
                continue
            }
            if (-not (Test-DriveLetterFree "$letter`:")) {
                Write-Host "  Drive $letter`: is already in use on this system." -ForegroundColor Red
                continue
            }
            break
        }

        $usedLetters += $letter
        $assignments += [pscustomobject]@{
            Export = $exp
            Letter = $letter
            Unc    = $unc
        }
    }

    $persistAns = Read-Host "  Reconnect at sign-in? [Y/n]"
    $persistent = -not ($persistAns -match '^(n|no)$')

    Write-Host ""
    Write-Host "  Server:     $server"
    Write-Host "  Persistent: $persistent"
    Write-Host "  Mounts:"
    foreach ($a in $assignments) {
        Write-Host ("    {0}:  <-  {1}" -f $a.Letter, $a.Unc)
    }
    Write-Host ""
    $confirm = Read-Host "  Proceed? [y/N]"
    if ($confirm -notmatch '^(y|yes)$') {
        Write-Host "  Aborted." -ForegroundColor Yellow
        $global:LASTEXITCODE = 1
        return
    }

    # Use the genuine Windows NFS mount.exe, not a Git/MSYS one that may
    # shadow it on PATH (see Get-NfsMountExe).
    $nfsMount = Get-NfsMountExe
    if (-not $nfsMount) { $nfsMount = 'mount.exe' }

    $ok = 0
    $fail = 0
    $addedLetters = @()   # drives actually mounted, for the Explorer refresh
    foreach ($a in $assignments) {
        Write-Host ""
        Write-Host ("  Mounting {0} -> {1}:" -f $a.Unc, $a.Letter) -ForegroundColor Cyan

        # -o anon mounts without sending UID/GID (anonymous). For UID-mapped access,
        # users can set AnonymousUid/Gid in HKLM\Software\Microsoft\ClientForNFS\...
        $mountArgs = @('-o','anon')
        if ($persistent) { $mountArgs += @('-o','fileaccess=755','-o','rsize=32','-o','wsize=32') }
        $mountArgs += @($a.Unc, "$($a.Letter):")

        try {
            & $nfsMount @mountArgs
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Mounted $($a.Unc) to $($a.Letter):" -ForegroundColor Green
                $addedLetters += "$($a.Letter):"
                $ok++

                # mount.exe does not honor a "reconnect at logon" flag the way
                # net use does. Persist by writing a logon script entry.
                if ($persistent) {
                    $entry = "mount -o anon $($a.Unc) $($a.Letter):"
                    $startup = [Environment]::GetFolderPath('Startup')
                    $script  = Join-Path $startup 'win_util_nfs_mounts.cmd'
                    if (-not (Test-Path $script) -or -not (Select-String -Path $script -Pattern ([regex]::Escape($entry)) -SimpleMatch -Quiet)) {
                        Add-Content -Path $script -Value $entry
                        Write-Host "  Persistence: added to $script (runs at sign-in)." -ForegroundColor DarkGray
                    }
                }
            } else {
                Write-Host "  mount.exe exited $LASTEXITCODE." -ForegroundColor Red
                $fail++
            }
        } catch {
            Write-Host "  mount.exe failed: $($_.Exception.Message)" -ForegroundColor Red
            $fail++
        }
    }

    Write-Host ""
    Write-Host ("  Done. Mounted: {0}  Failed: {1}" -f $ok, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })

    if ($ok -gt 0) {
        Show-NewDriveExplorerHelp -Letters $addedLetters
    }
    $global:LASTEXITCODE = if ($fail -eq 0) { 0 } else { 1 }
}

function Resolve-IndexSelection {
    # Parses a 1-based selection string against an item list. Accepts:
    #   - a single number ("3")
    #   - comma-separated numbers ("1,3,5")
    #   - ranges ("2-4")
    #   - mixed ("1,3-5,7")
    #   - "all" / "*"
    #   - any non-numeric string -> returned as a single literal entry
    #     (so callers can fall back to "user typed a custom name/path")
    param(
        [string]$Selection,
        [object[]]$Items
    )
    if ($null -eq $Selection) { return @() }
    $s = $Selection.Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return @() }

    if ($s -match '^(all|\*)$') { return @($Items) }

    if ($s -match '^[\d,\-\s]+$') {
        $picked = @()
        $seen   = @{}
        foreach ($part in ($s -split ',')) {
            $p = $part.Trim()
            if (-not $p) { continue }
            if ($p -match '^(\d+)-(\d+)$') {
                $a = [int]$matches[1]; $b = [int]$matches[2]
                if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
                for ($i = $a; $i -le $b; $i++) {
                    if ($i -ge 1 -and $i -le $Items.Count -and -not $seen.ContainsKey($i)) {
                        $seen[$i] = $true
                        $picked += ,$Items[$i - 1]
                    }
                }
            } elseif ($p -match '^\d+$') {
                $i = [int]$p
                if ($i -ge 1 -and $i -le $Items.Count -and -not $seen.ContainsKey($i)) {
                    $seen[$i] = $true
                    $picked += ,$Items[$i - 1]
                }
            }
        }
        # Return as a single array object; callers wrap with @() to normalize.
        # Using `,$picked` here would double-wrap, making foreach treat the
        # whole selection as one item (a recent regression that mapped every
        # selected share to the same drive letter).
        return $picked
    }

    return @($s)
}

#endregion

#region --- List / Disconnect ---

function Invoke-ListShares {
    Write-Host "  [Get-SmbMapping]  Mapped SMB shares:" -ForegroundColor Cyan
    try {
        $smb = Get-SmbMapping -ErrorAction Stop
        if ($smb) {
            $smb | Format-Table LocalPath, RemotePath, Status -AutoSize | Out-String | Write-Host
        } else {
            Write-Host "  (none)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  Get-SmbMapping failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    $nfsMount = Get-NfsMountExe
    if ($nfsMount) {
        Write-Host ""
        Write-Host "  [mount.exe]  Mounted NFS shares:" -ForegroundColor Cyan
        try {
            $nfsOut = & $nfsMount 2>$null
            if ($LASTEXITCODE -eq 0 -and $nfsOut) {
                $nfsOut | ForEach-Object { Write-Host "  $_" }
            } else {
                Write-Host "  (none)" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "  mount.exe failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    $global:LASTEXITCODE = 0
}

function Get-NfsMountEntries {
    # Enumerate mounted NFS drives, returning {Local; Remote} objects.
    #
    # Two sources, merged and de-duplicated by drive letter:
    #   1. The NFS mount.exe table. Its header is "Local  Remote  Properties";
    #      a healthy mount prints "X:  \\server\export  UID=..." while a stale
    #      one prints "Y:  \\server\export  Unavailable". Both forms start the
    #      line with the letter followed by the UNC path, so one regex covers
    #      them. (The MSYS Git mount.exe must be avoided -see Get-NfsMountExe.)
    #   2. `net use`, which lists NFS drives as "NFS Network" even when
    #      mount.exe omits them (e.g. mounts owned by a different logon token).
    $found = @{}
    $list  = @()

    $nfsMount = Get-NfsMountExe
    if ($nfsMount) {
        try {
            $nfsOut = & $nfsMount 2>$null
            if ($LASTEXITCODE -eq 0 -and $nfsOut) {
                foreach ($line in $nfsOut) {
                    if ($line -match '^([A-Za-z]):\s+(\\\\\S+)') {
                        $letter = $matches[1].ToUpper()
                        if (-not $found.ContainsKey($letter)) {
                            $found[$letter] = $true
                            $list += [pscustomobject]@{ Kind='NFS'; Local="$letter`:"; Remote=$matches[2] }
                        }
                    }
                }
            }
        } catch { }
    }

    # `net use` rows wrap: the drive letter + remote path are on one line,
    # the network type ("NFS Network") may be on the next. Track the last
    # letter/remote seen and attach the type when it arrives.
    try {
        $netUse = & net use 2>$null
        if ($netUse) {
            $pendLetter = $null; $pendRemote = $null
            foreach ($line in $netUse) {
                if ($line -match '([A-Za-z]):\s+(\\\\\S+)') {
                    $pendLetter = $matches[1].ToUpper(); $pendRemote = $matches[2]
                    # Type may already be on the same line.
                    if ($line -match 'NFS' -and -not $found.ContainsKey($pendLetter)) {
                        $found[$pendLetter] = $true
                        $list += [pscustomobject]@{ Kind='NFS'; Local="$pendLetter`:"; Remote=$pendRemote }
                        $pendLetter = $null
                    }
                } elseif ($pendLetter -and $line -match 'NFS') {
                    if (-not $found.ContainsKey($pendLetter)) {
                        $found[$pendLetter] = $true
                        $list += [pscustomobject]@{ Kind='NFS'; Local="$pendLetter`:"; Remote=$pendRemote }
                    }
                    $pendLetter = $null
                }
            }
        }
    } catch { }

    return $list
}

function Clear-DriveLetterMapping {
    # Thoroughly tear down a mapped/mounted drive letter so it disappears from
    # Explorer and does not reconnect at the next sign-in.
    #
    # Why several steps: a single Remove-SmbMapping / umount only removes the
    # mapping from the *calling* token's namespace and does not always purge
    # the persistent profile entry. To make the drive truly gone we also:
    #   * run `net use <letter> /delete /y` (clears the live mapping + profile),
    #   * delete the persistent HKCU:\Network\<letter> registry key,
    #   * when elevated, repeat the delete in the *interactive* (non-elevated)
    #     token via a one-off scheduled task, so Explorer's namespace clears.
    #
    # Returns $true if the letter is no longer a drive afterwards.
    param([string]$Letter)

    $bare = $Letter.TrimEnd(':','\').ToUpper()    # e.g. "Z"
    $dev  = "$bare`:"                              # e.g. "Z:"

    # 1. net use /delete in the current token (covers SMB and NFS letters).
    & net use $dev /delete /y 2>$null | Out-Null

    # 2. Remove the persistent reconnect entry so it doesn't return at logon.
    $regKey = "HKCU:\Network\$bare"
    if (Test-Path $regKey) {
        Remove-Item -Path $regKey -Force -Recurse -ErrorAction SilentlyContinue
    }

    # 3. If we're elevated, the interactive (Explorer) token has its own copy
    #    of the mapping. A one-off scheduled task running at the LIMITED run
    #    level executes `net use /delete` in that non-elevated token, so the
    #    drive also disappears from Explorer rather than going stale.
    if (Test-IsElevated) {
        $taskName = "win_util_drvclear_$bare"
        try {
            schtasks.exe /create /tn $taskName /tr "cmd.exe /c net use $dev /delete /y" `
                /sc once /st 00:00 /f /rl LIMITED 2>$null | Out-Null
            schtasks.exe /run /tn $taskName 2>$null | Out-Null
            Start-Sleep -Milliseconds 800
        } catch {
        } finally {
            schtasks.exe /delete /tn $taskName /f 2>$null | Out-Null
        }
    }

    return -not (Test-Path "$dev\")
}

function Invoke-DisconnectShare {
    Write-Host "  [Remove-SmbMapping / umount.exe]  Disconnect a mapped share" -ForegroundColor Cyan

    $entries = @()
    try {
        Get-SmbMapping -ErrorAction Stop | ForEach-Object {
            $entries += [pscustomobject]@{ Kind='SMB'; Local=$_.LocalPath; Remote=$_.RemotePath }
        }
    } catch { }

    $entries += @(Get-NfsMountEntries)

    if ($entries.Count -eq 0) {
        Write-Host "  No mapped shares found." -ForegroundColor Yellow
        # Drives mapped in a non-elevated session are invisible to an elevated
        # one (separate token namespaces). If we're elevated and the registry
        # mirror is off, the user's drives may simply be in the other token.
        if ((Test-IsElevated) -and -not (Test-LinkedConnectionsEnabled)) {
            Write-Host ""
            Write-Host "  Note: this session is elevated. If you see mapped drives in" -ForegroundColor DarkYellow
            Write-Host "  Explorer that aren't listed here, they were created in your" -ForegroundColor DarkYellow
            Write-Host "  non-elevated session and live in a separate drive namespace." -ForegroundColor DarkYellow
            Write-Host "  Disconnect them from a normal (non-admin) shell, or run the" -ForegroundColor DarkYellow
            Write-Host "  'Enable Linked Connections' utility and sign out/in." -ForegroundColor DarkYellow
        }
        $global:LASTEXITCODE = 0
        return
    }

    Write-Host ""
    for ($i = 0; $i -lt $entries.Count; $i++) {
        Write-Host ("    {0}) [{1}] {2}  ->  {3}" -f ($i + 1), $entries[$i].Kind, $entries[$i].Local, $entries[$i].Remote)
    }
    Write-Host "    0) Cancel"
    Write-Host ""
    Write-Host "  Tip: select multiple with commas/ranges (e.g. 1,3,5 or 2-4), or 'all'." -ForegroundColor DarkGray
    $sel = Read-Host "  Select share(s) to disconnect"

    if ([string]::IsNullOrWhiteSpace($sel) -or $sel.Trim() -eq '0') {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        $global:LASTEXITCODE = 0
        return
    }

    $targets = @(Resolve-IndexSelection -Selection $sel -Items $entries |
        Where-Object { $_ -is [pscustomobject] })

    if ($targets.Count -eq 0) {
        Write-Host "  No valid selection. Cancelled." -ForegroundColor Yellow
        $global:LASTEXITCODE = 0
        return
    }

    $ok = 0
    $fail = 0
    $removedLetters = @()   # drives actually torn down, for the Explorer refresh
    foreach ($target in $targets) {
        Write-Host ""
        Write-Host ("  Disconnecting [{0}] {1}  ->  {2}" -f $target.Kind, $target.Local, $target.Remote) -ForegroundColor Cyan
        try {
            if ($target.Kind -eq 'SMB') {
                # Primary removal in the current token. -UpdateProfile drops the
                # persistent reconnect entry. SilentlyContinue: a stale mapping
                # can already be half-gone; Clear-DriveLetterMapping finishes it.
                Remove-SmbMapping -LocalPath $target.Local -Force -UpdateProfile -ErrorAction SilentlyContinue
            } else {
                # Prefer the Windows NFS umount.exe (sibling of the NFS
                # mount.exe), avoiding the MSYS Git tool that may shadow it.
                $nfsMount = Get-NfsMountExe
                $umount = $null
                if ($nfsMount) {
                    $cand = Join-Path (Split-Path $nfsMount -Parent) 'umount.exe'
                    if (Test-Path $cand) { $umount = $cand }
                }
                if (-not $umount) { $umount = 'umount.exe' }

                & $umount -f $target.Local 2>$null | Out-Null

                # Clean the matching line from the persistence script if present.
                $script = Join-Path ([Environment]::GetFolderPath('Startup')) 'win_util_nfs_mounts.cmd'
                if (Test-Path $script) {
                    $kept = Get-Content $script | Where-Object { $_ -notmatch [regex]::Escape($target.Local) }
                    if ($kept) { Set-Content -Path $script -Value $kept -Encoding ASCII }
                    else       { Remove-Item $script -Force }
                }
            }

            # Common teardown for both SMB and NFS: net use /delete, purge the
            # persistent registry entry, and (when elevated) clear the drive in
            # the interactive token so it really disappears from Explorer.
            $gone = Clear-DriveLetterMapping -Letter $target.Local
            if ($gone) {
                Write-Host "  Disconnected $($target.Local) -no longer mapped." -ForegroundColor Green
                $removedLetters += $target.Local
            } else {
                Write-Host "  $($target.Local) disconnected, but the letter is still" -ForegroundColor Yellow
                Write-Host "  present. If it lingers in Explorer, sign out and back in." -ForegroundColor Yellow
            }
            $ok++
        } catch {
            Write-Host "  Disconnect failed: $($_.Exception.Message)" -ForegroundColor Red
            $fail++
        }
    }

    # Tell Explorer the drives are gone so their icons drop off any open
    # "This PC" window immediately, instead of lingering as stale entries.
    if ($removedLetters.Count -gt 0) {
        Update-ShellDriveView -Letters $removedLetters
    }

    Write-Host ""
    Write-Host ("  Done. Disconnected: {0}  Failed: {1}" -f $ok, $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
    $global:LASTEXITCODE = if ($fail -eq 0) { 0 } else { 1 }
}

#endregion

#region --- Menu plumbing ---

# Action-type utilities re-use install/uninstall/update slots. Test always
# returns $false so Enter routes to Install (= run the action).
#
# safeName mapping (Utility.Name with non-alphanumerics stripped):
#   "Map SMB Share"    -> MapSMBShare
#   "Mount NFS Share"  -> MountNFSShare
#   "List Shares"      -> ListShares
#   "Disconnect Share" -> DisconnectShare

function Install-MapSMBShare       { Invoke-MapSmbShare }
function Update-MapSMBShare        { Invoke-MapSmbShare }
function Uninstall-MapSMBShare     { Invoke-MapSmbShare }
function Test-MapSMBShare          { return $false }

function Install-MountNFSShare     { Invoke-MountNfsShare }
function Update-MountNFSShare      { Invoke-MountNfsShare }
function Uninstall-MountNFSShare   { Invoke-MountNfsShare }
function Test-MountNFSShare        { return $false }

function Install-ListShares        { Invoke-ListShares }
function Update-ListShares         { Invoke-ListShares }
function Uninstall-ListShares      { Invoke-ListShares }
function Test-ListShares           { return $false }

function Install-DisconnectShare   { Invoke-DisconnectShare }
function Update-DisconnectShare    { Invoke-DisconnectShare }
function Uninstall-DisconnectShare { Invoke-DisconnectShare }
function Test-DisconnectShare      { return $false }

# "Enable Linked Connections" -> EnableLinkedConnections
function Install-EnableLinkedConnections   { Invoke-EnableLinkedConnections }
function Update-EnableLinkedConnections    { Invoke-EnableLinkedConnections }
function Uninstall-EnableLinkedConnections { Invoke-EnableLinkedConnections }
function Test-EnableLinkedConnections      { return $false }

#endregion
