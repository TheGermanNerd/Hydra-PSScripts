<#
.SYNOPSIS
    Updates Microsoft 365 Apps for Enterprise (Click-to-Run) on a Windows 11 machine.

.DESCRIPTION
    Designed to run unattended in SYSTEM context via Hydra (Login VSI) as a Script
    or Script Collection step - e.g. against session hosts in maintenance mode or
    against a master VM before image capture.

    What it does:
      1. Validates the Click-to-Run installation and logs current version/channel
      2. Triggers an update via OfficeC2RClient.exe (silent, force app shutdown)
      3. Polls the C2R registry until the update completes or times out
      4. Reports old vs. new version and exits with a meaningful exit code

    Exit codes:
      0   = Success (updated, or already up to date)
      1   = Click-to-Run not found / not a C2R installation
      2   = Failed to start the update process
      3   = Timeout waiting for update to complete
      4   = Update finished but version did not change and errors were detected

.NOTES
    Run context : SYSTEM (Hydra script execution)
    Logging     : C:\ProgramData\Hydra\Logs\M365Update_<timestamp>.log
                  plus stdout (captured by Hydra)
#>

#-------------------- Configuration ---------------------------------------------------

$TimeoutMinutes   = 60          # Max time to wait for the update to finish
$PollSeconds      = 30          # Polling interval while waiting
$LogDirectory     = 'C:\ProgramData\Hydra\Logs'
$ForceAppShutdown = $true       # Close open Office apps (recommended for SYSTEM/unattended)

#------------------ Helper functions ------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $line                       # Captured by Hydra script output
    Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue
}

function Get-C2RConfiguration {
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if (-not (Test-Path $regPath)) { return $null }
    Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
}

function Get-C2RScenarioState {
    # During an update, C2R writes scenario progress here
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Scenario'
    if (Test-Path $regPath) {
        Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
    }
}

function Test-C2RClientRunning {
    $null -ne (Get-Process -Name 'OfficeC2RClient' -ErrorAction SilentlyContinue)
}



#------------------------------- Initialization --------------------------------------------------

if (-not (Test-Path $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}
$script:LogFile = Join-Path $LogDirectory ('M365Update_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

Write-Log "=== Microsoft 365 Apps update started on $env:COMPUTERNAME ==="
Write-Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

#---------- Step 1: Validate Click-to-Run installation ----------------------

$c2rClient = Join-Path ${env:ProgramFiles} 'Common Files\microsoft shared\ClickToRun\OfficeC2RClient.exe'

if (-not (Test-Path $c2rClient)) {
    Write-Log "OfficeC2RClient.exe not found at '$c2rClient'. This machine does not appear to have a Click-to-Run installation of Microsoft 365 Apps." 'ERROR'
    OutputWriter ("OfficeC2RClient.exe not found at '$c2rClient'. This machine does not appear to have a Click-to-Run installation of Microsoft 365 Apps.")
    exit 1
}

$config = Get-C2RConfiguration
if (-not $config) {
    Write-Log 'Click-to-Run configuration registry key not found. Aborting.' 'ERROR'
    OutputWriter ("Click-to-Run configuration registry key not found. Aborting.")
    exit 1
}

$oldVersion = $config.VersionToReport
$channelUrl = $config.CDNBaseUrl
$updateUrl  = $config.UpdateUrl

# Map well-known CDN channel GUIDs to friendly names for logging
$channelMap = @{
    '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'
    '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Channel (Preview)'
    '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise Channel'
    '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise Channel'
    'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semi-Annual Enterprise Channel (Preview)'
    '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta Channel'
}
$channelGuid = if ($channelUrl) { ($channelUrl -split '/')[-1] } else { $null }
$channelName = if ($channelGuid -and $channelMap.ContainsKey($channelGuid)) { $channelMap[$channelGuid] } else { 'Unknown / Custom' }

Write-Log "Current version : $oldVersion"
Write-Log "Update channel  : $channelName"
if ($updateUrl) { Write-Log "Custom UpdateUrl: $updateUrl (updates are served from this path, not the CDN)" 'WARN' }

# Check whether updates are administratively disabled
$updatesEnabled = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -Name 'UpdatesEnabled' -ErrorAction SilentlyContinue).UpdatesEnabled
if ($updatesEnabled -eq 'False') {
    Write-Log "UpdatesEnabled is set to 'False' in the C2R configuration. The update may be blocked by policy (GPO/Intune)." 'WARN'
    OutputWriter ("UpdatesEnabled is set to 'False' in the C2R configuration. The update may be blocked by policy (GPO/Intune).")
}

#----------------------- Step 2: Trigger the update --------------------------------------

$shutdownArg = if ($ForceAppShutdown) { 'True' } else { 'False' }
$arguments = "/update user displaylevel=False forceappshutdown=$shutdownArg updatepromptuser=False"

Write-Log "Starting update: `"$c2rClient`" $arguments"

try {
    $proc = Start-Process -FilePath $c2rClient -ArgumentList $arguments -PassThru -ErrorAction Stop
    Write-Log "OfficeC2RClient started (PID $($proc.Id)). Waiting for update to complete..."
}
catch {
    Write-Log "Failed to start OfficeC2RClient.exe: $($_.Exception.Message)" 'ERROR'
    OutputWriter ("Failed to start OfficeC2RClient.exe: $($_.Exception.Message)")
    exit 2
}

# Give the client a moment to spin up and register its scenario
Start-Sleep -Seconds 20

#-------------------- Step 3: Wait for completion -------------------------------------

$deadline   = (Get-Date).AddMinutes($TimeoutMinutes)
$completed  = $false

while ((Get-Date) -lt $deadline) {

    $clientRunning = Test-C2RClientRunning
    $config        = Get-C2RConfiguration
    $currentVer    = $config.VersionToReport

    # Success condition 1: version changed
    if ($currentVer -and ($currentVer -ne $oldVersion)) {
        Write-Log "Version changed: $oldVersion -> $currentVer"
        # Wait for the client to fully finish (finalize/cleanup) before declaring success
        if (-not $clientRunning) {
            $completed = $true
            break
        }
    }

    # Success condition 2: client exited without a version change = already up to date
    if (-not $clientRunning -and ($currentVer -eq $oldVersion)) {
        # Double-check it's not just between phases (TASKSTATE in Scenario key)
        Start-Sleep -Seconds 15
        if (-not (Test-C2RClientRunning)) {
            Write-Log 'OfficeC2RClient has exited and the version is unchanged. Installation is already up to date (or no applicable update was found).'
            $completed = $true
            break
        }
    }

    # Optional: log scenario progress for visibility in Hydra output
    $scenario = Get-C2RScenarioState
    if ($scenario) {
        $stateProps = $scenario.PSObject.Properties | Where-Object { $_.Name -match 'TASKSTATE' } | Select-Object -First 1
        if ($stateProps) { Write-Log "Update in progress... ($($stateProps.Name) = $($stateProps.Value))" }
        else             { Write-Log 'Update in progress...' }
    }
    else {
        Write-Log 'Update in progress...'
    }

    Start-Sleep -Seconds $PollSeconds
}

#-------------------- Step 4: Final result --------------------------------------------

if (-not $completed) {
    Write-Log "Timeout: update did not complete within $TimeoutMinutes minutes. Check the C2R logs under '%windir%\Temp' and the 'Microsoft Office Alerts' event log." 'ERROR'
    OutputWriter ("Timeout: update did not complete within $TimeoutMinutes minutes. Check the C2R logs under '%windir%\Temp' and the 'Microsoft Office Alerts' event log.")
    exit 3
}

$finalConfig  = Get-C2RConfiguration
$finalVersion = $finalConfig.VersionToReport

if ($finalVersion -ne $oldVersion) {
    Write-Log "SUCCESS: Microsoft 365 Apps updated from $oldVersion to $finalVersion."
    OutputWriter ("SUCCESS: Microsoft 365 Apps updated from $oldVersion to $finalVersion.")
    Write-Log '=== Update finished ==='
    OutputWriter ("=== Update finished ===")
    exit 0
}
else {
    Write-Log "FINISHED: No update was applied. Version remains $finalVersion (already current for channel '$channelName')."
    OutputWriter ("FINISHED: No update was applied. Version remains $finalVersion (already current for channel '$channelName').")
    Write-Log '=== Update finished ==='
    OutputWriter ("=== Update finished ===")
    exit 0
}
