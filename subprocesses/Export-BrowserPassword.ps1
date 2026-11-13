<#
.SYNOPSIS
    Guides a saved-password export/re-import around a profile migration, using each
    browser's own authenticated export - it never decrypts the credential store itself.

.DESCRIPTION
    Run this AS THE USER BEING MIGRATED, in their own desktop session (not from the
    elevated migration window). The browsers' built-in export can only read the
    credentials of the user whose session owns the DPAPI keys, so it must run in
    that user's context.

    Workflow:
      1. Before migrating, run with -Mode Export. The script creates a locked-down
         folder and walks you through each browser's own Export command. The browser
         authenticates you (Windows Hello / account password) and writes a plaintext
         CSV that you save into that folder.
      2. Run ProfWiz / the migration.
      3. After migrating, run with -Mode Import. The script walks you through each
         browser's own Import command against the CSVs.
      4. Run with -Mode Cleanup to securely overwrite and delete the CSVs. ALWAYS do
         this - the CSVs hold passwords in clear text.

    Why not fully automatic? A browser's saved passwords are encrypted with keys tied
    to the user (DPAPI / app-bound encryption). Decrypting them from a script, without
    the browser's own authenticated export, is exactly what credential-stealing malware
    does and would leave plaintext on disk unprompted. This script keeps the decrypt
    inside the browser, behind its own authentication prompt.

.PARAMETER Mode
    Export (default), Import, or Cleanup.

.PARAMETER ExportPath
    Folder for the temporary CSVs. Default C:\azureauto-pwexport. Kept outside the user
    profile so it survives the migration. Created with inheritance removed and access
    limited to the current user and Administrators.

.EXAMPLE
    .\Export-BrowserPassword.ps1 -Mode Export
.EXAMPLE
    .\Export-BrowserPassword.ps1 -Mode Import
.EXAMPLE
    .\Export-BrowserPassword.ps1 -Mode Cleanup
#>
[CmdletBinding()]
param(
    [ValidateSet("Export", "Import", "Cleanup")]
    [string]$Mode = "Export",

    [string]$ExportPath = (Join-Path $env:SystemDrive "azureauto-pwexport")
)

function Write-Step {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host $Message -ForegroundColor $Color
}

function Get-FirstExistingPath {
    param([string[]]$Candidates)
    foreach ($Path in $Candidates) {
        if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) { return $Path }
    }
    return $null
}

# Each browser: where it is installed, whether this user has a store, the settings page
# that hosts Export/Import, and the CSV filename we use. Exact menu labels drift between
# versions, so the script opens the right page and prints the steps rather than clicking.
function Get-Browser {
    $Browsers = @()

    $Chrome = Get-FirstExistingPath @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $Browsers += [PSCustomObject]@{
        Name       = "Chrome"
        Exe        = $Chrome
        StoreDir   = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        Csv        = "chrome-passwords.csv"
        ExportUrl  = "chrome://password-manager/settings"
        ImportUrl  = "chrome://password-manager/settings"
        ExportStep = 'Click "Download file" / Export passwords, authenticate, and save it as the path below.'
        ImportStep = 'Click Import / "Select file", choose the CSV below, and confirm.'
    }

    $Edge = Get-FirstExistingPath @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )
    $Browsers += [PSCustomObject]@{
        Name       = "Edge"
        Exe        = $Edge
        StoreDir   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
        Csv        = "edge-passwords.csv"
        ExportUrl  = "edge://settings/passwords"
        ImportUrl  = "edge://settings/passwords"
        ExportStep = 'Open the "..." menu by Saved passwords, choose Export passwords, authenticate, and save it as the path below.'
        ImportStep = 'Open the "..." menu by Saved passwords, choose Import passwords, choose the CSV below, and confirm.'
    }

    $Firefox = Get-FirstExistingPath @(
        "$env:ProgramFiles\Mozilla Firefox\firefox.exe",
        "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
    )
    $Browsers += [PSCustomObject]@{
        Name       = "Firefox"
        Exe        = $Firefox
        StoreDir   = "$env:APPDATA\Mozilla\Firefox\Profiles"
        Csv        = "firefox-passwords.csv"
        ExportUrl  = "about:logins"
        ImportUrl  = "about:logins"
        ExportStep = 'Open the "..." menu (top right), choose Export Logins, authenticate, and save it as the path below.'
        ImportStep = 'Open the "..." menu (top right), choose Import from a CSV File, and choose the CSV below.'
    }

    # Only browsers that are installed AND hold a credential store for this user.
    $Browsers | Where-Object { $_.Exe -and (Test-Path -LiteralPath $_.StoreDir) }
}

function Get-CurrentUserSid { [Security.Principal.WindowsIdentity]::GetCurrent().User }
function Get-AdminsSid {
    New-Object System.Security.Principal.SecurityIdentifier(
        [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
}

function Assert-RestrictedAcl {
    param([string]$Path)
    # Owner alone is not enough: a folder owned by us/Administrators could still have had
    # its DACL widened (Everyone:F via WRITE_DAC, or left inheriting). Confirm the DACL is
    # protected from inheritance and every Allow ACE is the current user, Administrators or
    # SYSTEM - otherwise the plaintext CSVs are readable by someone they should not be.
    $Acl = Get-Acl -LiteralPath $Path
    if (-not $Acl.AreAccessRulesProtected) {
        throw "$Path still inherits permissions from its parent. Refusing to use it for plaintext passwords."
    }
    $Allowed = @((Get-CurrentUserSid).Value, (Get-AdminsSid).Value, "S-1-5-18")  # S-1-5-18 = SYSTEM
    foreach ($Ace in $Acl.Access) {
        if ($Ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        $Sid = try { $Ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $Ace.IdentityReference.Value }
        if ($Sid -notin $Allowed) {
            $Who = try { $Ace.IdentityReference.Value } catch { $Sid }
            throw "$Path grants access to $Who, which is not the current user, Administrators or SYSTEM. Refusing to use it for plaintext passwords."
        }
    }
}

function New-SecureExportDirectory {
    param([string]$Path)

    # Plaintext passwords get written here, so the folder must be created FRESH. Creating
    # it (and failing if it already exists) in one step means:
    #   - no pre-existing child files or sub-folders, and no explicit ACLs left on them;
    #   - no time-of-check/time-of-use race on a predictable path - there is no "check
    #     then use" gap, the create itself is the check.
    # A leftover folder from an aborted run must be removed (run -Mode Cleanup) first.
    try {
        New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
    } catch {
        throw "Could not create a fresh export folder at $Path (it may already exist from an earlier run). Run -Mode Cleanup or remove it, or pass a fresh -ExportPath. Underlying error: $($_.Exception.Message)"
    }

    # Lock the DACL down to current user + Administrators, non-inherited. icacls only
    # touches the DACL (no owner/SACL, so no SeSecurityPrivilege needed) and behaves the
    # same on Windows PowerShell 5.1 and 7. SID form avoids localised account names. We
    # just created and own the folder, so there is no window for another user to swap it
    # before this runs. Abort if icacls fails, so passwords never land in an unlocked folder.
    $Me = Get-CurrentUserSid
    $Admins = Get-AdminsSid
    & icacls $Path /inheritance:r /grant:r "*$($Me.Value):(OI)(CI)F" "*$($Admins.Value):(OI)(CI)F" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue
        throw "Failed to restrict permissions on $Path (icacls exit $LASTEXITCODE). Refusing to continue."
    }

    # Confirm the lock actually took before anything is written into the folder.
    try {
        Assert-RestrictedAcl -Path $Path
    } catch {
        Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue
        throw
    }
}

function Assert-SafeDirectory {
    param([string]$Path)

    # Validate an EXISTING export folder before Import/Cleanup reuse it: it must be a real
    # directory (not a reparse point redirecting elsewhere) owned by us or Administrators,
    # so a local attacker cannot have swapped in a folder whose contents they control.
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($Item -isnot [System.IO.DirectoryInfo]) {
        throw "$Path is not a directory. Refusing to use it."
    }
    if ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "$Path is a reparse point (symlink/junction). Refusing to use it."
    }
    $Owner = (Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier])
    if ($Owner -ne (Get-CurrentUserSid) -and $Owner -ne (Get-AdminsSid)) {
        $OwnerName = try { $Owner.Translate([System.Security.Principal.NTAccount]).Value } catch { $Owner.Value }
        throw "$Path is owned by $OwnerName, not you or Administrators. Refusing to use it."
    }
    Assert-RestrictedAcl -Path $Path
}

function Remove-SecureFile {
    param([string]$Path)
    # Never overwrite through a link: a symlink/hardlink planted as *.csv would send the
    # random bytes to whatever it points at (arbitrary file overwrite). Delete the link
    # itself instead and skip the wipe.
    $Item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $Item) { return }
    if ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Write-Warning "$Path is a reparse point; removing the link without overwriting its target."
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return
    }
    if ($Item.LinkType) {
        Write-Warning "$Path is a $($Item.LinkType); removing the link without overwriting its target."
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return
    }
    # Best-effort wipe: overwrite the bytes, then delete. On SSDs wear-levelling can
    # leave remnants, so treat deletion of the folder as defence-in-depth, not a guarantee.
    try {
        $Length = $Item.Length
        if ($Length -gt 0) {
            $Bytes = New-Object byte[] $Length
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($Bytes)
            [System.IO.File]::WriteAllBytes($Path, $Bytes)
        }
    } catch {
        Write-Warning "Could not overwrite $Path before delete: $($_.Exception.Message)"
    }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

# --- Guards ---------------------------------------------------------------------------

if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Running elevated. The browser export reads the CURRENT user's passwords, so run this as the user being migrated - not from the elevated migration window - or you will export the admin account's passwords instead."
    if ((Read-Host "Continue anyway? (y/n)").ToLower() -ne "y") { return }
}

$Browsers = @(Get-Browser)
if ($Browsers.Count -eq 0) {
    Write-Host "No installed browser with a saved-password store was found for $env:USERNAME. Nothing to do." -ForegroundColor Green
    return
}

# --- Modes ----------------------------------------------------------------------------

switch ($Mode) {

    "Export" {
        New-SecureExportDirectory -Path $ExportPath
        Write-Host ""
        Write-Host "Exporting saved passwords to: $ExportPath" -ForegroundColor Yellow
        Write-Warning "These CSV files contain passwords in CLEAR TEXT. Run -Mode Cleanup after re-importing."
        Write-Host ""

        foreach ($B in $Browsers) {
            $Target = Join-Path $ExportPath $B.Csv
            Write-Host "--- $($B.Name) ---" -ForegroundColor White
            Write-Step "Opening $($B.ExportUrl)"
            Start-Process -FilePath $B.Exe -ArgumentList $B.ExportUrl | Out-Null
            Write-Step $B.ExportStep
            Write-Step "Save as: $Target" "Yellow"
            Read-Host "Press Enter once you have saved $($B.Csv) (or to skip this browser)"
            if (Test-Path -LiteralPath $Target -PathType Leaf) {
                Write-Host "Found $($B.Csv) - OK" -ForegroundColor Green
            } else {
                Write-Warning "$Target not found. $($B.Name) passwords were not exported."
            }
            Write-Host ""
        }
        Write-Host "Export step complete. Run the migration, then re-run with -Mode Import." -ForegroundColor Green
    }

    "Import" {
        if (-not (Test-Path -LiteralPath $ExportPath)) {
            Write-Warning "No export folder at $ExportPath. Nothing to import."
            return
        }
        Assert-SafeDirectory -Path $ExportPath
        foreach ($B in $Browsers) {
            $Source = Join-Path $ExportPath $B.Csv
            if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
                Write-Host "No $($B.Csv) to import for $($B.Name). Skipping." -ForegroundColor Gray
                continue
            }
            Write-Host "--- $($B.Name) ---" -ForegroundColor White
            Write-Step "Opening $($B.ImportUrl)"
            Start-Process -FilePath $B.Exe -ArgumentList $B.ImportUrl | Out-Null
            Write-Step $B.ImportStep
            Write-Step "CSV to choose: $Source" "Yellow"
            Read-Host "Press Enter once the import is done"
            Write-Host ""
        }
        Write-Host "Import step complete. Verify the passwords, then run with -Mode Cleanup." -ForegroundColor Green
    }

    "Cleanup" {
        if (-not (Test-Path -LiteralPath $ExportPath)) {
            Write-Host "Nothing to clean up at $ExportPath." -ForegroundColor Green
            return
        }
        Assert-SafeDirectory -Path $ExportPath
        Write-Warning "This securely deletes every exported password CSV in $ExportPath."
        if ((Read-Host "Proceed? (y/n)").ToLower() -ne "y") { return }
        foreach ($Csv in (Get-ChildItem -LiteralPath $ExportPath -Filter *.csv -File -ErrorAction SilentlyContinue)) {
            Remove-SecureFile -Path $Csv.FullName
            Write-Host "Wiped $($Csv.Name)" -ForegroundColor Green
        }
        # Remove the folder only if nothing else was left in it.
        if (@(Get-ChildItem -LiteralPath $ExportPath -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $ExportPath -Force -ErrorAction SilentlyContinue
            Write-Host "Removed $ExportPath" -ForegroundColor Green
        } else {
            Write-Warning "$ExportPath still contains other files; left in place. Review and remove manually."
        }
    }
}
