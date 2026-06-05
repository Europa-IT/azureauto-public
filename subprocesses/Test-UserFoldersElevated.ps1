# Standalone script for key checking that requires elevation.

$HKLMPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\"

$UsrShellFld = "User Shell Folders"
$ShellFld = "Shell Folders"

try {
    $DesktopKey = Get-ItemPropertyValue -Path ($HKLMPath + $UsrShellFld) -Name "Desktop" -ErrorAction Stop
    $DocumentsKey = Get-ItemPropertyValue -Path ($HKLMPath + $UsrShellFld) -Name "Personal" -ErrorAction Stop
    $PicturesKey = Get-ItemPropertyValue -Path ($HKLMPath + $UsrShellFld) -Name "My Pictures" -ErrorAction Stop
}
catch {

    try {
        $DesktopKey = Get-ItemPropertyValue -Path ($HKLMPath + $ShellFld) -Name "Desktop" -ErrorAction Stop
        $DocumentsKey = Get-ItemPropertyValue -Path ($HKLMPath + $ShellFld) -Name "Personal" -ErrorAction Stop
        $PicturesKey = Get-ItemPropertyValue -Path ($HKLMPath + $ShellFld) -Name "My Pictures" -ErrorAction Stop
    }
    catch {
        Throw "Unable to determine user folder locations."
    }
}

Return @($DesktopKey, $DocumentsKey, $PicturesKey)
