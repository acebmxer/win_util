# System information helpers for the menu sidebar.
#
# Get-SystemInfo returns a hashtable with short, sidebar-friendly strings:
#   Host, OS, Kernel, CPU, Mem, Disk, Uptime
# All lookups are wrapped in try/catch and default to "Unknown" so a missing
# WMI provider never blocks the menu from rendering.

function Format-Bytes {
    param([double]$Bytes, [int]$Digits = 1)
    if ($Bytes -ge 1TB) { return ("{0:N$Digits}T" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N$Digits}G" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N$Digits}M" -f ($Bytes / 1MB)) }
    return ("{0:N0}B" -f $Bytes)
}

function Get-SystemInfo {
    $info = [ordered]@{
        Host   = "Unknown"
        OS     = "Unknown"
        Kernel = "Unknown"
        CPU    = "Unknown"
        Mem    = "Unknown"
        Disk   = "Unknown"
        Uptime = "Unknown"
    }

    try { $info.Host = [Environment]::MachineName } catch {}

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $caption = ($os.Caption -replace '^Microsoft\s+', '').Trim()
        $info.OS     = $caption
        $info.Kernel = $os.Version
        try {
            $boot   = $os.LastBootUpTime
            $span   = (Get-Date) - $boot
            $info.Uptime = if ($span.Days -gt 0) {
                "{0}d {1}h" -f $span.Days, $span.Hours
            } elseif ($span.Hours -gt 0) {
                "{0}h {1}m" -f $span.Hours, $span.Minutes
            } else {
                "{0}m" -f $span.Minutes
            }
        } catch {}

        $totalBytes = [double]$os.TotalVisibleMemorySize * 1KB
        $freeBytes  = [double]$os.FreePhysicalMemory     * 1KB
        $usedBytes  = $totalBytes - $freeBytes
        $info.Mem   = "{0}/{1}" -f (Format-Bytes $usedBytes), (Format-Bytes $totalBytes)
    } catch {}

    try {
        $cpu  = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $name = $cpu.Name
        # Tidy common patterns to fit a narrow sidebar
        $name = $name -replace '\(R\)|\(TM\)', ''
        $name = $name -replace '\s+CPU\s+@.*$', ''
        $name = $name -replace 'Intel Core ', ''
        $name = $name -replace 'AMD Ryzen ', 'Ryzen '
        $info.CPU = $name.Trim()
    } catch {}

    try {
        $sysDrive = ($env:SystemDrive).TrimEnd(':')
        $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction Stop
        if ($vol) {
            $size = [double]$vol.Size
            $free = [double]$vol.FreeSpace
            $used = $size - $free
            $info.Disk = "{0}/{1} ({2}:)" -f (Format-Bytes $used), (Format-Bytes $size), $sysDrive
        }
    } catch {}

    return $info
}
