# All registered utilities -add a Register-Utility line to add a new tool.
# Custom install/uninstall/update/test logic: define Install-SafeName, etc. anywhere in the loaded files.
#
# Fields: Name, Id (winget package id), Category, Description (one-line)

# ── Browsers ──────────────────────────────────────────────────────────────
Register-Utility @{ Name = "Google Chrome";            Id = "Google.Chrome";                          Category = "Browsers";    Description = "Google's browser with sync and developer tools" }
Register-Utility @{ Name = "Mozilla Firefox";          Id = "Mozilla.Firefox";                        Category = "Browsers";    Description = "Mozilla's open-source browser" }
Register-Utility @{ Name = "Microsoft Edge";           Id = "Microsoft.Edge";                         Category = "Browsers";    Description = "Microsoft's Chromium-based browser" }
Register-Utility @{ Name = "Brave Browser";            Id = "Brave.Brave";                            Category = "Browsers";    Description = "Privacy-focused Chromium browser with built-in ad blocking" }
Register-Utility @{ Name = "Vivaldi";                  Id = "Vivaldi.Vivaldi";                        Category = "Browsers";    Description = "Highly customizable Chromium browser" }
Register-Utility @{ Name = "LibreWolf";                Id = "LibreWolf.LibreWolf";                    Category = "Browsers";    Description = "Privacy-hardened Firefox fork" }
Register-Utility @{ Name = "Tor Browser";              Id = "TorProject.TorBrowser";                  Category = "Browsers";    Description = "Anonymous browsing via the Tor network" }

# ── Development ───────────────────────────────────────────────────────────
Register-Utility @{ Name = "Visual Studio Code";       Id = "Microsoft.VisualStudioCode";             Category = "Development"; Description = "Microsoft's extensible code editor" }
Register-Utility @{ Name = "Cursor";                   Id = "Anysphere.Cursor";                       Category = "Development"; Description = "AI-powered code editor built on VS Code" }
Register-Utility @{ Name = "Git";                      Id = "Git.Git";                                Category = "Development"; Description = "Distributed version control system" }
Register-Utility @{ Name = "GitHub CLI";               Id = "GitHub.cli";                             Category = "Development"; Description = "Official CLI for GitHub -repos, issues, PRs, workflows" }
Register-Utility @{ Name = "GitHub Desktop";           Id = "GitHub.GitHubDesktop";                   Category = "Development"; Description = "GUI client for managing GitHub repositories" }
Register-Utility @{ Name = "Docker Desktop";           Id = "Docker.DockerDesktop";                   Category = "Development"; Description = "Container platform for Windows with WSL2 backend" }
Register-Utility @{ Name = "Node.js LTS";              Id = "OpenJS.NodeJS.LTS";                      Category = "Development"; Description = "JavaScript runtime -LTS release" }
Register-Utility @{ Name = "Python 3";                 Id = "Python.Python.3.12";                     Category = "Development"; Description = "Python programming language runtime" }
Register-Utility @{ Name = "Go SDK";                   Id = "GoLang.Go";                              Category = "Development"; Description = "Official Go programming language toolchain" }
Register-Utility @{ Name = "Rustup";                   Id = "Rustlang.Rustup";                        Category = "Development"; Description = "Rust toolchain installer and version manager" }
Register-Utility @{ Name = "Neovim";                   Id = "Neovim.Neovim";                          Category = "Development"; Description = "Extensible Vim-based text editor" }
Register-Utility @{ Name = "Windows Terminal";         Id = "Microsoft.WindowsTerminal";              Category = "Development"; Description = "Modern terminal emulator with tabs and profiles" }
Register-Utility @{ Name = "PowerShell 7";             Id = "Microsoft.PowerShell";                   Category = "Development"; Description = "Cross-platform PowerShell (pwsh)" }
Register-Utility @{ Name = "DBeaver";                  Id = "dbeaver.dbeaver";                        Category = "Development"; Description = "Universal database management tool" }
Register-Utility @{ Name = "Postman";                  Id = "Postman.Postman";                        Category = "Development"; Description = "API development and testing platform" }
Register-Utility @{ Name = "JetBrains Toolbox";        Id = "JetBrains.Toolbox";                      Category = "Development"; Description = "Manager for JetBrains IDEs" }

# ── Internet / Communication ──────────────────────────────────────────────
Register-Utility @{ Name = "Discord";                  Id = "Discord.Discord";                        Category = "Internet";    Description = "Voice, video, and text communication platform" }
Register-Utility @{ Name = "Slack";                    Id = "SlackTechnologies.Slack";                Category = "Internet";    Description = "Team messaging and collaboration platform" }
Register-Utility @{ Name = "Microsoft Teams";          Id = "Microsoft.Teams";                        Category = "Internet";    Description = "Workplace chat, meetings, and collaboration" }
Register-Utility @{ Name = "Zoom";                     Id = "Zoom.Zoom";                              Category = "Internet";    Description = "Video conferencing and collaboration platform" }
Register-Utility @{ Name = "Signal";                   Id = "OpenWhisperSystems.Signal";              Category = "Internet";    Description = "End-to-end encrypted messaging" }
Register-Utility @{ Name = "Telegram";                 Id = "Telegram.TelegramDesktop";               Category = "Internet";    Description = "Cloud-based messaging with groups and channels" }
Register-Utility @{ Name = "Thunderbird";              Id = "Mozilla.Thunderbird";                    Category = "Internet";    Description = "Mozilla's email client with calendar and PGP" }
Register-Utility @{ Name = "FileZilla";                Id = "TimKosse.FileZilla.Client";              Category = "Internet";    Description = "FTP, FTPS, and SFTP client" }
Register-Utility @{ Name = "qBittorrent";              Id = "qBittorrent.qBittorrent";                Category = "Internet";    Description = "Open-source BitTorrent client" }
Register-Utility @{ Name = "ProtonVPN";                Id = "Proton.ProtonVPN";                       Category = "Internet";    Description = "Free and open-source VPN by Proton" }
Register-Utility @{ Name = "Tailscale";                Id = "tailscale.tailscale";                    Category = "Internet";    Description = "Zero-config mesh VPN built on WireGuard" }
Register-Utility @{ Name = "AnyDesk";                  Id = "AnyDeskSoftwareGmbH.AnyDesk";            Category = "Internet";    Description = "Remote desktop application" }
Register-Utility @{ Name = "RustDesk";                 Id = "RustDesk.RustDesk";                      Category = "Internet";    Description = "Open-source remote desktop and remote assistance tool" }

# ── Media ─────────────────────────────────────────────────────────────────
Register-Utility @{ Name = "VLC Media Player";         Id = "VideoLAN.VLC";                           Category = "Media";       Description = "Versatile media player supporting virtually all formats" }
Register-Utility @{ Name = "Spotify";                  Id = "Spotify.Spotify";                        Category = "Media";       Description = "Music streaming service" }
Register-Utility @{ Name = "OBS Studio";               Id = "OBSProject.OBSStudio";                   Category = "Media";       Description = "Video recording and live streaming" }
Register-Utility @{ Name = "Audacity";                 Id = "Audacity.Audacity";                      Category = "Media";       Description = "Open-source audio editor and recorder" }
Register-Utility @{ Name = "HandBrake";                Id = "HandBrake.HandBrake";                    Category = "Media";       Description = "Open-source video transcoder" }
Register-Utility @{ Name = "GIMP";                     Id = "GIMP.GIMP";                              Category = "Media";       Description = "GNU Image Manipulation Program" }
Register-Utility @{ Name = "Inkscape";                 Id = "Inkscape.Inkscape";                      Category = "Media";       Description = "Professional vector graphics editor" }
Register-Utility @{ Name = "Krita";                    Id = "KDE.Krita";                              Category = "Media";       Description = "Professional digital painting application" }
Register-Utility @{ Name = "Blender";                  Id = "BlenderFoundation.Blender";              Category = "Media";       Description = "Open-source 3D creation suite" }

# ── Productivity ──────────────────────────────────────────────────────────
Register-Utility @{ Name = "LibreOffice";              Id = "TheDocumentFoundation.LibreOffice";      Category = "Productivity"; Description = "Open-source office suite" }
Register-Utility @{ Name = "OnlyOffice";               Id = "ONLYOFFICE.DesktopEditors";              Category = "Productivity"; Description = "Office suite with MS Office format compatibility" }
Register-Utility @{ Name = "Notepad++";                Id = "Notepad++.Notepad++";                    Category = "Productivity"; Description = "Source-code editor with syntax highlighting" }
Register-Utility @{ Name = "Obsidian";                 Id = "Obsidian.Obsidian";                      Category = "Productivity"; Description = "Markdown-based knowledge base with graphs and plugins" }
Register-Utility @{ Name = "Joplin";                   Id = "Joplin.Joplin";                          Category = "Productivity"; Description = "Note-taking app with Markdown and sync" }
Register-Utility @{ Name = "Logseq";                   Id = "Logseq.Logseq";                          Category = "Productivity"; Description = "Privacy-first knowledge management and outliner" }
Register-Utility @{ Name = "Bitwarden";                Id = "Bitwarden.Bitwarden";                    Category = "Productivity"; Description = "Open-source password manager" }
Register-Utility @{ Name = "Nextcloud Desktop";        Id = "Nextcloud.NextcloudDesktop";             Category = "Productivity"; Description = "Sync client for self-hosted Nextcloud storage" }
Register-Utility @{ Name = "ShareX";                   Id = "ShareX.ShareX";                          Category = "Productivity"; Description = "Screenshot and screen recording tool" }

# ── Gaming ────────────────────────────────────────────────────────────────
Register-Utility @{ Name = "Steam";                    Id = "Valve.Steam";                            Category = "Gaming";      Description = "Valve's gaming platform" }
Register-Utility @{ Name = "Epic Games Launcher";      Id = "EpicGames.EpicGamesLauncher";            Category = "Gaming";      Description = "Epic Games store and launcher" }
Register-Utility @{ Name = "GOG Galaxy";               Id = "GOG.Galaxy";                             Category = "Gaming";      Description = "GOG.com client and unified game library" }
Register-Utility @{ Name = "Heroic Games Launcher";    Id = "HeroicGamesLauncher.HeroicGamesLauncher"; Category = "Gaming";     Description = "Open-source launcher for Epic, GOG, and Amazon Prime Gaming" }
Register-Utility @{ Name = "Ubisoft Connect";          Id = "Ubisoft.Connect";                        Category = "Gaming";      Description = "Ubisoft's game launcher and store" }
Register-Utility @{ Name = "Battle.net";               Id = "Blizzard.BattleNet";                     Category = "Gaming";      Description = "Blizzard's game launcher and store" }

# ── System Tools ──────────────────────────────────────────────────────────
Register-Utility @{ Name = "7-Zip";                    Id = "7zip.7zip";                              Category = "System Tools"; Description = "File archiver with high compression ratio" }
Register-Utility @{ Name = "WinRAR";                   Id = "RARLab.WinRAR";                          Category = "System Tools"; Description = "Archive manager for RAR and ZIP files" }
Register-Utility @{ Name = "PowerToys";                Id = "Microsoft.PowerToys";                    Category = "System Tools"; Description = "Microsoft's productivity utilities (FancyZones, PowerRename, etc.)" }
Register-Utility @{ Name = "Sysinternals Suite";       Id = "Microsoft.Sysinternals.Suite";           Category = "System Tools"; Description = "Microsoft's collection of Windows diagnostic utilities" }
Register-Utility @{ Name = "Everything";               Id = "voidtools.Everything";                   Category = "System Tools"; Description = "Instant file and folder search by name" }
Register-Utility @{ Name = "CPU-Z";                    Id = "CPUID.CPU-Z";                            Category = "System Tools"; Description = "CPU, memory, and motherboard information utility" }
Register-Utility @{ Name = "GPU-Z";                    Id = "TechPowerUp.GPU-Z";                      Category = "System Tools"; Description = "GPU information and monitoring utility" }
Register-Utility @{ Name = "HWiNFO";                   Id = "REALiX.HWiNFO";                          Category = "System Tools"; Description = "Comprehensive hardware analysis and monitoring" }

# ── Disk Utilities ────────────────────────────────────────────────────────
Register-Utility @{ Name = "WizTree";                  Id = "AntibodySoftware.WizTree";               Category = "Disk Utilities"; Description = "Fast disk space analyzer reading the MFT directly" }
Register-Utility @{ Name = "WinDirStat";               Id = "WinDirStat.WinDirStat";                  Category = "Disk Utilities"; Description = "Disk usage statistics and cleanup tool" }
Register-Utility @{ Name = "WinCleanup";               Id = "PozzaTech.WinCleanup";                   Category = "Disk Utilities"; Description = "Bundled cleanup script -DISM, temp files, hibernation, shadow copies (PozzaTech)" }

# ── Bootable Media ────────────────────────────────────────────────────────
Register-Utility @{ Name = "Rufus";                    Id = "Rufus.Rufus";                            Category = "Bootable Media"; Description = "Create bootable USB drives from ISOs" }
Register-Utility @{ Name = "Ventoy";                   Id = "Ventoy.Ventoy";                          Category = "Bootable Media"; Description = "Bootable USB tool -boot multiple ISOs from one drive" }

# ── Runtimes ──────────────────────────────────────────────────────────────
Register-Utility @{ Name = "Java Runtime Environment"; Id = "Oracle.JavaRuntimeEnvironment";          Category = "Runtimes";    Description = "Oracle Java Runtime Environment" }
Register-Utility @{ Name = "OpenJDK 21";               Id = "Microsoft.OpenJDK.21";                   Category = "Runtimes";    Description = "Microsoft Build of OpenJDK 21 (LTS)" }
Register-Utility @{ Name = ".NET 8 SDK";               Id = "Microsoft.DotNet.SDK.8";                 Category = "Runtimes";    Description = "Microsoft .NET 8 SDK" }
Register-Utility @{ Name = "VCRedist 2015+ x64";       Id = "Microsoft.VCRedist.2015+.x64";           Category = "Runtimes";    Description = "Visual C++ Redistributable for 2015-2022 (x64)" }
Register-Utility @{ Name = "DirectX End-User Runtime"; Id = "Microsoft.DirectX";                      Category = "Runtimes";    Description = "DirectX End-User Runtime web installer" }
