# Standalone script for removing personal Azure join

$BrokerFolders = Get-ChildItem -Path "C:\Users\*\AppData\Local\Packages" -Filter "Microsoft.AAD.BrokerPlugin*" -Directory -ErrorAction SilentlyContinue
Write-Host "Found $(@($BrokerFolders).Count) AAD broker folder(s) to remove."

$FailedRemovals = @()
foreach ($Folder in $BrokerFolders) {
    try {
        Remove-Item -Path $Folder.FullName -Recurse -Force -ErrorAction Stop
        Write-Host "Removed: $($Folder.FullName)"
    } catch {
        $FailedRemovals += $Folder.FullName
    }
}

if ($FailedRemovals.Count -gt 0) {
    Write-Host "Warning: Failed to remove the following AAD broker folders (may need manual removal after restart):"
    $FailedRemovals | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "All AAD broker folders removed successfully."
}

Read-Host "User AAD key removal complete, press Enter to restart"
Restart-Computer -Force
