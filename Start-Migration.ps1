# Run this script prior to running the ProfWiz.exe

# Self-elevate if not running as admin (single UAC prompt for the entire session)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $ElevatedProcess = Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Wait -PassThru
    Exit $ElevatedProcess.ExitCode
}

$LogPath = "$PSScriptRoot\azureauto-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').log"
Start-Transcript -Path $LogPath -Append

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
}

Write-Log "Migration started."

try {
    & "$PSScriptRoot\subprocesses\Invoke-Preflight.ps1" -ErrorAction Stop
}
catch {
    Write-Log $_.Exception.Message "WARN"
    Exit 5
}

try {
    & "$PSScriptRoot\subprocesses\Test-Tpm.ps1" -ErrorAction Stop
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    Exit 1
}

try {
    & "$PSScriptRoot\subprocesses\Test-UserFolders.ps1" -ErrorAction Stop
}
catch {
    Write-Log ("User folder check failed: {0}" -f $_.Exception.Message) "WARN"
    Write-Log "Attempting a group policy update..."
    gpupdate /force
    $Resp = Read-Host "Press Enter to exit or y to continue anyways"
    if ($Resp.ToLower() -ne "y") {
        Exit 2
    }
}

Write-Log "Removing installed provisioning packages."
try {
    & "$PSScriptRoot\subprocesses\Remove-ProvisioningPackages.ps1" -ErrorAction Stop
}
catch {
    Write-Log ("Provisioning package removal failed: {0}" -f $_.Exception.Message) "WARN"
    $Resp = Read-Host "Press Enter to exit or y to continue anyways"
    if ($Resp.ToLower() -ne "y") {
        Exit 3
    }
}

Write-Log "Removing any existing enrollment information."
try {
    & "$PSScriptRoot\subprocesses\Remove-EnrollmentKeys.ps1" -ErrorAction Stop
    $Resp = Read-Host "Remove all user-initiated Azure joins? This step requires a restart. y/n"
    if ($Resp.ToLower() -eq "y") {
        Write-Log "Removing user AAD keys. Machine will restart."
        & "$PSScriptRoot\subprocesses\Remove-AadBrokerFolders.ps1" -ErrorAction Stop
    }
    else {
        Write-Log "Continuing without clearing user AAD keys."
    }
}
catch {
    Write-Log ("Enrollment removal scripts failed: {0}" -f $_.Exception.Message) "ERROR"
    Write-Log "Press Enter to exit"
    Read-Host
    Exit 4
}

Write-Log "Disabling Windows Sync Center."
try {
    $DisableSyncResult = & "$PSScriptRoot\subprocesses\Disable-SyncCenter.ps1" -ErrorAction Stop
    if ($true -eq $DisableSyncResult.RebootRequired) {
        Write-Log "Sync Center disabled. A restart is required before running ProfWiz."
        $Resp = Read-Host "Press Enter to exit and restart, or y to continue without restarting"
        if ($Resp.ToLower() -ne "y") {
            Exit 0
        }
    }
}
catch {
    Write-Log ("Disabling Sync Center failed: {0}" -f $_.Exception.Message) "WARN"
    Write-Log "Please manually disable Sync Center and press Enter to continue."
    Read-Host
}

$ProfWizPath = $PSScriptRoot + "\subprocesses\ProfWiz.exe"
if (-not (Test-Path $ProfWizPath)) {
    Write-Log "ProfWiz.exe not found at $ProfWizPath. Run Build-DeploymentPackage.bat to generate the deployment package first." "ERROR"
    Write-Host "Press Enter to exit."
    Read-Host
    Exit 6
}
Write-Log "Running ProfWiz.exe"
& $ProfWizPath
Write-Log "Migration complete."
Write-Host "Done, press Enter to exit script."
Read-Host
