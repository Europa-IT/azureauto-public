### Running Migration
1. Double-click `run.bat`. DO NOT run as administrator.
2. Grant admin rights when the UAC prompt appears.
3. Review the pre-flight summary and confirm to proceed.
4. Proceed through the ProfWiz dialogues to select a user to migrate and run the migration.

A transcript log (`azureauto-<timestamp>.log`) is written to the project directory automatically.

### Saved Browser Passwords

The pre-flight summary includes a **Saved passwords** row per user, counting saved logins in Chrome, Edge and Firefox (read-only — it counts entries without ever decrypting or reading them). In most same-machine migrations the profile and its credential keys carry across and these passwords survive. The row is a reminder to protect against the cases where they do not.

**Recommended first option: browser sync.** If the user signs into Chrome/Edge/Firefox with an account and has password sync on, their passwords return automatically after signing in on the migrated profile. Nothing touches disk — prefer this.

**Fallback: `subprocesses/Export-BrowserPassword.ps1`.** Walks the user's own browser through its built-in, authenticated export to CSV, then re-imports after migration. The browser performs the decrypt behind its own Windows Hello / password prompt; the script never decrypts the store itself.

> ⚠️ The exported CSV files hold passwords in **clear text**. Always run `-Mode Cleanup` once re-import is verified.

Run it **as the user being migrated, in their own session** (not from the elevated migration window — the export only sees the logged-in user's passwords):

1. Before migrating: `powershell -ExecutionPolicy Bypass -File subprocesses\Export-BrowserPassword.ps1 -Mode Export`
2. Run the migration (`run.bat`).
3. After migrating, signed in as the user: `... -Mode Import`
4. Verify the passwords, then: `... -Mode Cleanup`

CSVs default to `C:\azureauto-pwexport` (outside the profile so they survive migration; access is restricted to the user and Administrators). Override with `-ExportPath`. `-Mode Export` creates this folder **fresh** and refuses to run if it already exists — run `-Mode Cleanup` (or delete the folder) before re-exporting.

### Creating Azure Deployment Package Step-by-Step

#### Preparation
1. Run `buildprofwiz.bat` and follow the prompts.
2. The finished deployment package is saved to `build/<ProjectName>-azureauto.zip`.

#### Building without a provisioning package
The `.ppkg` is optional. Leave its path blank at the first prompt, and leave the provisioning package field empty in the ProfWiz project. Use this when the target PC is already Entra-joined and enrolled, or will be joined some other way.

The build fails if `Profwiz.config` names a different package than the one you gave it (including naming one when you gave none). It also refuses to run if any other `.ppkg` is sitting in `subprocesses/`, since everything there is zipped.

When a package has no `.ppkg`, `Start-Migration.ps1` skips removing installed provisioning packages and MDM enrollment keys, leaving the device's existing join and Intune enrollment in place. The pre-flight summary adds an **Entra join** row that fails (red) unless the device is already Entra-joined to the tenant in `ForensiTAzureID.xml`, i.e. the one you signed into during the build.

#### What the build does
- Copies the provisioning package (`.ppkg`), if given, into the deployment directory
- Downloads and installs ForensiT ProfWiz Professional (if not already installed)
- Authenticates to Microsoft Graph interactively to generate `ForensiTAzureID.xml`
- Launches the ProfWiz Deployment Kit UI for project configuration
- Packages everything into a deployable ZIP archive and verifies its contents

### Configuration

**`config/enrollmenturls.txt`** — one MDM enrollment URL per line. Used by the migration to identify and remove the correct enrollment registry keys. Defaults to the Intune MAM endpoint if the file is absent.

**`config/buildconfig.ps1`** — ForensiT installation paths. Edit if ProfWiz is installed to a non-default location.

**`config/license.ps1`** — ForensiT ProfWiz license ID, used by the build to download the installer. Copy `config/license.example.ps1` to `config/license.ps1` and fill in `$ProfwizLicenseId`. The file is gitignored and left out of the deployment package. If it is missing, the build prompts for the ID when it needs to download ProfWiz.
