# Standalone script for checking user folder locations

$HKCUPath = "Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\"
$UsrShellFld = "User Shell Folders"
$ShellFld = "Shell Folders"

try {
    $DesktopKey = Get-ItemPropertyValue -Path ($HKCUPath + $UsrShellFld) -Name "Desktop" -ErrorAction Stop
    $DocumentsKey = Get-ItemPropertyValue -Path ($HKCUPath + $UsrShellFld) -Name "Personal" -ErrorAction Stop
    $PicturesKey = Get-ItemPropertyValue -Path ($HKCUPath + $UsrShellFld) -Name "My Pictures" -ErrorAction Stop
}
catch {
    try {
        $DesktopKey = Get-ItemPropertyValue -Path ($HKCUPath + $ShellFld) -Name "Desktop" -ErrorAction Stop
        $DocumentsKey = Get-ItemPropertyValue -Path ($HKCUPath + $ShellFld) -Name "Personal" -ErrorAction Stop
        $PicturesKey = Get-ItemPropertyValue -Path ($HKCUPath + $ShellFld) -Name "My Pictures" -ErrorAction Stop
    }
    catch {
        $DesktopKey, $DocumentsKey, $PicturesKey = & "$PSScriptRoot\Test-UserFoldersElevated.ps1" -ErrorAction Stop
    }
}

$UsrFolder = $env:USERPROFILE
$DesktopParent = Split-Path -Parent $DesktopKey
$DocumentsParent = Split-Path -Parent $DocumentsKey
$PicturesParent = Split-Path -Parent $PicturesKey

if ($DesktopParent -ne $UsrFolder) {
    Throw ("Desktop folder is redirected to {0}." -f $DesktopKey)

}
elseif ($DocumentsParent -ne $UsrFolder) {
    Throw ("Documents folder is redirected to {0}." -f $DocumentsKey)
}
elseif ($PicturesParent -ne $UsrFolder) {
    Throw ("Pictures folder is redirected to {0}." -f $PicturesKey)
}

Write-Host "Desktop, Documents, and Pictures are all located in the local user folder."
