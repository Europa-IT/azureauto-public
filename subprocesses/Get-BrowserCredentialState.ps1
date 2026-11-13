# Read-only scan of saved browser passwords for every user profile on the device
# (not just the account running this script).
#
# Reports WHETHER each user has saved passwords in Chrome, Edge or Firefox, and
# HOW MANY, so the technician knows what the user stands to lose if the migration
# does not carry the credential store across. It never decrypts anything:
#   - Chromium "Login Data" is a SQLite database; this counts rows in the "logins"
#     table. The usernames/passwords in those rows stay encrypted and are never read.
#   - Firefox "logins.json" is counted by the length of its "logins" array; the
#     encrypted "encryptedUsername"/"encryptedPassword" fields are never read.
#
# Returns one object per (user profile x browser) that has a credential store.

$ProfileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

# winsqlite3.dll ships with Windows 10/11, so counting Chromium rows needs no
# external dependency. Wrap it once per session.
if (-not ("AzureAuto.Sqlite" -as [type])) {
    Add-Type -Namespace AzureAuto -Name Sqlite -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("winsqlite3.dll", EntryPoint="sqlite3_open16", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int Open(string filename, out System.IntPtr db);

[System.Runtime.InteropServices.DllImport("winsqlite3.dll", EntryPoint="sqlite3_prepare16_v2", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int Prepare(System.IntPtr db, string sql, int nByte, out System.IntPtr stmt, System.IntPtr tail);

[System.Runtime.InteropServices.DllImport("winsqlite3.dll", EntryPoint="sqlite3_step")]
public static extern int Step(System.IntPtr stmt);

[System.Runtime.InteropServices.DllImport("winsqlite3.dll", EntryPoint="sqlite3_column_int")]
public static extern int ColumnInt(System.IntPtr stmt, int col);

[System.Runtime.InteropServices.DllImport("winsqlite3.dll", EntryPoint="sqlite3_finalize")]
public static extern int Finalize(System.IntPtr stmt);

[System.Runtime.InteropServices.DllImport("winsqlite3.dll", EntryPoint="sqlite3_close")]
public static extern int Close(System.IntPtr db);
'@
}

function Get-ChromiumLoginCount {
    param([string]$LoginDataPath)

    # Copy first: the file is locked while the browser runs, and we must never
    # write to the live store. A GUID temp name avoids collisions across profiles.
    $Temp = Join-Path $env:TEMP ("azureauto-logindata-{0}.db" -f [guid]::NewGuid())
    $Db = [IntPtr]::Zero
    $Stmt = [IntPtr]::Zero
    try {
        Copy-Item -LiteralPath $LoginDataPath -Destination $Temp -Force -ErrorAction Stop

        if ([AzureAuto.Sqlite]::Open($Temp, [ref]$Db) -ne 0) { return $null }
        # -1 lets SQLite read the SQL up to its null terminator.
        if ([AzureAuto.Sqlite]::Prepare($Db, "SELECT COUNT(*) FROM logins", -1, [ref]$Stmt, [IntPtr]::Zero) -ne 0) { return $null }
        # 100 = SQLITE_ROW
        if ([AzureAuto.Sqlite]::Step($Stmt) -ne 100) { return $null }
        return [AzureAuto.Sqlite]::ColumnInt($Stmt, 0)
    } catch {
        return $null
    } finally {
        if ($Stmt -ne [IntPtr]::Zero) { [void][AzureAuto.Sqlite]::Finalize($Stmt) }
        if ($Db -ne [IntPtr]::Zero) { [void][AzureAuto.Sqlite]::Close($Db) }
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
    }
}

function Get-FirefoxLoginCount {
    param([string]$LoginsJsonPath)
    try {
        $Json = Get-Content -LiteralPath $LoginsJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
        return @($Json.logins).Count
    } catch {
        return $null
    }
}

function New-CredentialState {
    param(
        [string]$UserName, [string]$Sid, [string]$Browser,
        [string]$BrowserProfile, [string]$StorePath, $Count
    )
    [PSCustomObject]@{
        UserName       = $UserName
        Sid            = $Sid
        Browser        = $Browser
        BrowserProfile = $BrowserProfile
        StorePath      = $StorePath
        # $null = store present but count could not be read (locked/corrupt).
        CredentialCount = $Count
    }
}

# Chromium browsers keep one "Login Data" file per browser profile under "User Data".
$ChromiumBrowsers = @(
    @{ Browser = "Chrome"; RelPath = "AppData\Local\Google\Chrome\User Data" },
    @{ Browser = "Edge";   RelPath = "AppData\Local\Microsoft\Edge\User Data" }
)

$Profiles = Get-ChildItem -Path $ProfileListPath -ErrorAction SilentlyContinue | Where-Object {
    # Local/domain users (S-1-5-21) and Entra ID users (S-1-12-1); skips SYSTEM and service accounts.
    $_.PSChildName -match "^S-1-(5-21|12-1)-"
}

foreach ($Entry in $Profiles) {
    $Sid = $Entry.PSChildName
    $ProfilePath = $Entry.GetValue("ProfileImagePath")
    if (-not $ProfilePath) { continue }
    $ProfilePath = [Environment]::ExpandEnvironmentVariables($ProfilePath).TrimEnd('\')
    $UserName = Split-Path -Leaf $ProfilePath

    # Chromium: enumerate "Default" and "Profile *" directories that hold a store.
    foreach ($Chromium in $ChromiumBrowsers) {
        $UserData = Join-Path $ProfilePath $Chromium.RelPath
        if (-not (Test-Path -LiteralPath $UserData -PathType Container)) { continue }

        $BrowserProfiles = @(Get-ChildItem -LiteralPath $UserData -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile *" })

        foreach ($BP in $BrowserProfiles) {
            $Store = Join-Path $BP.FullName "Login Data"
            if (-not (Test-Path -LiteralPath $Store -PathType Leaf)) { continue }
            $Count = Get-ChromiumLoginCount -LoginDataPath $Store
            # Skip empty stores so the summary only flags users who actually have logins.
            if ($Count -eq 0) { continue }
            New-CredentialState -UserName $UserName -Sid $Sid -Browser $Chromium.Browser `
                -BrowserProfile $BP.Name -StorePath $Store -Count $Count
        }
    }

    # Firefox: one logins.json per Firefox profile under Profiles\.
    $FirefoxProfiles = Join-Path $ProfilePath "AppData\Roaming\Mozilla\Firefox\Profiles"
    if (Test-Path -LiteralPath $FirefoxProfiles -PathType Container) {
        foreach ($FP in @(Get-ChildItem -LiteralPath $FirefoxProfiles -Directory -ErrorAction SilentlyContinue)) {
            $Store = Join-Path $FP.FullName "logins.json"
            if (-not (Test-Path -LiteralPath $Store -PathType Leaf)) { continue }
            $Count = Get-FirefoxLoginCount -LoginsJsonPath $Store
            if ($Count -eq 0) { continue }
            New-CredentialState -UserName $UserName -Sid $Sid -Browser "Firefox" `
                -BrowserProfile $FP.Name -StorePath $Store -Count $Count
        }
    }
}
