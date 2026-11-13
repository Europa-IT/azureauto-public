# Read-only pre-flight system check

[CmdletBinding()]
param(
    # Provisioning package named in Profwiz.config; blank when the build has none.
    [string]$ProvPackageName = ""
)

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

# Entra (Azure AD) join. Without a provisioning package ProfWiz does not join the device,
# so it must already be joined to the tenant the user IDs in ForensiTAzureID.xml came from.
if ($ProvPackageName -eq "") {
    try {
        $TenantInfo = ([xml](Get-Content -Path "$PSScriptRoot\ForensiTAzureID.xml" -Raw -ErrorAction Stop)).ForensiTAzureID
        $ExpectedTenantId = $TenantInfo.ObjectId
        if (-not $ExpectedTenantId) { throw "No tenant ID in ForensiTAzureID.xml." }
        $ExpectedTenantLabel = "$($TenantInfo.DisplayName) ($ExpectedTenantId)"

        $DsregOutput = dsregcmd /status
        if ($LASTEXITCODE -ne 0) { throw "dsregcmd exited with code $LASTEXITCODE." }
        # Tenant lines are only printed when the device is joined.
        $DsregValues = @{}
        foreach ($Key in "AzureAdJoined", "TenantId", "TenantName") {
            $Match = $DsregOutput | Select-String -Pattern "^\s*$Key\s*:\s*(.+?)\s*$" | Select-Object -First 1
            $DsregValues[$Key] = if ($null -ne $Match) { $Match.Matches[0].Groups[1].Value } else { "" }
        }
        if ($DsregValues.AzureAdJoined -eq "") { throw "No AzureAdJoined line in dsregcmd output." }

        if ($DsregValues.AzureAdJoined -ne "YES") {
            Add-Result "Entra join" "Not joined; expected $ExpectedTenantLabel (no provisioning package to join it)" "FAIL"
        } elseif ($DsregValues.TenantId -eq $ExpectedTenantId) {
            Add-Result "Entra join" "Joined to $ExpectedTenantLabel" "OK"
        } else {
            Add-Result "Entra join" "Joined to $($DsregValues.TenantName) ($($DsregValues.TenantId)); expected $ExpectedTenantLabel" "FAIL"
        }
    } catch {
        Add-Result "Entra join" "Unable to check: $($_.Exception.Message)" "WARN"
    }
}

# Per-profile checks (every user on the device, not the elevated account running this script)
$AnyRedirected = $false
try {
    $ProfileStates = @(& "$PSScriptRoot\Get-UserProfileState.ps1")
    foreach ($State in $ProfileStates) {
        $Label = "Folders ($($State.UserName))"
        if ($State.HiveStatus -eq "Unavailable") {
            Add-Result $Label "Unable to read registry" "WARN"
        } else {
            $Redirected = @($State.Folders | Where-Object { $_.Redirected })
            if ($Redirected.Count -eq 0) {
                Add-Result $Label "Local" "OK"
            } else {
                $AnyRedirected = $true
                foreach ($Folder in $Redirected) {
                    $Value = "$($Folder.Name) redirected to $($Folder.Path)"
                    if ($Folder.LocalConflict) {
                        $Value += "; $($Folder.LocalPath) exists and will block GPO move-back"
                    }
                    Add-Result $Label $Value "FAIL"
                }
            }
        }
        if ($State.PersonalAccounts.Count -gt 0) {
            Add-Result "Personal MS accts ($($State.UserName))" (($State.PersonalAccounts -join ", ") + " - sign out of Teams/Settings first") "FAIL"
        }
    }
    if ($ProfileStates.Count -eq 0) {
        Add-Result "User profiles" "None found" "WARN"
    }
} catch {
    Add-Result "User profiles" "Unable to check: $($_.Exception.Message)" "WARN"
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
    if ($Enabled -and $AnyRedirected) {
        Add-Result "Sync Center" "Enabled with redirected folders - restart required after disabling" "FAIL"
    } else {
        $Value = if ($Enabled) { "Enabled (will be disabled)" } else { "Already disabled" }
        Add-Result "Sync Center" $Value "INFO"
    }
} catch {
    Add-Result "Sync Center" "Unable to check" "WARN"
}

# AAD broker plugin folders
$BrokerFolders = @(& "$PSScriptRoot\Get-AadBrokerFolders.ps1")
Add-Result "AAD broker folders" "$($BrokerFolders.Count) found" "INFO"

# Saved browser passwords (so the user does not silently lose logins in the migration)
try {
    $CredStates = @(& "$PSScriptRoot\Get-BrowserCredentialState.ps1")
    if ($CredStates.Count -eq 0) {
        Add-Result "Saved passwords" "None found" "INFO"
    } else {
        foreach ($Group in ($CredStates | Group-Object UserName)) {
            $Parts = foreach ($Browser in ($Group.Group | Group-Object Browser)) {
                $Counts = @($Browser.Group | ForEach-Object { $_.CredentialCount })
                if ($Counts -contains $null) {
                    "$($Browser.Name): present (count unavailable)"
                } else {
                    "$($Browser.Name): $(($Counts | Measure-Object -Sum).Sum)"
                }
            }
            # WARN, not FAIL: it does not block migration, but the technician should
            # back these up (browser sync or Export-BrowserPassword.ps1) first.
            Add-Result "Saved passwords ($($Group.Name))" ($Parts -join ", ") "WARN"
        }
    }
} catch {
    Add-Result "Saved passwords" "Unable to check: $($_.Exception.Message)" "WARN"
}

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
    Write-Host ("{0,-34} {1}" -f $R.Check, $R.Value) -ForegroundColor $Color
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
