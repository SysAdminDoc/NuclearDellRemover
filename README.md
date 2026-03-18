# NuclearOEMRemover

Scorched-earth removal of **all** OEM pre-installed software from Windows 11. Supports **Dell**, **HP**, and **Lenovo** with automatic manufacturer detection. Eight-phase elimination covering every attack surface OEM bloatware uses to persist.

> Filename kept as `NuclearDellRemover.ps1` for backwards compatibility.

## Phases

1. **Kill Processes** - Terminate all running OEM processes
2. **Services** - Stop, disable, and delete OEM services
3. **AppX Packages** - Remove OEM packages for all users + provisioned
4. **Win32 Apps** - Uninstall via MSI, InstallShield, silent switches, winget fallback
5. **Scheduled Tasks** - Remove OEM tasks and task folders
6. **Registry** - Purge OEM entries from HKLM, HKCU, WOW6432Node
7. **Filesystem** - Clean OEM directory remnants (robocopy empty-folder trick for stubborn dirs)
8. **Block Reinstall** - ContentDeliveryManager and CloudContent policies to prevent return

## Supported OEMs

| OEM | Detected Via | Key Targets |
|-----|-------------|-------------|
| **Dell** | `Dell` in manufacturer | SupportAssist, DDV, Dell Optimizer, Alienware, PC-Doctor |
| **HP** | `HP` / `Hewlett` in manufacturer | HP Support Assistant, Wolf Security, Sure Click, TouchpointAnalytics |
| **Lenovo** | `Lenovo` in manufacturer | Vantage, ImController, System Update, Commercial Vantage |

## Usage

```powershell
# Run as Administrator (auto-detects OEM)
.\NuclearDellRemover.ps1

# Dry run - see what would be removed without making changes
.\NuclearDellRemover.ps1 -DryRun

# Target specific OEM
.\NuclearDellRemover.ps1 -OEM HP
.\NuclearDellRemover.ps1 -OEM Lenovo

# Nuke all three OEMs
.\NuclearDellRemover.ps1 -OEM All

# Dry run targeting all OEMs
.\NuclearDellRemover.ps1 -OEM All -DryRun

# Skip reinstall blocking (if you want OEM apps available in Store)
.\NuclearDellRemover.ps1 -SkipReinstallBlock

# Skip filesystem cleanup
.\NuclearDellRemover.ps1 -SkipFilesystemCleanup

# Verbose output
.\NuclearDellRemover.ps1 -Verbose
```

## Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-DryRun` | Switch | Report-only mode. Goes through all phases but only logs what it **would** do. All dry-run output prefixed with `[DRY RUN]`. |
| `-OEM` | String | Override auto-detected manufacturer. Values: `Dell`, `HP`, `Lenovo`, `All`. |
| `-SkipReinstallBlock` | Switch | Skip phase 8 reinstall prevention policies. |
| `-SkipFilesystemCleanup` | Switch | Skip phase 7 directory removal. |
| `-LogPath` | String | Override default log file location. |

## HTML Report

After execution, an HTML summary report is generated at `%TEMP%\NuclearOEMRemover_Report.html` and opened automatically. Includes:

- System info (manufacturer, model, OS)
- Per-phase summary counts
- Detailed table of every item processed with color-coded status (green = removed, yellow = skipped/dry-run, red = failed)

## Requirements

- Windows 11
- Administrator privileges
- PowerShell 5.1+

## Logging

Logs to `%TEMP%\NuclearOEMRemover.log` by default. Override with `-LogPath`.
