# Profile registry -curated presets that pre-populate the install queue.
#
# Each profile is a hashtable with Name, Description, and Items (an array of
# utility names that match Register-Utility entries). Profiles are applied
# from the menu sidebar: focus PROFILES, choose one, and press Enter.

$script:ProfileRegistry = [System.Collections.Generic.List[hashtable]]::new()

function Register-Profile {
    param([hashtable]$Definition)
    $script:ProfileRegistry.Add($Definition)
}

function Get-AllProfiles {
    return $script:ProfileRegistry
}

function Find-Profile {
    param([string]$Name)
    foreach ($p in $script:ProfileRegistry) {
        if ($p.Name -ieq $Name) { return $p }
    }
    return $null
}

# Resolve a profile's item names against the live utility registry and
# return matching utility hashtables. Names that don't resolve are ignored
# silently -useful when a profile lists optional packages.
function Resolve-ProfileItems {
    param([hashtable]$Profile)
    $resolved = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($name in $Profile.Items) {
        foreach ($u in Get-AllUtilities) {
            if ($u.Name -ieq $name) { $resolved.Add($u); break }
        }
    }
    return $resolved
}

# ── Curated Profiles ──────────────────────────────────────────────────────

Register-Profile @{
    Name        = "Run Me First"
    Description = "Baseline tools every Windows install benefits from"
    Items       = @(
        "7-Zip",
        "PowerToys",
        "Windows Terminal",
        "Microsoft Edge"
    )
}

Register-Profile @{
    Name        = "Default Physical PC"
    Description = "Desktop essentials - browser, archiver, media, system tools"
    Items       = @(
        "Google Chrome",
        "7-Zip",
        "VLC Media Player",
        "PowerToys",
        "Windows Terminal",
        "Notepad++",
        "ShareX",
        "Everything",
        "Spotify"
    )
}

Register-Profile @{
    Name        = "Developer Workstation"
    Description = "Editors, runtimes, version control, and container tooling"
    Items       = @(
        "Visual Studio Code",
        "Git",
        "GitHub CLI",
        "Windows Terminal",
        "PowerShell 7",
        "Docker Desktop",
        "Node.js LTS",
        "Python 3",
        "Postman",
        "DBeaver",
        "7-Zip",
        "PowerToys"
    )
}

Register-Profile @{
    Name        = "Home Desktop"
    Description = "Browser, office, messaging, media, and privacy tools"
    Items       = @(
        "Mozilla Firefox",
        "Thunderbird",
        "LibreOffice",
        "VLC Media Player",
        "Signal",
        "Bitwarden",
        "qBittorrent",
        "ProtonVPN",
        "Obsidian",
        "7-Zip",
        "ShareX"
    )
}

Register-Profile @{
    Name        = "Gaming Rig"
    Description = "Game launchers, voice chat, and performance tools"
    Items       = @(
        "Steam",
        "Epic Games Launcher",
        "GOG Galaxy",
        "Discord",
        "OBS Studio",
        "HWiNFO",
        "GPU-Z",
        "7-Zip"
    )
}
