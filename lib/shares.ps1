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

#endregion

#region --- SMB ---

function Invoke-MapSmbShare {
    Write-Host "  [New-SmbMapping]  Map an SMB / CIFS share" -ForegroundColor Cyan

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

    # Pre-allocate one drive letter per share; the user can override the first
    # and we auto-pick subsequent free letters.
    $suggested = Get-AvailableDriveLetter
    $letterIn  = Read-Host "  Drive letter to assign first mount [default: $suggested]"
    if ([string]::IsNullOrWhiteSpace($letterIn)) { $letterIn = $suggested }
    $firstLetter = $letterIn.TrimEnd(':','\').ToUpper()
    if ($firstLetter.Length -ne 1 -or $firstLetter -notmatch '^[A-Z]$') {
        Write-Host "  Invalid drive letter '$letterIn'." -ForegroundColor Red
        $global:LASTEXITCODE = 1
        return
    }

    $assignments = @()
    $usedLetters = @()
    foreach ($sh in $selectedShares) {
        $letter = $null
        if ($assignments.Count -eq 0) {
            $letter = $firstLetter
        } else {
            foreach ($c in [char[]]('ZYXWVUTSRQPONMLKJIHGFED')) {
                $cand = "$c"
                if ($usedLetters -notcontains $cand -and (Test-DriveLetterFree "$cand`:")) {
                    $letter = $cand; break
                }
            }
        }
        if (-not $letter) {
            Write-Host "  Ran out of available drive letters." -ForegroundColor Red
            $global:LASTEXITCODE = 1
            return
        }
        if (($usedLetters -contains $letter) -or -not (Test-DriveLetterFree "$letter`:")) {
            Write-Host "  Drive $letter`: is already in use." -ForegroundColor Red
            $global:LASTEXITCODE = 1
            return
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
    $global:LASTEXITCODE = if ($fail -eq 0) { 0 } else { 1 }
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

    # Pre-allocate one drive letter per export; the user can override the first
    # and we auto-pick subsequent free letters.
    $suggested = Get-AvailableDriveLetter
    $letterIn  = Read-Host "  Drive letter to assign first mount [default: $suggested]"
    if ([string]::IsNullOrWhiteSpace($letterIn)) { $letterIn = $suggested }
    $firstLetter = $letterIn.TrimEnd(':','\').ToUpper()
    if ($firstLetter.Length -ne 1 -or $firstLetter -notmatch '^[A-Z]$') {
        Write-Host "  Invalid drive letter '$letterIn'." -ForegroundColor Red
        $global:LASTEXITCODE = 1
        return
    }

    $assignments = @()
    $usedLetters = @()
    foreach ($exp in $selectedExports) {
        $letter = $null
        if ($assignments.Count -eq 0) {
            $letter = $firstLetter
        } else {
            foreach ($c in [char[]]('ZYXWVUTSRQPONMLKJIHGFED')) {
                $cand = "$c"
                if ($usedLetters -notcontains $cand -and (Test-DriveLetterFree "$cand`:")) {
                    $letter = $cand; break
                }
            }
        }
        if (-not $letter) {
            Write-Host "  Ran out of available drive letters." -ForegroundColor Red
            $global:LASTEXITCODE = 1
            return
        }
        if (($usedLetters -contains $letter) -or -not (Test-DriveLetterFree "$letter`:")) {
            Write-Host "  Drive $letter`: is already in use." -ForegroundColor Red
            $global:LASTEXITCODE = 1
            return
        }
        $usedLetters += $letter
        $unc = "\\$server" + ($exp -replace '/', '\')
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

    $ok = 0
    $fail = 0
    foreach ($a in $assignments) {
        Write-Host ""
        Write-Host ("  Mounting {0} -> {1}:" -f $a.Unc, $a.Letter) -ForegroundColor Cyan

        # -o anon mounts without sending UID/GID (anonymous). For UID-mapped access,
        # users can set AnonymousUid/Gid in HKLM\Software\Microsoft\ClientForNFS\...
        $mountArgs = @('-o','anon')
        if ($persistent) { $mountArgs += @('-o','fileaccess=755','-o','rsize=32','-o','wsize=32') }
        $mountArgs += @($a.Unc, "$($a.Letter):")

        try {
            & mount.exe @mountArgs
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Mounted $($a.Unc) to $($a.Letter):" -ForegroundColor Green
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
        return ,$picked
    }

    return ,@($s)
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

    if (Get-Command 'mount.exe' -ErrorAction SilentlyContinue) {
        Write-Host ""
        Write-Host "  [mount.exe]  Mounted NFS shares:" -ForegroundColor Cyan
        try {
            $nfsOut = & mount.exe 2>$null
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

function Invoke-DisconnectShare {
    Write-Host "  [Remove-SmbMapping / umount.exe]  Disconnect a mapped share" -ForegroundColor Cyan

    $entries = @()
    try {
        Get-SmbMapping -ErrorAction Stop | ForEach-Object {
            $entries += [pscustomobject]@{ Kind='SMB'; Local=$_.LocalPath; Remote=$_.RemotePath }
        }
    } catch { }

    if (Get-Command 'mount.exe' -ErrorAction SilentlyContinue) {
        try {
            $nfsOut = & mount.exe 2>$null
            if ($LASTEXITCODE -eq 0 -and $nfsOut) {
                foreach ($line in $nfsOut) {
                    # Typical line: "Z:    \\server\export    UID, GID, ..."
                    if ($line -match '^([A-Za-z]):\s+(\\\\\S+)') {
                        $entries += [pscustomobject]@{ Kind='NFS'; Local="$($matches[1]):"; Remote=$matches[2] }
                    }
                }
            }
        } catch { }
    }

    if ($entries.Count -eq 0) {
        Write-Host "  No mapped shares found." -ForegroundColor Yellow
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
    foreach ($target in $targets) {
        Write-Host ""
        Write-Host ("  Disconnecting [{0}] {1}  ->  {2}" -f $target.Kind, $target.Local, $target.Remote) -ForegroundColor Cyan
        try {
            if ($target.Kind -eq 'SMB') {
                Remove-SmbMapping -LocalPath $target.Local -Force -UpdateProfile -ErrorAction Stop
                Write-Host "  Disconnected $($target.Local)." -ForegroundColor Green
            } else {
                & umount.exe $target.Local
                if ($LASTEXITCODE -ne 0) { throw "umount.exe exited $LASTEXITCODE" }
                Write-Host "  Unmounted $($target.Local)." -ForegroundColor Green

                # Clean the matching line from the persistence script if present.
                $script = Join-Path ([Environment]::GetFolderPath('Startup')) 'win_util_nfs_mounts.cmd'
                if (Test-Path $script) {
                    $kept = Get-Content $script | Where-Object { $_ -notmatch [regex]::Escape($target.Local) }
                    if ($kept) { Set-Content -Path $script -Value $kept -Encoding ASCII }
                    else       { Remove-Item $script -Force }
                }
            }
            $ok++
        } catch {
            Write-Host "  Disconnect failed: $($_.Exception.Message)" -ForegroundColor Red
            $fail++
        }
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

#endregion
