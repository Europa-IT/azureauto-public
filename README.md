### Running Migration
1. Double-click `run.bat`. DO NOT run as administrator.
2. Grant admin rights when the UAC prompt appears.
3. Review the pre-flight summary and confirm to proceed.
4. Proceed through the ProfWiz dialogues to select a user to migrate and run the migration.

A transcript log (`azureauto-<timestamp>.log`) is written to the project directory automatically.

### Creating Azure Deployment Package Step-by-Step

#### Preparation
1. Run `buildprofwiz.bat` and follow the prompts.
2. The finished deployment package is saved to `build/<ProjectName>-azureauto.zip`.

#### What the build does
- Copies the provisioning package (`.ppkg`) into the deployment directory
- Downloads and installs ForensiT ProfWiz Professional (if not already installed)
- Authenticates to Microsoft Graph interactively to generate `ForensiTAzureID.xml`
- Launches the ProfWiz Deployment Kit UI for project configuration
- Packages everything into a deployable ZIP archive and verifies its contents

### Configuration

**`config/enrollmenturls.txt`** — one MDM enrollment URL per line. Used by the migration to identify and remove the correct enrollment registry keys. Defaults to the Intune MAM endpoint if the file is absent.

**`config/buildconfig.ps1`** — ForensiT installation paths. Edit if ProfWiz is installed to a non-default location.
