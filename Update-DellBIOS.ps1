<#
.SYNOPSIS
    Dell BIOS Update Script - MedPro Healthcare Staffing
    Detects machine model via WMI, downloads the correct BIOS update, and installs silently.

.DESCRIPTION
    Targets the following Dell model families per the vulnerability remediation roster:
      - Vostro 5620       → BIOS 1.33.0 (from 1.32)
      - Vostro 5890       → BIOS 1.40.0 (from 1.37)
      - Vostro 7620       → BIOS 1.34.0 (from 1.33.1)
      - Vostro 14 5410    → BIOS 2.39.0 (from 2.38.1)
      - Vostro 15 5510    → BIOS 2.39.0 (from 2.38.1)

    Deployment: Push via Action1, Intune, GPO, or any RMM. Must run as SYSTEM or local admin.
    The script will:
      1. Detect the machine model
      2. Match it to the correct BIOS package
      3. Check if the BIOS is already at or above the target version (skip if so)
      4. Download the Dell BIOS .exe to a temp staging folder
      5. Execute the silent install (no auto-reboot — you control the reboot window)
      6. Log everything to C:\ProgramData\MedPro\BIOSUpdate\BIOSUpdate.log

.NOTES
    Author:  Javi @ MedPro IT / StackPoint IT
    Date:    2026-03-12
    Version: 1.0

    EXIT CODES:
      0 = Success (update applied or already current)
      1 = Model not in scope (not a targeted device)
      2 = Download failed
      3 = BIOS install failed
      4 = Not running as admin
#>

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION — Model-to-BIOS Mapping
# ============================================================================
# Each entry maps a WMI model string (as returned by Win32_ComputerSystem) to:
#   - TargetVersion : The BIOS version this update installs
#   - DownloadURL   : Direct .exe download from Dell (extracted from driver page)
#   - FileName      : Local filename for the downloaded installer
#   - DriverID      : Dell driver ID for reference
#
# Direct .exe download links from Dell (dl.dell.com) — updated 2026-03-12
# ============================================================================

$BIOSMap = @{
    'Vostro 5620' = @{
        TargetVersion = '1.33.0'
        CurrentVersion = '1.32'  # Version on roster machines
        DownloadURL   = 'https://dl.dell.com/FOLDER13929527M/1/Inspiron_Vostro_5420_5620_1.33.0.exe'
        FileName      = 'Inspiron_Vostro_5420_5620_1.33.0.exe'
        DriverID      = 'mpy0m'
    }
    'Vostro 5890' = @{
        TargetVersion = '1.40.0'
        CurrentVersion = '1.37'  # Version on roster machines
        DownloadURL   = 'https://dl.dell.com/FOLDER13924616M/1/Vostro_5890_1.40.0.exe'
        FileName      = 'Vostro_5890_1.40.0.exe'
        DriverID      = '94f3t'
    }
    'Vostro 7620' = @{
        TargetVersion = '1.34.0'
        CurrentVersion = '1.33.1'  # Version on roster machines
        DownloadURL   = 'https://dl.dell.com/FOLDER13929460M/1/Inspiron_7420_7620_Vostro_7620_1.34.0.exe'
        FileName      = 'Inspiron_7420_7620_Vostro_7620_1.34.0.exe'
        DriverID      = 'fycn3'
    }
    'Vostro 14 5410' = @{
        TargetVersion = '2.39.0'
        CurrentVersion = '2.38.1'  # Version on roster machines
        DownloadURL   = 'https://dl.dell.com/FOLDER14044347M/1/Inspiron_Vostro_5410_5418_5510_5518_5410_5510_2.39.0.exe'
        FileName      = 'Inspiron_Vostro_5410_5418_5510_5518_5410_5510_2.39.0.exe'
        DriverID      = 'ym51n'
    }
    'Vostro 15 5510' = @{
        TargetVersion = '2.39.0'
        CurrentVersion = '2.38.1'  # Version on roster machines
        DownloadURL   = 'https://dl.dell.com/FOLDER14044347M/1/Inspiron_Vostro_5410_5418_5510_5518_5410_5510_2.39.0.exe'
        FileName      = 'Inspiron_Vostro_5410_5418_5510_5518_5410_5510_2.39.0.exe'
        DriverID      = 'ym51n'
    }
}

# ============================================================================
# OPTIONAL: Network share mode (if you pre-download the .exe files)
# Set $UseNetworkShare = $true and point $NetworkSharePath to the folder
# containing the BIOS .exe files. File names must match the FileName values above.
# ============================================================================
$UseNetworkShare  = $false
$NetworkSharePath = '\\med-dc-02\BIOS_Updates'  # Adjust to your share

# ============================================================================
# LOGGING SETUP
# ============================================================================
$LogDir  = 'C:\ProgramData\MedPro\BIOSUpdate'
$LogFile = Join-Path $LogDir 'BIOSUpdate.log'
$StagingDir = Join-Path $env:TEMP 'MedPro_BIOS'

if (-not (Test-Path $LogDir))     { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $StagingDir)) { New-Item -Path $StagingDir -ItemType Directory -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry -Force
    Write-Host $entry
}

# ============================================================================
# ADMIN CHECK
# ============================================================================
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log 'Script must run as Administrator or SYSTEM. Exiting.' 'ERROR'
    exit 4
}

# ============================================================================
# DETECT MACHINE MODEL & CURRENT BIOS
# ============================================================================
Write-Log '====== BIOS Update Script Started ======'
Write-Log "Hostname: $env:COMPUTERNAME"

$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
$currentBIOS    = Get-CimInstance -ClassName Win32_BIOS

$model        = $computerSystem.Model.Trim()
$manufacturer = $computerSystem.Manufacturer.Trim()
$biosVersion  = $currentBIOS.SMBIOSBIOSVersion.Trim()
$serial       = $currentBIOS.SerialNumber.Trim()

Write-Log "Manufacturer: $manufacturer"
Write-Log "Model:        $model"
Write-Log "Serial:       $serial"
Write-Log "Current BIOS: $biosVersion"

# ============================================================================
# MODEL MATCHING — fuzzy match to handle minor WMI string variations
# ============================================================================
$matchedKey = $null

# Try exact match first
if ($BIOSMap.ContainsKey($model)) {
    $matchedKey = $model
}
else {
    # Fuzzy: check if the WMI model string contains any of our known model names
    foreach ($key in $BIOSMap.Keys) {
        if ($model -like "*$key*") {
            $matchedKey = $key
            break
        }
    }
}

if (-not $matchedKey) {
    Write-Log "Model '$model' is not in the BIOS update scope. No action needed." 'WARN'
    Write-Log '====== Script Complete (Not in Scope) ======'
    exit 1
}

$biosConfig = $BIOSMap[$matchedKey]
Write-Log "Matched model key: '$matchedKey' (Driver: $($biosConfig.DriverID))"
Write-Log "Target BIOS version: $($biosConfig.TargetVersion)"

# ============================================================================
# VERSION COMPARISON — skip if already at or above target
# ============================================================================
function Compare-BIOSVersion {
    param([string]$Current, [string]$Target)
    
    # Normalize: strip non-numeric/dot characters, pad to 3-part version
    $cleanCurrent = ($Current -replace '[^0-9.]', '').Trim('.')
    $cleanTarget  = ($Target  -replace '[^0-9.]', '').Trim('.')
    
    try {
        # Pad to at least 3 parts for [version] parsing
        while (($cleanCurrent -split '\.').Count -lt 2) { $cleanCurrent += '.0' }
        while (($cleanTarget  -split '\.').Count -lt 2) { $cleanTarget  += '.0' }
        
        $vCurrent = [version]$cleanCurrent
        $vTarget  = [version]$cleanTarget
        
        return $vCurrent.CompareTo($vTarget)
    }
    catch {
        Write-Log "Version comparison failed (Current='$Current', Target='$Target'): $_" 'WARN'
        return -1  # Assume update is needed if comparison fails
    }
}

$versionCompare = Compare-BIOSVersion -Current $biosVersion -Target $biosConfig.TargetVersion

if ($versionCompare -ge 0) {
    Write-Log "BIOS is already at v$biosVersion (target: v$($biosConfig.TargetVersion)). No update needed." 'INFO'
    Write-Log '====== Script Complete (Already Current) ======'
    exit 0
}

Write-Log "BIOS update required: v$biosVersion → v$($biosConfig.TargetVersion))"

# ============================================================================
# ACQUIRE BIOS INSTALLER
# ============================================================================
$installerPath = Join-Path $StagingDir $biosConfig.FileName

if ($UseNetworkShare) {
    # --- NETWORK SHARE MODE ---
    $sourcePath = Join-Path $NetworkSharePath $biosConfig.FileName
    Write-Log "Copying BIOS installer from network share: $sourcePath"
    
    if (-not (Test-Path $sourcePath)) {
        Write-Log "BIOS installer not found at '$sourcePath'. Exiting." 'ERROR'
        exit 2
    }
    
    try {
        Copy-Item -Path $sourcePath -Destination $installerPath -Force
        Write-Log "Copy complete: $installerPath"
    }
    catch {
        Write-Log "Failed to copy BIOS installer: $_" 'ERROR'
        exit 2
    }
}
else {
    # --- DIRECT DOWNLOAD MODE ---
    $downloadURL = $biosConfig.DownloadURL
    
    Write-Log "Downloading BIOS installer from: $downloadURL"
    
    try {
        # Use BITS for resilient download, fall back to WebClient
        $bitsJob = Start-BitsTransfer -Source $downloadURL -Destination $installerPath -ErrorAction Stop
        Write-Log "Download complete (BITS): $installerPath"
    }
    catch {
        Write-Log "BITS transfer failed, falling back to WebClient: $_" 'WARN'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $webClient = New-Object System.Net.WebClient
            $webClient.DownloadFile($downloadURL, $installerPath)
            Write-Log "Download complete (WebClient): $installerPath"
        }
        catch {
            Write-Log "Download failed completely: $_" 'ERROR'
            exit 2
        }
    }
}

# Validate the file exists and isn't zero-length
if (-not (Test-Path $installerPath) -or (Get-Item $installerPath).Length -eq 0) {
    Write-Log "BIOS installer file is missing or empty after download. Exiting." 'ERROR'
    exit 2
}

$fileSize = [math]::Round((Get-Item $installerPath).Length / 1MB, 2)
Write-Log "Installer size: ${fileSize} MB"

# ============================================================================
# INSTALL BIOS UPDATE — Dell silent switches
# ============================================================================
# Dell BIOS .exe standard silent switches:
#   /s        = Silent mode
#   /p=<pwd>  = BIOS password (if set)
#   /l=<log>  = Log file path
#   /f        = Force update even if same version
#   /r        = Reboot automatically (WE OMIT THIS — no auto-reboot)
#
# If your machines have a BIOS admin password, uncomment and set below:
# $BIOSPassword = 'YourBIOSPassword'
# ============================================================================

$dellLogFile = Join-Path $LogDir "DellBIOS_$($biosConfig.DriverID).log"

$installArgs = "/s /l=`"$dellLogFile`""

# Uncomment if BIOS password is required:
# $installArgs += " /p=`"$BIOSPassword`""

Write-Log "Executing BIOS installer: $installerPath $installArgs"
Write-Log 'NOTE: Machine will require a REBOOT to apply the BIOS update.'

try {
    $process = Start-Process -FilePath $installerPath `
                             -ArgumentList $installArgs `
                             -Wait `
                             -PassThru `
                             -NoNewWindow

    $exitCode = $process.ExitCode
    Write-Log "Dell BIOS installer exit code: $exitCode"

    # Dell BIOS exit codes:
    #   0 = Success
    #   1 = Unsuccessful (generic failure)
    #   2 = Reboot required (success, pending reboot) — this is expected
    #   3 = Soft dependency error
    #   4 = Hard dependency error
    #   5 = Qualification error
    #   6 = Rebooting system
    switch ($exitCode) {
        0 { Write-Log 'BIOS update applied successfully. Reboot required to finalize.' 'SUCCESS' }
        2 { Write-Log 'BIOS update staged. Reboot required to finalize.' 'SUCCESS' }
        default {
            Write-Log "BIOS installer returned unexpected exit code: $exitCode. Check Dell log: $dellLogFile" 'ERROR'
            exit 3
        }
    }
}
catch {
    Write-Log "Failed to execute BIOS installer: $_" 'ERROR'
    exit 3
}

# ============================================================================
# CLEANUP
# ============================================================================
Write-Log 'Cleaning up staging directory...'
try {
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    Write-Log 'Cleanup complete.'
}
catch {
    Write-Log "Cleanup warning (non-critical): $_" 'WARN'
}

Write-Log '====== BIOS Update Script Complete ======'
Write-Log "ACTION REQUIRED: Schedule a reboot for $env:COMPUTERNAME to apply the BIOS update."
exit 0
