# Standalone script for checking user folder locations across every user profile on the device.

$Problems = @()
foreach ($State in & "$PSScriptRoot\Get-UserProfileState.ps1") {
    if ($State.HiveStatus -eq "Unavailable") {
        Write-Host ("Could not read registry for {0}, folder locations not checked." -f $State.UserName)
        continue
    }
    foreach ($Folder in $State.Folders | Where-Object { $_.Redirected }) {
        $Problem = "{0}: {1} folder is redirected to {2}." -f $State.UserName, $Folder.Name, $Folder.Path
        if ($Folder.LocalConflict) {
            $Problem += " {0} already exists and will block the GPO from moving it back; rename or remove it." -f $Folder.LocalPath
        }
        $Problems += $Problem
    }
}

if ($Problems.Count -gt 0) {
    $Problems | ForEach-Object { Write-Host $_ }
    Throw ("{0} redirected folder(s) found." -f $Problems.Count)
}

Write-Host "Desktop, Documents, and Pictures are located in the local user folder for all profiles."
