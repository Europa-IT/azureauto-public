#--------------------------------------------------------------------------------
#
# Check Microsoft.Graph is installed
#
$getmodule = Get-Module -ListAvailable "Microsoft.Graph" | Sort-Object Version -Descending
$installedversion = ($getmodule | Select-Object -First 1).Version

if (-not $getmodule) {
    $install = Read-Host "The Microsoft.Graph PowerShell module is not installed. Do you want to install it now? (Y/n)"
    if ($install -eq "" -or $install -eq "Y" -or $install -eq "Yes") {
        if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
            Write-Warning "Administrator permissions are needed to install the Microsoft.Graph PowerShell module.`nPlease re-run this script as an Administrator."
            Exit
        }
        Install-Module Microsoft.Graph -Scope AllUsers
    } else {
        Exit
    }
}

#--------------------------------------------------------------------------------
#
# Main process
#

# Output path matches what buildprofwiz.ps1 expects: the project root directory.
$OutputPath = "$PSScriptRoot\..\ForensiTAzureID.xml"

try {
    # Disconnect any existing session
    if (Get-MgContext) {
        Disconnect-MgGraph | Out-Null
    }

    # Authenticate interactively
    Connect-MgGraph -Scopes @("User.Read.All", "Organization.Read.All") -NoWelcome -ContextScope Process

    Write-Host "Fetching tenant details..."
    $tenant = Get-MgOrganization -ErrorAction Stop

    Write-Host "Fetching users (this may take a moment for large tenants)..."
    $users = Get-MgUser -All -ErrorAction Stop
    Write-Host "Found $($users.Count) user(s)."

    # Resolve the primary verified domain
    $primaryDomain = ($tenant.VerifiedDomains | Where-Object { $_.IsDefault } | Select-Object -First 1).Name
    if (-not $primaryDomain) {
        $primaryDomain = ($tenant.VerifiedDomains | Select-Object -First 1).Name
    }

    # Write XML
    $xmlsettings = New-Object System.Xml.XmlWriterSettings
    $xmlsettings.Indent = $true
    $xmlsettings.IndentChars = "    "

    $XmlWriter = [System.Xml.XmlWriter]::Create($OutputPath, $xmlsettings)
    try {
        $xmlWriter.WriteStartDocument()
        $xmlWriter.WriteProcessingInstruction("xml-stylesheet", "type='text/xsl' href='style.xsl'")
        $xmlWriter.WriteStartElement("ForensiTAzureID")
        $xmlWriter.WriteAttributeString("ObjectId", $tenant.Id)
        $xmlWriter.WriteAttributeString("Name", $primaryDomain)
        $xmlWriter.WriteAttributeString("DisplayName", $tenant.DisplayName)

        foreach ($user in $users) {
            $xmlWriter.WriteStartElement("User")
            $xmlWriter.WriteElementString("UserPrincipalName", $user.UserPrincipalName)
            $xmlWriter.WriteElementString("ObjectId", $user.Id)
            $xmlWriter.WriteElementString("DisplayName", $user.DisplayName)
            $xmlWriter.WriteEndElement()
        }

        $xmlWriter.WriteEndElement()
        $xmlWriter.WriteEndDocument()
    } finally {
        $xmlWriter.Flush()
        $xmlWriter.Close()
    }

    Disconnect-MgGraph | Out-Null
    Write-Host "Azure user ID file created: $OutputPath" -ForegroundColor Green
}
catch {
    Write-Host "Save-AzureADUser.ps1 failed: $_" -ForegroundColor Red
    Exit 1
}
