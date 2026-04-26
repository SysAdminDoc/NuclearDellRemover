# Roadmap

PowerShell/WPF OEM bloatware remover for Dell, HP, Lenovo with dry-run, HTML reports, undo manifests, hardware-ID deny list. Roadmap expands OEM coverage, deepens reinstall prevention, and adds a fleet aggregation layer.

## Planned Features

### OEM Coverage Expansion
- ASUS (Armoury Crate, MyASUS, GameFirst VI, Splendid Utility)
- Acer (Predator Sense, Care Center, Quick Access, Bluelight Shield)
- MSI (Center, Dragon Center, Mystic Light, Nahimic)
- Samsung (Galaxy Book Settings, Security Settings, Recovery)
- Razer (Synapse, Cortex, Chroma background agents)
- Microsoft Surface (Surface Diagnostic, Microsoft Pen Health)

### Reinstall Prevention
- AppLocker / WDAC policy generation to permanently block OEM re-install on fleet
- Intune / SCCM compliance policy export that flags reappearance
- Windows Update driver-block policy templated per-model
- Delivery-Optimization filter to prevent OEM content via peer-cache
- Periodic re-audit scheduled task with Discord/webhook drift alert

### Undo & Safety
- Actually-reversible undo (today the manifest is audit-only) — replay the reverse actions
- Per-action consent mode: step through each destructive action with Skip/Apply
- System Restore + full drivers backup (`Export-WindowsDriver`) before live run
- Pre-run snapshot of Start Menu + Taskbar + shortcuts into user-restorable JSON

### Reporting & Fleet
- Central aggregator: POST per-run JSON to a webhook (Discord / Slack / HTTP endpoint)
- Fleet dashboard (static HTML generator): what's installed where, drift per machine
- Exit-code enrichment with detailed failure reason (for RMM alerting nuance)
- Compliance mode: pass/fail against a baseline "no OEM software" policy

### RMM / Packaging
- Intune Win32 app `.intunewin` packaging with detection script
- Chocolatey / Winget package for one-line install
- PowerShell Gallery module publication
- Scheduled "monthly debloat drift audit" template
- Datto / NinjaRMM / ConnectWise-ready components

### UX
- Theme picker (Catppuccin Mocha, Nord, Dracula)
- Per-OEM tab showing installed package inventory before action
- Live progress bar per phase with ETA
- Verbose / diagnostics console pane (currently output-only)

## Competitive Research
- **Win11Debloat / Sophia Script** — consumer bloatware focus, weaker on vendor OEM specifically; clear niche delta.
- **ChrisTitusTech winutil** — broader but shallower on OEM cleanup; we stay focused and deeper.
- **Dell-uninstall-bloatware community scripts** — our version superset; cite and migrate their tips.
- **Lenovo Cleaner / HP BloatCleaner community** — reference for OEM-specific service lists.

## Nice-to-Haves
- Preview mode with tree-view of every targeted artifact before apply
- Report-only continuous monitoring service (no cleanup, just track what OEM installers do)
- Discord bot command (`!nuke-drift hostname`) to remotely trigger dry-run
- Crowd-sourced OEM signature updates (community PRs of new patterns verified via CI)
- Test-harness VM images (clean Dell / HP / Lenovo baselines) for regression testing
- Per-finding CVSS-style severity on reintroduced bloat

## Open-Source Research (Round 2)

### Related OSS Projects
- https://github.com/andrew-s-taylor/public — `De-Bloat/RemoveBloat.ps1`, HP + Dell + Lenovo coverage, uses native uninstall strings, McAfee Mccleanup.exe integration, whitelist-only approach
- https://github.com/arcadesdude/BRU — Bloatware Removal Utility, GUI + CLI, Win7-11, UWP/Metro/Store/provisioned apps, Lenovo App Explorer silent removal, HP/Dell/Lenovo/Sony coverage, PS 2+
- https://github.com/Raphire/Win11Debloat — extensive HP-specific app list (HPAIExperienceCenter, HPConnectedMusic, HPSupportAssistant, HPSureShieldAI, myHP, HPWelcome, etc.), Appx + WinGet uninstall
- https://github.com/Sycnex/Windows10Debloater — GUI debloater, telemetry kill, Cortana disable, scheduled-task cleanup
- https://github.com/LeDragoX/Win-Debloat-Tools — Windows + OEM debloat, telemetry GPOs, winget/choco upgrade tasks
- https://github.com/MSAdministrator/PoshCodeMarkDown (docs/Lenovo-PC-DeBloat.ps1) — Lenovo-specific reference script
- https://github.com/ChrisTitusTech/winutil — large-audience winutil, OEM toggles present, patterns for GUI consent flow

### Features to Borrow
- Use official uninstall strings before reaching for MSI/Appx paths (andrew-s-taylor) — cleaner removal, respects vendor uninstall hooks, avoids orphaned services
- Bundled McAfee Mccleanup.exe removal with documented service-arg matrix (andrew-s-taylor) — McAfee LiveSafe is on nearly every Dell + HP consumer box and evades normal uninstall
- Whitelist-only mode: "remove everything except this list" (andrew-s-taylor) — inverse of current blacklist approach, faster for fresh-install fleets
- BRU-style include/exclude list files, WhatIf/dry-run, silent CLI (BRU) — currently NuclearDellRemover has dry-run, expand to saved include/exclude presets
- Per-OEM app coverage parity with Raphire/Win11Debloat's current HP list (HPAIExperienceCenter, HPPrinterControl, HPSureShieldAI, HPWelcome, HPJumpStarts, HPQuickDrop, HPConnectedMusic) — audit NuclearDellRemover HP coverage against this
- Silent Lenovo App Explorer removal (BRU) — LAE has no clean uninstall path, BRU documents the workaround
- WinGet as fallback uninstaller when Appx/MSI both fail (Raphire/Win11Debloat) — newer OEM apps ship WinGet-only
- OEM auto-detect → preselect only matching manufacturer (already in NuclearDellRemover; audit against BRU's detection matrix for ProBook/EliteBook/ProDesk/Inspiron/Latitude/OptiPlex/Precision)

### Patterns & Architectures Worth Studying
- Two-pass process kill → service stop → uninstall (already used) vs three-pass with respawn catch (NuclearDellRemover currently two-pass; BRU documents three-pass for persistent agents like HP Support Assistant)
- Whatif/ShouldProcess PowerShell native approval instead of custom dry-run flag — standardizes with PS advanced-function conventions
- HTML report with per-item before/after diff + restore script generation (LeDragoX pattern) — NuclearDellRemover has HTML report; add an undo PS1 generator
- Intune/RMM integration: exit codes mapped to detection/remediation semantics (andrew-s-taylor is designed around this) — document NuclearDellRemover exit codes for RMM consumers
- Community-maintained app database in a separate JSON file vs baked into script — easier PR workflow for new OEM apps (Raphire uses YAML-ish data file pattern)
