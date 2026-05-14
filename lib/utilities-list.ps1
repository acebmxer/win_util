# All registered utilities — add a Register-Utility line here to add a new tool.
# Custom install/uninstall/update/test logic: define Install-SafeName, etc. anywhere in the loaded files.

Register-Utility @{ Name = "Google Chrome";            Id = "Google.Chrome";                   Category = "Browsers" }

Register-Utility @{ Name = "7-Zip";                    Id = "7zip.7zip";                       Category = "Tools"    }

Register-Utility @{ Name = "VLC Media Player";         Id = "VideoLAN.VLC";                    Category = "Media"    }

Register-Utility @{ Name = "Java Runtime Environment"; Id = "Oracle.JavaRuntimeEnvironment";   Category = "Runtimes" }

Register-Utility @{ Name = "VCRedist 2015+ x64";       Id = "Microsoft.VCRedist.2015+.x64";   Category = "System"   }
