Write-Host "Checking TPM version."

try {
    $TPMOutput = TPMTool GetDeviceInformation 2>&1
} catch {
    throw "TPMTool could not be run. Cannot verify TPM version: $_"
}

$TPMLine = $TPMOutput | Select-String -Pattern "TPM Version"
if ($null -eq $TPMLine) {
    throw "Unable to determine TPM version from TPMTool output."
}

$TPMVersion = ($TPMLine.Line -Split ": ")[-1].Trim()
Write-Host "TPM version: $TPMVersion"

if ([double]$TPMVersion -lt 2.0) {
    $Response = Read-Host "TPM Version is $TPMVersion, exit? y/n"
    if ($Response.ToLower() -ne "n") {
        throw "TPM version < 2.0, exiting."
    }
}
