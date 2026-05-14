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
