# Utility registry — defines Register-Utility and standard winget wrappers

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

    return @{
        Install    = if ($customInstall)    { $customInstall }    else { { Invoke-WingetInstall   $id }.GetNewClosure() }
        Uninstall  = if ($customUninstall)  { $customUninstall }  else { { Invoke-WingetUninstall $id }.GetNewClosure() }
        Update     = if ($customUpdate)     { $customUpdate }     else { { Invoke-WingetUpdate    $id }.GetNewClosure() }
        Test       = if ($customTest)       { $customTest }       else { { Test-WingetInstalled   $id }.GetNewClosure() }
        GetVersion = if ($customGetVersion) { $customGetVersion } else { { Get-WingetVersion      $id }.GetNewClosure() }
    }
}

# Load utility registrations
. (Join-Path $PSScriptRoot "utilities-list.ps1")  # COMPILE:SKIP
