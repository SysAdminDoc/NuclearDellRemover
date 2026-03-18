# CLAUDE.md - NuclearDellRemover (NuclearOEMRemover)

## Overview
Scorched-earth removal of all OEM pre-installed software from Windows 11. Supports Dell, HP, and Lenovo with auto-detection. Eight-phase elimination with verification pass and HTML report. v1.1.0.

## Tech Stack
- PowerShell 5.1, CLI/console (no GUI)

## Key Details
- Single-file script (filename kept as NuclearDellRemover.ps1 for backwards compatibility)
- 8 phases: kill processes, services, AppX, Win32 apps (MSI/InstallShield/winget), scheduled tasks, registry, filesystem, reinstall blocking
- OEM auto-detection via `Win32_ComputerSystem.Manufacturer`
- `$OEMTargets` hashtable maps Dell/HP/Lenovo to their specific process, service, appx, registry, filesystem, and task patterns
- `-DryRun` mode reports all actions without making changes (prefixed with `[DRY RUN]`)
- HTML summary report generated at `%TEMP%\NuclearOEMRemover_Report.html` with color-coded status rows
- Robocopy empty-folder trick for stubborn directories
- ContentDeliveryManager + CloudContent policies to prevent return
- Logs to `%TEMP%\NuclearOEMRemover.log`

## Parameters
- `-DryRun` - Report-only mode, no destructive changes
- `-OEM <Dell|HP|Lenovo|All>` - Override auto-detected manufacturer
- `-SkipReinstallBlock` - Skip phase 8 reinstall prevention policies
- `-SkipFilesystemCleanup` - Skip phase 7 directory removal
- `-LogPath <path>` - Override default log location
- `-Verbose` - Extra verbose output

## Build/Run
```powershell
# Run as Administrator (auto-detects OEM)
.\NuclearDellRemover.ps1

# Dry run - see what would happen
.\NuclearDellRemover.ps1 -DryRun

# Target specific OEM
.\NuclearDellRemover.ps1 -OEM HP
.\NuclearDellRemover.ps1 -OEM Lenovo

# Nuke all three OEMs
.\NuclearDellRemover.ps1 -OEM All

# Combine flags
.\NuclearDellRemover.ps1 -OEM All -DryRun
```

## Version History
- 1.1.0 - DryRun mode, HP/Lenovo support, OEM auto-detection, HTML report, improved summary table
- 1.0.0 - Initial release, Dell-only
