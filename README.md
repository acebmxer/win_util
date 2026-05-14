# win_util

```powershell
irm https://raw.githubusercontent.com/acebmxer/win_util/main/dist/win_util.ps1 | iex
```

Interactive TUI for installing, uninstalling, and updating common Windows software via winget. No setup required — works on any Windows system with internet access.

On first run, a **Win Util** shortcut is automatically added to your Desktop so you can relaunch the menu without re-pasting the command.

---

## Preview

```
╔══════════════════════════════════════════════════════════════════════╗
║  Windows Utilities Installer  |  win_util                            ║
║  Powered by winget  |  Use arrow keys to navigate                    ║
╠════════════════════╦═════════════════════════════════════════════════╣
║ CATEGORY           ║ UTILITY                                         ║
║ Browsers           ║ [ ] Google Chrome                not installed  ║
║ Tools              ║ [+] 7-Zip                        v24.09         ║
║ Media              ║ [ ] VLC Media Player             not installed  ║
║ Runtimes           ║                                                 ║
║ System             ║                                                 ║
╠════════════════════╩═════════════════════════════════════════════════╣
║  [SPACE] Toggle  [A] All  [D] None  [U] Update-All  [R] Refresh  [Q] ║
║  [ENTER] Install/Uninstall selected  [1 selected]                    ║
╚══════════════════════════════════════════════════════════════════════╝
```

| Key       | Action                              |
|-----------|-------------------------------------|
| `↑ ↓`     | Navigate items                      |
| `Tab`     | Switch between category / item panel|
| `Space`   | Toggle selection                    |
| `A` / `D` | Select / deselect all in category   |
| `Enter`   | Install or uninstall selected       |
| `U`       | Update all installed                |
| `R`       | Refresh installed status            |
| `Q`       | Quit                                |

---

## CLI Usage

```powershell
.\win_util.ps1 --install   "Google Chrome"
.\win_util.ps1 --uninstall "7-Zip"
.\win_util.ps1 --update    "VLC Media Player"
.\win_util.ps1 --update-all
.\win_util.ps1 --list
.\win_util.ps1 --check     "Java Runtime Environment"
```

---

## Adding a Utility

Add one line to `lib/utilities-list.ps1`:

```powershell
Register-Utility @{ Name = "App Name"; Id = "Winget.Package.Id"; Category = "Category" }
```

Find the winget ID with `winget search <name>`. Then run `.\Compile.ps1` or push to `main` — GitHub Actions auto-compiles `dist/win_util.ps1`.

For custom install logic, define `Install-SafeName` / `Uninstall-SafeName` anywhere in the loaded files and it will be picked up automatically.
