# Returns the AAD broker plugin package folders for every user profile on the device.
# Profiles are enumerated individually: a wildcard such as C:\Users\*\AppData does not match the hidden AppData folder.
# Junctions/symlinks are skipped anywhere in the path: these folders are user-writable and the results are deleted elevated.

$ProfileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$ReparsePoint = [System.IO.FileAttributes]::ReparsePoint

Get-ChildItem -Path $ProfileListPath | ForEach-Object {
    $ProfilePath = $_.GetValue("ProfileImagePath")
    if (-not $ProfilePath) { return }
    $Current = [Environment]::ExpandEnvironmentVariables($ProfilePath)

    foreach ($Part in @("AppData", "Local", "Packages")) {
        $Current = Join-Path $Current $Part
        $Item = Get-Item -LiteralPath $Current -Force -ErrorAction SilentlyContinue
        if ($null -eq $Item -or ($Item.Attributes -band $ReparsePoint)) { return }
    }

    Get-ChildItem -LiteralPath $Current -Filter "Microsoft.AAD.BrokerPlugin*" -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band $ReparsePoint) }
}
