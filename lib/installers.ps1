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
. (Join-Path $PSScriptRoot "utilities-list.ps1")  # COMPILE:SKIP
