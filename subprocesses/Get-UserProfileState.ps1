# Read-only scan of every user profile on the device (not just the account running this script).
# Loads NTUSER.DAT for profiles that are not signed in, then unloads it again.
# Returns one object per profile with shell folder locations and personal Microsoft accounts.

$ProfileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$ShellFoldersSubKey = "Software\Microsoft\Windows\CurrentVersion\Explorer"
$StoredIdentitiesSubKey = "Software\Microsoft\IdentityCRL\StoredIdentities"

# Registry value name -> folder name in the profile root
$Folders = @(
    @{ Name = "Desktop";   RegKey = "Desktop"     },
    @{ Name = "Documents"; RegKey = "Personal"    },
    @{ Name = "Pictures";  RegKey = "My Pictures" }
)

function Get-ShellFolderPath {
    param([string]$HiveRoot, [string]$RegKey, [string]$ProfilePath)

    foreach ($SubKey in @("User Shell Folders", "Shell Folders")) {
        $Key = [Microsoft.Win32.Registry]::Users.OpenSubKey("$HiveRoot\$ShellFoldersSubKey\$SubKey")
        if ($null -eq $Key) { continue }
        try {
            # Do not expand: %USERPROFILE% would expand to the account running this script.
            $Raw = $Key.GetValue($RegKey, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } finally {
            $Key.Close()
        }
        if ($Raw) {
            $Raw = $Raw -replace "%USERPROFILE%", $ProfilePath.Replace('$', '$$')
            return [Environment]::ExpandEnvironmentVariables($Raw)
        }
    }
    return $null
}

$Profiles = Get-ChildItem -Path $ProfileListPath | Where-Object {
    # Local/domain users (S-1-5-21) and Entra ID users (S-1-12-1); skips SYSTEM and service accounts.
    $_.PSChildName -match "^S-1-(5-21|12-1)-"
}

foreach ($Entry in $Profiles) {
    $Sid = $Entry.PSChildName
    $ProfilePath = $Entry.GetValue("ProfileImagePath")
    if (-not $ProfilePath) { continue }
    $ProfilePath = [Environment]::ExpandEnvironmentVariables($ProfilePath).TrimEnd('\')

    $State = [PSCustomObject]@{
        Sid              = $Sid
        UserName         = Split-Path -Leaf $ProfilePath
        ProfilePath      = $ProfilePath
        HiveStatus       = "Unavailable"
        Folders          = @()
        PersonalAccounts = @()
    }

    $HiveRoot = $null
    $Mounted = $false
    if (Test-Path "Registry::HKEY_USERS\$Sid") {
        $HiveRoot = $Sid
        $State.HiveStatus = "Loaded"
    } elseif (Test-Path "$ProfilePath\NTUSER.DAT" -PathType Leaf) {
        $HiveRoot = "azureauto_$Sid"
        reg.exe load "HKU\$HiveRoot" "$ProfilePath\NTUSER.DAT" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $Mounted = $true
            $State.HiveStatus = "Mounted"
        } else {
            $HiveRoot = $null
        }
    }

    if ($null -ne $HiveRoot) {
        try {
            $State.Folders = @(foreach ($Folder in $Folders) {
                $Path = Get-ShellFolderPath -HiveRoot $HiveRoot -RegKey $Folder.RegKey -ProfilePath $ProfilePath
                $LocalPath = Join-Path $ProfilePath $Folder.Name
                $Redirected = ($null -ne $Path) -and (
                    $Path.StartsWith("\\") -or
                    (Split-Path -Parent $Path.TrimEnd('\')) -ne $ProfilePath
                )
                [PSCustomObject]@{
                    Name          = $Folder.Name
                    Path          = $Path
                    Redirected    = $Redirected
                    # A folder already sitting at the local path blocks the GPO from moving the redirected folder back.
                    LocalConflict = $Redirected -and (Test-Path $LocalPath -PathType Container)
                    LocalPath     = $LocalPath
                }
            })

            $Key = [Microsoft.Win32.Registry]::Users.OpenSubKey("$HiveRoot\$StoredIdentitiesSubKey")
            if ($null -ne $Key) {
                try {
                    $State.PersonalAccounts = @($Key.GetSubKeyNames())
                } finally {
                    $Key.Close()
                }
            }
        } finally {
            if ($Mounted) {
                # Release handles held by .NET before unloading, or reg unload fails with "access denied".
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
                reg.exe unload "HKU\$HiveRoot" 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Could not unload registry hive for $($State.UserName) (HKU\$HiveRoot). Restart before running ProfWiz."
                }
            }
        }
    }

    $State
}
