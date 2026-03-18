# CLAUDE.md - NuclearDellRemover

## Overview
Scorched-earth removal of all Dell pre-installed software from Windows 11. Eight-phase elimination with verification pass. v1.0.0.

## Tech Stack
- PowerShell 5.1, CLI/console (no GUI)

## Key Details
- ~835 lines, single-file
- 8 phases: kill processes, services, AppX, Win32 apps (MSI/InstallShield/winget), scheduled tasks, registry, filesystem, reinstall blocking
- Robocopy empty-folder trick for stubborn directories
- ContentDeliveryManager + CloudContent policies to prevent return
- Logs to `%TEMP%\NuclearDellRemover.log`
- Supports `-Verbose`, `-SkipReinstallBlock`, `-SkipFilesystemCleanup`

## Build/Run
```powershell
# Run as Administrator
.\NuclearDellRemover.ps1
.\NuclearDellRemover.ps1 -SkipReinstallBlock
```

## Version
1.0.0
