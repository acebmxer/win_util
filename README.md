oks # Windows System Setup & Utilities Installer

An interactive multi-select TUI for installing, uninstalling, and updating common Windows software via winget. Supports 60+ utilities organized by category, curated profiles for one-shot setups, and a live system-details sidebar. No setup required — works on any Windows machine with internet access.

```powershell
irm https://raw.githubusercontent.com/acebmxer/win_util/main/dist/win_util.ps1 | iex
```

On first run, a **Win Util** shortcut is added to your Desktop so you can relaunch the menu without re-pasting the command. The shortcut's icon is auto-synced from the upstream repo on every launch.

## Requirements

- Windows 10 (1809+) or Windows 11
- PowerShell 5.1 or PowerShell 7+
- `winget` (App Installer) — pre-installed on Windows 11; available from the Microsoft Store on Windows 10
- Internet connection for downloads
- An interactive terminal at least **78 columns × 24 rows** (for the TUI menu)

## Quick Start

Run it directly:

```powershell
irm https://raw.githubusercontent.com/acebmxer/win_util/main/dist/win_util.ps1 | iex
```

Or clone and run locally:

```powershell
git clone https://github.com/acebmxer/win_util.git
cd win_util
.\win_util.ps1
```

## CLI Flags

The script supports non-interactive use for scripting and automation:

| Flag | Description |
|------|-------------|
| `--help` | Show usage information |
| `--list` | List all utilities with current install status |
| `--list-profiles` | List curated profiles and their contents |
| `--sys-info` | Print host / OS / CPU / memory / disk / uptime |
| `--install <name>` | Install a utility by name |
| `--uninstall <name>` | Uninstall a utility by name |
| `--update <name>` | Update a utility by name |
| `--update-all` | Update every currently installed utility |
| `--check <name>` | Print installation status (and version, if installed) |
| `--apply-profile <name>` | Install every utility in a profile (already-installed items are skipped) |

Utility and profile names are matched case-insensitively. Names that contain spaces must be quoted.

```powershell
.\win_util.ps1 --list
.\win_util.ps1 --check         "Docker Desktop"
.\win_util.ps1 --install       "Visual Studio Code"
.\win_util.ps1 --apply-profile "Developer Workstation"
.\win_util.ps1 --update-all
```

## Interactive Menu

The TUI uses a two-panel layout: a left sidebar with **Categories**, **Profiles**, and a **System Details** pane, and a right panel listing items with a description pane underneath. Version numbers are shown inline for installed utilities.

```
╔══════════════════════╦══════════════════════════════════════════════════╗
║  Windows Utilities Installer  |  win_util                               ║
║  Powered by winget  |  Tab=switch focus  |  Q=quit                      ║
╠══════════════════════╦══════════════════════════════════════════════════╣
║ SIDEBAR              ║ Development                                      ║
╠══════════════════════╣  [ ]  Visual Studio Code         not installed   ║
║ CATEGORIES           ║  [+]  Git                        v2.45.2         ║
║ ────────────────     ║  [ ]  GitHub CLI                 not installed   ║
║   > Browsers         ║  [+]  Windows Terminal           v1.21.3231      ║
║     Development      ║  [ ]  Docker Desktop             not installed   ║
║     Internet         ║  [ ]  Node.js LTS                not installed   ║
║     Media            ║  [ ]  Python 3                   not installed   ║
║     Productivity     ║                                                  ║
║     Gaming           ║                                                  ║
║     System Tools     ║                                                  ║
║     Runtimes         ║                                                  ║
║                      ║                                                  ║
║ PROFILES             ║                                                  ║
║ ────────────────     ║                                                  ║
║     Run Me First     ║                                                  ║
║     Default Phys. PC ║                                                  ║
║     Developer WS.    ║                                                  ║
║     Home Desktop     ║                                                  ║
║     Gaming Rig       ║                                                  ║
║                      ║                                                  ║
║ SYSTEM Details       ║                                                  ║
║ ────────────────     ║                                                  ║
║    Host: WIN-DESKTOP ║                                                  ║
║      OS: Windows 11  ║                                                  ║
║  Kernel: 10.0.26200  ║──────────────────────────────────────────────────║
║     CPU: i9-14900K   ║  Microsoft's extensible code editor.             ║
║     Mem: 12.4G/32G   ║                                                  ║
║    Disk: 245G/931G   ║                                                  ║
║  Uptime: 3d 12h      ║                                                  ║
╠══════════════════════╩══════════════════════════════════════════════════╣
║  [SPACE] Toggle  [A] All  [D] None  [U] Update-All  [R] Refresh  [Q]    ║
║  [ENTER] Install/Uninstall (or apply profile)  [1 selected]             ║
╚═════════════════════════════════════════════════════════════════════════╝
```

### Controls

| Key | Action |
|-----|--------|
| ↑ / ↓ | Navigate items (or sidebar entries, when focused) |
| ← / → | Move focus between sidebar and items |
| `Tab` | Toggle focus between sidebar and items |
| `Space` | Toggle selection on the focused item |
| `A` / `D` | Select / deselect all in the current category |
| `Enter` | Install/uninstall selected items (or apply a profile when one is highlighted) |
| `U` | Update every currently installed utility |
| `R` | Refresh installed status and system info |
| `Q` | Quit |

### Selection Logic

| Checkbox | Installed? | Action on Enter |
|----------|------------|-----------------|
| `[+]`    | No         | **Install** |
| `[+]`    | Yes        | **Uninstall** |
| `[ ]`    | Either     | Skip |

If every selected item is already installed, Enter triggers an **uninstall** run; otherwise it triggers an **install** run.

## Available Utilities

### Browsers

| Utility | Description |
|---------|-------------|
| **Google Chrome** | Google's browser with sync and developer tools |
| **Mozilla Firefox** | Mozilla's open-source browser |
| **Microsoft Edge** | Microsoft's Chromium-based browser |
| **Brave Browser** | Privacy-focused Chromium browser with built-in ad blocking |
| **Vivaldi** | Highly customizable Chromium browser |
| **LibreWolf** | Privacy-hardened Firefox fork |
| **Tor Browser** | Anonymous browsing via the Tor network |

### Development

| Utility | Description |
|---------|-------------|
| **Visual Studio Code** | Microsoft's extensible code editor |
| **Cursor** | AI-powered code editor built on VS Code |
| **Git** | Distributed version control system |
| **GitHub CLI** | Official CLI for GitHub — repos, issues, PRs, workflows |
| **GitHub Desktop** | GUI client for managing GitHub repositories |
| **Docker Desktop** | Container platform for Windows with WSL2 backend |
| **Node.js LTS** | JavaScript runtime — LTS release |
| **Python 3** | Python programming language runtime |
| **Go SDK** | Official Go programming language toolchain |
| **Rustup** | Rust toolchain installer and version manager |
| **Neovim** | Extensible Vim-based text editor |
| **Windows Terminal** | Modern terminal emulator with tabs and profiles |
| **PowerShell 7** | Cross-platform PowerShell (`pwsh`) |
| **DBeaver** | Universal database management tool |
| **Postman** | API development and testing platform |
| **JetBrains Toolbox** | Manager for JetBrains IDEs |

### Internet / Communication

| Utility | Description |
|---------|-------------|
| **Discord** | Voice, video, and text communication platform |
| **Slack** | Team messaging and collaboration platform |
| **Microsoft Teams** | Workplace chat, meetings, and collaboration |
| **Zoom** | Video conferencing and collaboration platform |
| **Signal** | End-to-end encrypted messaging |
| **Telegram** | Cloud-based messaging with groups and channels |
| **Thunderbird** | Mozilla's email client with calendar and PGP |
| **FileZilla** | FTP, FTPS, and SFTP client |
| **qBittorrent** | Open-source BitTorrent client |
| **ProtonVPN** | Free and open-source VPN by Proton |
| **Tailscale** | Zero-config mesh VPN built on WireGuard |
| **AnyDesk** | Remote desktop application |
| **RustDesk** | Open-source remote desktop and remote assistance tool |

### Media

| Utility | Description |
|---------|-------------|
| **VLC Media Player** | Versatile media player supporting virtually all formats |
| **Spotify** | Music streaming service |
| **OBS Studio** | Video recording and live streaming |
| **Audacity** | Open-source audio editor and recorder |
| **HandBrake** | Open-source video transcoder |
| **GIMP** | GNU Image Manipulation Program |
| **Inkscape** | Professional vector graphics editor |
| **Krita** | Professional digital painting application |
| **Blender** | Open-source 3D creation suite |

### Productivity

| Utility | Description |
|---------|-------------|
| **LibreOffice** | Open-source office suite |
| **OnlyOffice** | Office suite with MS Office format compatibility |
| **Notepad++** | Source-code editor with syntax highlighting |
| **Obsidian** | Markdown-based knowledge base with graphs and plugins |
| **Joplin** | Note-taking app with Markdown and sync |
| **Logseq** | Privacy-first knowledge management and outliner |
| **Bitwarden** | Open-source password manager |
| **Nextcloud Desktop** | Sync client for self-hosted Nextcloud storage |
| **ShareX** | Screenshot and screen recording tool |

### Gaming

| Utility | Description |
|---------|-------------|
| **Steam** | Valve's gaming platform |
| **Epic Games Launcher** | Epic Games store and launcher |
| **GOG Galaxy** | GOG.com client and unified game library |
| **Heroic Games Launcher** | Open-source launcher for Epic, GOG, and Amazon Prime Gaming |
| **Ubisoft Connect** | Ubisoft's game launcher and store |
| **Battle.net** | Blizzard's game launcher and store |

### System Tools

| Utility | Description |
|---------|-------------|
| **7-Zip** | File archiver with high compression ratio |
| **WinRAR** | Archive manager for RAR and ZIP files |
| **PowerToys** | Microsoft's productivity utilities (FancyZones, PowerRename, etc.) |
| **Sysinternals Suite** | Microsoft's collection of Windows diagnostic utilities |
| **Everything** | Instant file and folder search by name |
| **WizTree** | Fast disk space analyzer reading the MFT directly |
| **WinDirStat** | Disk usage statistics and cleanup tool |
| **CPU-Z** | CPU, memory, and motherboard information utility |
| **GPU-Z** | GPU information and monitoring utility |
| **HWiNFO** | Comprehensive hardware analysis and monitoring |
| **Rufus** | Create bootable USB drives from ISOs |
| **Ventoy** | Bootable USB tool — boot multiple ISOs from one drive |

### Runtimes

| Utility | Description |
|---------|-------------|
| **Java Runtime Environment** | Oracle Java Runtime Environment |
| **OpenJDK 21** | Microsoft Build of OpenJDK 21 (LTS) |
| **.NET 8 SDK** | Microsoft .NET 8 SDK |
| **VCRedist 2015+ x64** | Visual C++ Redistributable for 2015–2022 (x64) |
| **DirectX End-User Runtime** | DirectX End-User Runtime web installer |

## Profiles

Profiles are curated presets that pre-populate the install queue in one step. They appear in the left sidebar below `CATEGORIES` — press `Tab` to focus the sidebar, `↑`/`↓` to navigate into `PROFILES`, then `Enter` to apply.

Applying a profile clears all current selections and queues the profile's items. Items already installed will be skipped when you press Enter on the items panel.

| Profile | Description |
|---------|-------------|
| **Run Me First** | Baseline tools every Windows install benefits from — 7-Zip, PowerToys, Windows Terminal, Microsoft Edge |
| **Default Physical PC** | Desktop essentials — Chrome, 7-Zip, VLC, PowerToys, Windows Terminal, Notepad++, ShareX, Everything, Spotify |
| **Developer Workstation** | VS Code, Git, GitHub CLI, Windows Terminal, PowerShell 7, Docker Desktop, Node.js LTS, Python 3, Postman, DBeaver, 7-Zip, PowerToys |
| **Home Desktop** | Firefox, Thunderbird, LibreOffice, VLC, Signal, Bitwarden, qBittorrent, ProtonVPN, Obsidian, 7-Zip, ShareX |
| **Gaming Rig** | Steam, Epic Games Launcher, GOG Galaxy, Discord, OBS Studio, HWiNFO, GPU-Z, 7-Zip |

To add your own profile, append a `Register-Profile` block in [`lib/profiles.ps1`](lib/profiles.ps1):

```powershell
Register-Profile @{
    Name        = "My Profile"
    Description = "Short description shown in the menu."
    Items       = @(
        "Visual Studio Code",
        "Git",
        "7-Zip"
    )
}
```

Item names must match the `Name` field of a `Register-Utility` entry. Names that don't resolve are silently ignored so a profile can mention optional tools without breaking on machines that don't have them registered.

## System Details

The `SYSTEM Details` sidebar pane shows live host information sourced from CIM/WMI (`Win32_OperatingSystem`, `Win32_Processor`, `Win32_LogicalDisk`):

| Field | Source |
|-------|--------|
| Host | `[Environment]::MachineName` |
| OS | `Win32_OperatingSystem.Caption` |
| Kernel | `Win32_OperatingSystem.Version` |
| CPU | `Win32_Processor.Name` (trimmed for sidebar width) |
| Mem | Used / total physical memory |
| Disk | Used / total for `%SystemDrive%` |
| Uptime | Time since last boot |

System details refresh whenever you press `R` in the menu. From the CLI, `--sys-info` prints the same values.

## Logging

Every run writes a timestamped log file to `logs/win_util_YYYYMMDD_HHMMSS.log` containing per-utility install/uninstall/update outcomes and a session summary.

When the script is run via `irm | iex` (no local checkout), `$PSScriptRoot` is empty so logs are written to `%TEMP%\win_util_logs\` instead.

## Project Structure

```
win_util/
├── win_util.ps1           Main script — CLI parsing, bootstrap, entry point
├── Compile.ps1            Bundles lib/* into dist/win_util.ps1 for irm | iex
├── dist/win_util.ps1      Compiled single-file distributable
├── assets/                Desktop-shortcut icon and SHA256 manifest
├── lib/
│   ├── logging.ps1        Timestamped session log file
│   ├── sysinfo.ps1        Host / OS / CPU / mem / disk / uptime
│   ├── utilities.ps1      Registry + winget wrappers + custom-function dispatch
│   ├── utilities-list.ps1 Register-Utility calls — one line per utility
│   ├── installers.ps1     Custom Install-/Uninstall-/Update- overrides
│   ├── profiles.ps1       Profile registry and curated profiles
│   └── menu.ps1           TUI rendering, sidebar layout, keyboard navigation
├── scripts/build-icon.ps1 Regenerates the multi-resolution .ico
└── logs/                  Timestamped execution logs
```

### Module Responsibilities

| Module | Purpose | Edit When… |
|--------|---------|------------|
| `win_util.ps1` | Entry point, CLI parsing, desktop shortcut sync | Adding new CLI flags or changing bootstrap |
| `lib/logging.ps1` | Session log file and summary writer | Changing log format |
| `lib/sysinfo.ps1` | System details sidebar values | Adding new sidebar fields |
| `lib/utilities.ps1` | `Register-Utility`, winget wrappers, custom-function lookup | Adding new winget verbs or registry features |
| `lib/utilities-list.ps1` | All registered utilities | **Adding or removing a utility** |
| `lib/installers.ps1` | Per-utility install overrides for tools winget can't handle alone | Writing custom install/uninstall logic |
| `lib/profiles.ps1` | Curated profiles | **Adding or modifying a profile** |
| `lib/menu.ps1` | TUI rendering and keyboard navigation | Changing menu appearance or navigation |
| `Compile.ps1` | Bundles `lib/*.ps1` into `dist/win_util.ps1` | Adding a new lib file |

## Adding a Utility

Add one line to [`lib/utilities-list.ps1`](lib/utilities-list.ps1):

```powershell
Register-Utility @{
    Name        = "App Name"
    Id          = "Winget.Package.Id"
    Category    = "Category"
    Description = "One-line description for the menu's description pane."
}
```

Find the winget id with `winget search <name>`. Then run `.\Compile.ps1` or push to `main` — GitHub Actions auto-compiles `dist/win_util.ps1`.

For tools where the default `winget install --id <Id>` doesn't work (custom installers, post-install steps, etc.), define `Install-SafeName` / `Uninstall-SafeName` / `Update-SafeName` / `Test-SafeName` / `Get-SafeNameVersion` functions anywhere in the loaded files. `SafeName` is the utility's `Name` with all non-alphanumeric characters stripped. The custom function is picked up automatically and used in place of the default winget wrapper.

```powershell
# Example custom installer for "My App"
function Install-MyApp {
    # ...custom logic...
    return $LASTEXITCODE
}
```

## Troubleshooting

**`winget is not available`** — winget is bundled with App Installer. Install it from the Microsoft Store (search for "App Installer") or update Windows.

**Terminal too small** — the TUI requires at least 78 columns × 24 rows. Resize the window and the menu will redraw automatically.

**Package installation fails** — open the log in `logs/` for the winget exit code and message. Common causes: package id changed (run `winget search <name>` to confirm), elevation required, or the source agreement hasn't been accepted (re-run the script and accept).

**Profile items missing** — when you apply a profile, items unavailable on this machine (or unregistered) are reported in the status line. Edit `lib/profiles.ps1` and remove or rename them.

## License

This project is licensed under the [MIT License](LICENSE).
