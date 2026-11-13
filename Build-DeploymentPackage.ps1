$SubDir = "subprocesses"
$ProfwizVersion = "24.8"
$BuildDir = "$PSScriptRoot\build"
. "$PSScriptRoot\config\buildconfig.ps1"
$ProfwizLicenseId = ""
if ( Test-Path "$PSScriptRoot\config\license.ps1" -PathType Leaf ) {
    . "$PSScriptRoot\config\license.ps1"
}
$BuildLogPath = "$BuildDir\build-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').log"
Start-Transcript -Path $BuildLogPath -Append
Write-Host "Build log: $BuildLogPath"

# Copy .ppkg into directory. Leaving the path blank builds a package without one.
$ProvPackageName = ""
$ProvPackageDestination = $null
$ProvPackagePath = Read-Host "Enter the path to your provisioning package (.ppkg) file, or leave blank to build without one"
if ( $ProvPackagePath -eq "" ) {
    Write-Host "No provisioning package provided. Building without one."
} elseif ( -not (Test-Path $ProvPackagePath -PathType Leaf) -or -not ($ProvPackagePath -like "*.ppkg") ) {
    Write-Host "Invalid provisioning package path passed: $ProvPackagePath"
    Read-Host "Press Enter to exit"
    Exit 1
} else {
    $ProvPackageName = (Get-ChildItem $ProvPackagePath).Name
}

# Every .ppkg in the subprocess folder gets zipped, so a leftover from another client would ship with this build.
$StrayPackages = @(Get-ChildItem -Path "$PSScriptRoot\$SubDir" -Filter "*.ppkg" -File | Where-Object { $_.Name -ne $ProvPackageName })
if ( $StrayPackages.Count -gt 0 ) {
    Write-Host "Other provisioning packages found in $PSScriptRoot\$SubDir and would be bundled into this build:"
    $StrayPackages | ForEach-Object { Write-Host "  $($_.Name)" }
    Write-Host "Move or delete them and run the build again."
    Read-Host "Press Enter to exit"
    Exit 1
}

if ( $ProvPackageName -ne "" ) {
    $ProvPackageDestination = "$PSScriptRoot\$SubDir\$ProvPackageName"
    if ( Test-Path $ProvPackageDestination -PathType Leaf ) {
        Remove-Item -Path $ProvPackageDestination -Force
    }
    Copy-Item -Path $ProvPackagePath -Destination $ProvPackageDestination
}

$ProfwizInstalled = Read-Host "Is Profwiz Professional already installed on this computer? (y/n)"

if ( $ProfwizInstalled.ToLower() -ne "y" ) {
    # The download link is tied to the license ID, kept out of the repo in config\license.ps1.
    if ( [string]::IsNullOrWhiteSpace($ProfwizLicenseId) ) {
        $ProfwizLicenseId = Read-Host "No license ID in config\license.ps1 (see config\license.example.ps1). Enter the ForensiT license ID"
    }
    $ProfwizLicenseId = $ProfwizLicenseId.Trim()
    if ( $ProfwizLicenseId -notmatch "^[0-9a-fA-F]{32}$" ) {
        Write-Host "Invalid ForensiT license ID. Expected 32 hexadecimal characters."
        Read-Host "Press Enter to exit"
        Exit 1
    }

    # Download Forensit Profwiz
    curl "https://tronda.forensit.com/api/deliver/$ProfwizLicenseId&Version=$ProfwizVersion" -o ("{0}\profwizinstall.exe" -f $ENV:TEMP)

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

# ProfWiz applies whichever .ppkg Profwiz.config names, so it must match the package supplied above.
$ConfigError = $null
try {
    $ConfigNode = ([xml](Get-Content -Path $ProfwizConfigDestination -Raw)).GetElementsByTagName("ProvisioningPackage") | Select-Object -First 1
    $ConfigPackageName = if ($null -ne $ConfigNode) { $ConfigNode.InnerText.Trim() } else { "" }
    if ( $ConfigPackageName -ne $ProvPackageName ) {
        $ConfigError = "Profwiz.config names provisioning package `"$ConfigPackageName`" but the build was given `"$ProvPackageName`". Set the provisioning package in the ProfWiz project to match (blank for none) and run the build again."
    }
}
catch {
    $ConfigError = "Could not read Profwiz.config: $($_.Exception.Message)"
}

$ArchiveName = "$ProfWizProjectName-azureauto.zip"
$ArchiveDestination = "$BuildDir\$ArchiveName"
if ( $null -eq $ConfigError ) {
    if ( Test-Path $ArchiveDestination -PathType Leaf ) {
        Remove-Item -Path $ArchiveDestination -Force
    }

    # Stage config\ without the license files so the license ID never ships to client machines.
    $StageDir = Join-Path $env:TEMP ("azureauto-stage-{0}" -f [guid]::NewGuid())
    $StageConfigDir = "$StageDir\config"
    try {
        New-Item -Path $StageConfigDir -ItemType Directory -Force | Out-Null
        Get-ChildItem -Path "$PSScriptRoot\config" -File | Where-Object { $_.Name -notlike "license*.ps1" } | Copy-Item -Destination $StageConfigDir

        $ArchivePaths = @(
            "$PSScriptRoot\run.bat",
            "$PSScriptRoot\Start-Migration.ps1",
            "$PSScriptRoot\$SubDir",
            $StageConfigDir
        )
        Compress-Archive -Path $ArchivePaths -DestinationPath $ArchiveDestination
    } finally {
        if (Test-Path $StageDir) { Remove-Item -Path $StageDir -Recurse -Force }
    }
}

Write-Host "Cleaning up build artifacts."

foreach ($File in $CopiedDeploymentFiles) {
    if (Test-Path $File) { Remove-Item $File -Force }
}

foreach ($File in @($ProvPackageDestination, "$PSScriptRoot\$SubDir\ForensiTAzureID.xml", "$PSScriptRoot\$SubDir\Profwiz.config")) {
    if ($File -and (Test-Path $File -PathType Leaf)) { Remove-Item $File -Force }
}

if ($CreatedUsersCsv -and (Test-Path "$PSScriptRoot\$SubDir\Users.csv" -PathType Leaf)) {
    Remove-Item "$PSScriptRoot\$SubDir\Users.csv" -Force
}

if ( $null -ne $ConfigError ) {
    Write-Host $ConfigError
    Write-Host "No archive was created."
    Read-Host "Press Enter to exit"
    Exit 1
}

Write-Host "Verifying archive contents."
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Zip = [System.IO.Compression.ZipFile]::OpenRead($ArchiveDestination)
$VerificationFailures = @()
$RequiredEntries = @("Profwiz.exe", "Profwiz.config", "ForensiTAzureID.xml")
if ( $ProvPackageName -ne "" ) { $RequiredEntries += $ProvPackageName }
try {
    $Entries = $Zip.Entries
    foreach ($Required in $RequiredEntries) {
        if (-not ($Entries | Where-Object { $_.Name -eq $Required })) {
            $VerificationFailures += "Missing from archive: $Required"
        }
    }
    foreach ($Entry in ($Entries | Where-Object { $_.Name -in @("Profwiz.config", "ForensiTAzureID.xml") })) {
        if ($Entry.Length -eq 0) {
            $VerificationFailures += "Empty file in archive: $($Entry.Name)"
        }
    }
    foreach ($Entry in ($Entries | Where-Object { $_.Name -like "license*.ps1" })) {
        $VerificationFailures += "License file must not be in archive: $($Entry.FullName)"
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
