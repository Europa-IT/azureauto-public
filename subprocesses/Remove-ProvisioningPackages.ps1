# Standalone script for provisioning package removal

try {
    Uninstall-ProvisioningPackage -AllInstalledPackages -ErrorAction Stop
    $InstalledPackages = Get-ProvisioningPackage -AllInstalledPackages -ErrorAction Stop
    if ($null -ne $InstalledPackages) {
        throw "Unable to remove provisioning packages entirely: {0}" -f $InstalledPackages
    }
} catch {
    throw "Removal of one or more provisioning packages failed."
}
