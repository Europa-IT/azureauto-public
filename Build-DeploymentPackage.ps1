$SubDir = "subprocesses"
$ProfwizVersion = "24.8"
$BuildDir = "$PSScriptRoot\build"
. "$PSScriptRoot\config\buildconfig.ps1"
$BuildLogPath = "$BuildDir\build-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').log"
Start-Transcript -Path $BuildLogPath -Append
Write-Host "Build log: $BuildLogPath"

# Copy .ppkg into directory
$ProvPackagePath = Read-Host "Enter the path to your provisioning package (.ppkg) file"
if ( $ProvPackagePath -eq "" ) {
    Write-Host "No provisioning package path provided, exiting."
    Exit 1
}

if ( -not (Test-Path $ProvPackagePath -PathType Leaf) -or -not ($ProvPackagePath -like "*.ppkg") ) {
    Write-Host "Invalid provisioning package path passed: $ProvPackagePath"
    Read-Host "Press Enter to exit"
    Exit 1
} else {
    $ProvPackageName = (Get-ChildItem $ProvPackagePath).Name
}

$ProvPackageDestination = "$PSScriptRoot\$SubDir\$ProvPackageName"
if ( Test-Path $ProvPackageDestination -PathType Leaf ) {
    Remove-Item -Path $ProvPackageDestination -Force
}
Copy-Item -Path $ProvPackagePath -Destination $ProvPackageDestination

$ProfwizInstalled = Read-Host "Is Profwiz Professional already installed on this computer? (y/n)"

if ( $ProfwizInstalled.ToLower() -ne "y" ) {
    # Download Forensit Profwiz
    curl "https://tronda.forensit.com/api/deliver/REDACTED-LICENSE-ID&Version=$ProfwizVersion" -o ("{0}\profwizinstall.exe" -f $ENV:TEMP)

    # Silently install Forensit Profwiz
    Start-Process -FilePath ("{0}\profwizinstall.exe" -f $ENV:TEMP) -ArgumentList "/QUIET" -Wait
}

# Copy deployment files to subprocess folder.
# Save-AzureADUser.ps1 is excluded — our version in subprocesses/ takes precedence.
$CopiedDeploymentFiles = [System.Collections.Generic.List[string]]::new()
Get-ChildItem -Path "$ProfwizDataRoot\" -File | Where-Object { $_.Name -ne "Save-AzureADUser.ps1" } | ForEach-Object {
    $DestPath = ("{0}\{1}\{2}" -f $PSScriptRoot, $SubDir, $_.Name)
    if ( Test-Path -Path $DestPath ) { Remove-Item $DestPath }
    Copy-Item $_.FullName -Destination $DestPath
    $CopiedDeploymentFiles.Add($DestPath)
}

# Create Users.csv template at the correct location.
$CreatedUsersCsv = $false
if ( -not (Test-Path "$PSScriptRoot\$SubDir\Users.csv" -PathType Leaf) ) {
    New-Item -Path "$PSScriptRoot\$SubDir\Users.csv" -ItemType File
    $CreatedUsersCsv = $true
}

# Generate AzureAD info via Profwiz Save-AzureADUser.ps1 script
if ( Test-Path -Path "$PSScriptRoot\ForensiTAzureID.xml" -PathType Leaf ) {
    Remove-Item -Path "$PSScriptRoot\ForensiTAzureID.xml" -Force
}
& "$PSScriptRoot\$SubDir\Save-AzureADUser.ps1"
if ( -not (Test-Path -Path "$PSScriptRoot\ForensiTAzureID.xml" -PathType Leaf) ){ 
    Read-Host "ForensiTAzureID.xml generation failed. Press Enter to exit"
    Exit 1
}

Move-Item -Path "$PSScriptRoot\ForensiTAzureID.xml" -Destination "$PSScriptRoot\$SubDir\ForensiTAzureID.xml" -Force

# Generate Profwiz.config
$ProfwizProjectRoot = $ProfwizDataRoot
Read-Host "Running Profwiz project creation UI now. Press Enter to continue"
& "$ProfwizInstallKit\UPWDK3.exe"
$ProfwizProjectName = Read-Host "Enter the project name set for your Profwiz config"
while ( -not (Test-Path -Path "$ProfwizProjectRoot\$ProfwizProjectName" -PathType Container) -or -not (Test-Path -Path "$ProfwizProjectRoot\$ProfwizProjectName\Profwiz.config" -PathType Leaf) ) {
    $Answer = Read-Host "Project path `"$ProfwizProjectRoot\$ProfwizProjectName`" not found or missing Profwiz.config. Try again? (y/n)"
    if ($Answer.ToLower() -ne "y") {
        Exit 1
    }
    $ProfwizProjectName = Read-Host "Enter the project name set for your Profwiz config"
}

$ProfwizConfigDestination = "$PSScriptRoot\$SubDir\Profwiz.config" 

if ( Test-Path $ProfwizConfigDestination -PathType Leaf ) {
    Remove-Item -Path $ProfwizConfigDestination -Force
}

Copy-Item -Path "$ProfwizProjectRoot\$ProfwizProjectName\Profwiz.config" -Destination $ProfwizConfigDestination

$ArchiveName = "$ProfWizProjectName-azureauto.zip"
$ArchiveDestination = "$BuildDir\$ArchiveName"
if ( Test-Path $ArchiveDestination -PathType Leaf ) {
    Remove-Item -Path $ArchiveDestination -Force
}

$ArchivePaths = @(
    "$PSScriptRoot\run.bat",
    "$PSScriptRoot\Start-Migration.ps1",
    "$PSScriptRoot\$SubDir",
    "$PSScriptRoot\config"
)
Compress-Archive -Path $ArchivePaths -DestinationPath $ArchiveDestination

Write-Host "Cleaning up build artifacts."

foreach ($File in $CopiedDeploymentFiles) {
    if (Test-Path $File) { Remove-Item $File -Force }
}

foreach ($File in @($ProvPackageDestination, "$PSScriptRoot\$SubDir\ForensiTAzureID.xml", "$PSScriptRoot\$SubDir\Profwiz.config")) {
    if (Test-Path $File -PathType Leaf) { Remove-Item $File -Force }
}

if ($CreatedUsersCsv -and (Test-Path "$PSScriptRoot\$SubDir\Users.csv" -PathType Leaf)) {
    Remove-Item "$PSScriptRoot\$SubDir\Users.csv" -Force
}

Write-Host "Verifying archive contents."
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Zip = [System.IO.Compression.ZipFile]::OpenRead($ArchiveDestination)
$VerificationFailures = @()
try {
    $Entries = $Zip.Entries
    foreach ($Required in @("Profwiz.exe", "Profwiz.config", "ForensiTAzureID.xml", $ProvPackageName)) {
        if (-not ($Entries | Where-Object { $_.Name -eq $Required })) {
            $VerificationFailures += "Missing from archive: $Required"
        }
    }
    foreach ($Entry in ($Entries | Where-Object { $_.Name -in @("Profwiz.config", "ForensiTAzureID.xml") })) {
        if ($Entry.Length -eq 0) {
            $VerificationFailures += "Empty file in archive: $($Entry.Name)"
        }
    }
} finally {
    $Zip.Dispose()
}

if ($VerificationFailures.Count -gt 0) {
    Write-Host "Archive verification failed:"
    $VerificationFailures | ForEach-Object { Write-Host "  $_" }
    Write-Host "The archive at $ArchiveDestination may be incomplete. Review and rebuild if necessary."
} else {
    Write-Host "Archive verification passed."
    Write-Host "Build complete. Archive saved to $ArchiveDestination"
}
