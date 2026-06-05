# Read-only pre-flight system check

$Results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Check, [string]$Value, [string]$Status)
    $Results.Add([PSCustomObject]@{ Check = $Check; Value = $Value; Status = $Status })
}

# TPM Version
try {
    $TPMOutput = TPMTool GetDeviceInformation 2>&1
    $TPMLine = $TPMOutput | Select-String -Pattern "TPM Version"
    if ($null -eq $TPMLine) { throw "No TPM version line in output." }
    $TPMVersion = ($TPMLine.Line -Split ": ")[-1].Trim()
    $Status = if ([double]$TPMVersion -ge 2.0) { "OK" } else { "FAIL" }
    Add-Result "TPM Version" $TPMVersion $Status
} catch {
    Add-Result "TPM Version" "Unable to check" "WARN"
}

# User folder locations
$HKCUPath = "Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\"
foreach ($Folder in @(
    @{ Name = "Desktop";   RegKey = "Desktop"     },
    @{ Name = "Documents"; RegKey = "Personal"    },
    @{ Name = "Pictures";  RegKey = "My Pictures" }
)) {
    try {
        $Path = Get-ItemPropertyValue -Path ($HKCUPath + "User Shell Folders") -Name $Folder.RegKey -ErrorAction Stop
    } catch {
        try {
            $Path = Get-ItemPropertyValue -Path ($HKCUPath + "Shell Folders") -Name $Folder.RegKey -ErrorAction Stop
        } catch {
            $Path = $null
        }
    }
    if ($null -eq $Path) {
        Add-Result $Folder.Name "Unable to determine" "WARN"
    } elseif ((Split-Path -Parent $Path) -ne $env:USERPROFILE) {
        Add-Result $Folder.Name "Redirected to $Path" "FAIL"
    } else {
        Add-Result $Folder.Name $Path "OK"
    }
}

# Provisioning packages
try {
    $Count = @(Get-ProvisioningPackage -AllInstalledPackages -ErrorAction Stop).Count
    Add-Result "Provisioning packages" "$Count installed" "INFO"
} catch {
    Add-Result "Provisioning packages" "Unable to check" "WARN"
}

# Enrollment keys
try {
    $UrlsFile = "$PSScriptRoot\..\config\enrollmenturls.txt"
    $DiscoveryUrls = if (Test-Path $UrlsFile) {
        Get-Content $UrlsFile | Where-Object { $_ -match "^https?://" }
    } else {
        @("https://wip.mam.manage.microsoft.com/Enroll")
    }
    $Enrollments = Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Enrollments\" -ErrorAction Stop
    $ToRemove = 0
    foreach ($E in $Enrollments) {
        try {
            $Obj = Get-ItemProperty Registry::$E -ErrorAction Stop
            if ($Obj."DiscoveryServiceFullURL" -in $DiscoveryUrls -or
                $Obj.PSChildName -match "^[A-f0-9]{8}(-[A-f0-9]{4}){3}-[A-f0-9]{12}$") {
                $ToRemove++
            }
        } catch {}
    }
    Add-Result "Enrollment keys" "$ToRemove to remove" "INFO"
} catch {
    Add-Result "Enrollment keys" "Unable to check" "WARN"
}

# Sync Center
try {
    $Enabled = (Get-WmiObject -Class win32_OfflineFilesCache).Enabled
    $Value = if ($Enabled) { "Enabled (will be disabled)" } else { "Already disabled" }
    Add-Result "Sync Center" $Value "INFO"
} catch {
    Add-Result "Sync Center" "Unable to check" "WARN"
}

# AAD broker plugin folders
$BrokerFolders = @(Get-ChildItem -Path "C:\Users\*\AppData\Local\Packages" -Filter "Microsoft.AAD.BrokerPlugin*" -Directory -ErrorAction SilentlyContinue)
Add-Result "AAD broker folders" "$($BrokerFolders.Count) found" "INFO"

# Display results
Write-Host ""
Write-Host "=== Pre-flight check ==="
foreach ($R in $Results) {
    $Color = switch ($R.Status) {
        "OK"    { "Green"  }
        "FAIL"  { "Red"    }
        "WARN"  { "Yellow" }
        default { "Gray"   }
    }
    Write-Host ("{0,-28} {1}" -f $R.Check, $R.Value) -ForegroundColor $Color
}
Write-Host "========================"
Write-Host ""

if ($Results | Where-Object { $_.Status -eq "FAIL" }) {
    Write-Host "One or more checks show potential blockers (shown in red). Review before continuing." -ForegroundColor Yellow
    Write-Host ""
}

$Resp = Read-Host "Proceed with migration? (y/n)"
if ($Resp.ToLower() -ne "y") {
    throw "Migration cancelled by user at pre-flight."
}
