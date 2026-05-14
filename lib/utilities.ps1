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
    $lines = winget list --id $Id --exact --accept-source-agreements 2>&1
    foreach ($line in $lines) {
        if ($line -match [regex]::Escape($Id)) {
            # winget list columns: Name | Id | Version | Available | Source
            $parts = $line -split '\s{2,}'
            if ($parts.Count -ge 3) { return $parts[2].Trim() }
        }
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
