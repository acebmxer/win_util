# Logging module for win_util

$script:LogFile = $null

function Initialize-Logging {
    $logDir = if ($PSScriptRoot) {
        Join-Path $PSScriptRoot "..\logs"   # dev: lib\ -> win_util\logs\  |  dist: dist\ -> win_util\logs\
    } else {
        Join-Path $env:TEMP "win_util_logs" # scriptblock invocation: $PSScriptRoot is empty
    }
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Force $logDir | Out-Null
    }
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:LogFile = Join-Path $logDir "win_util_$timestamp.log"
    Write-Log "Session started" "INFO"
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue
    }
}

function Write-LogInfo  { param([string]$Message) Write-Log $Message "INFO" }
function Write-LogWarn  { param([string]$Message) Write-Log $Message "WARN" }
function Write-LogError { param([string]$Message) Write-Log $Message "ERROR" }

function Write-LogSummary {
    param(
        [int]$Succeeded,
        [int]$Failed,
        [string[]]$FailedNames = @()
    )
    Write-Log "--- Session Summary ---" "INFO"
    Write-Log "Succeeded: $Succeeded" "INFO"
    Write-Log "Failed:    $Failed" "INFO"
    if ($FailedNames.Count -gt 0) {
        Write-Log "Failed items: $($FailedNames -join ', ')" "ERROR"
    }
    Write-Log "Log file: $script:LogFile" "INFO"
}
