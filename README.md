# NuclearDellRemover

Scorched-earth removal of **all** Dell pre-installed software from Windows 11. Eight-phase elimination covering every attack surface Dell bloatware uses to persist.

## Phases

1. **Kill Processes** - Terminate all running Dell processes
2. **Services** - Stop, disable, and delete Dell services
3. **AppX Packages** - Remove Dell packages for all users + provisioned
4. **Win32 Apps** - Uninstall via MSI, InstallShield, silent switches, winget fallback
5. **Scheduled Tasks** - Remove Dell tasks and task folders
6. **Registry** - Purge Dell entries from HKLM, HKCU, WOW6432Node
7. **Filesystem** - Clean Dell directory remnants (robocopy empty-folder trick for stubborn dirs)
8. **Block Reinstall** - ContentDeliveryManager and CloudContent policies to prevent return

## Usage

```powershell
# Run as Administrator
.\NuclearDellRemover.ps1

# Skip reinstall blocking (if you want Dell apps available in Store)
.\NuclearDellRemover.ps1 -SkipReinstallBlock

# Skip filesystem cleanup
.\NuclearDellRemover.ps1 -SkipFilesystemCleanup

# Verbose output
.\NuclearDellRemover.ps1 -Verbose
```

## Requirements

- Windows 11
- Administrator privileges
- PowerShell 5.1+

## Logging

Logs to `%TEMP%\NuclearDellRemover.log` by default. Override with `-LogPath`.
