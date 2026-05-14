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
