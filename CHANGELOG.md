# Changelog

All notable changes to NuclearOEMRemover are documented here.

## [v1.4.2] - 2026-04-22

PS2EXE compatibility release.

### Added
- The script now detects when it is running as a compiled `.exe` (ps2exe) and adapts the "spawn the engine in a child process" flow accordingly. In exe mode the GUI relaunches the exe itself with the engine switches instead of `powershell.exe -File <exe>`, which would fail. In `.ps1` mode behavior is unchanged.
- `$Script:IsExeMode` flag derived from the script path extension with a fallback check on the host process name, and entry-assembly path resolution so `$Script:RepoRoot` still points at the exe's directory (where `icon.ico`/`icon.png` sit for side-by-side loading).

### Changed
- `Get-RunArguments` only emits the `-NoProfile -ExecutionPolicy Bypass -File <path>` wrapper arguments when running as `.ps1`. In exe mode those would be parsed as script parameters and fail.
- `Start-Run` (GUI) picks `ProcessStartInfo.FileName` based on `$Script:IsExeMode`.

## [v1.4.1] - 2026-04-22

Tooling, docs, and test-coverage refinement on top of 1.4.0. No new engine capability; operator ergonomics and maintainability only.

### Added
- `Invoke-Tests.ps1` convenience runner at repo root. `-InstallIfMissing` auto-installs Pester 5 for CurrentUser; returns exit 0 on pass / 1 on fail so it slots into any build pipeline.
- `examples/hardware-id-seeds/` directory with a documented template seed file (`dell-alienware.template.txt`) and a README explaining format, discovery workflow, and safety considerations. Every entry in the template is commented out by default; operators opt in per hardware ID.
- `docs/undo-manifest-schema.md` documenting the JSON undo-manifest format: top-level fields, entry schema, action vocabulary, dry-run behavior, sample consumption snippets, and an explicit "audit-only, not a replay tool" statement.
- `.github/workflows/test.yml` GitHub Actions CI workflow: runs the script parser + the Pester suite on `windows-latest` on every push / PR that touches the engine, tests, or runner. Manual `workflow_dispatch` trigger included.
- Twelve new Pester tests covering `Initialize-RunArtifactPath` (valid path / parent-creation / blank input rejection), `Test-InstallerIsTrusted` status-branch differentiation (missing file, foreign-signer rejection), `Get-TargetOEMs` (all / specific / detect fallback), `Build-MergedConfig` dedup edge cases (cross-OEM duplicates, whitespace filtering), and `$Script:Config` invariants (trusted-signer allowlist presence, SupportAssist gate parseability). Suite is now 44 tests, all passing.

### Changed
- `Test-InstallerIsTrusted` differentiates signature failure modes: `NotSigned`, `HashMismatch` (logged as ERROR - possible tampering), `NotTrusted`, `UnknownError` (crypt32 catalog may be broken, suggests `-SkipSignatureVerification` override), and unknown states. Override suggestions are NOT logged on `HashMismatch` or `NotTrusted` since bypass on those paths would defeat the purpose.
- `Test-InstallerIsTrusted` now explicitly rejects non-existent paths with a clear log message instead of relying on `Get-AuthenticodeSignature` throwing.
- `Get-TargetOEMs` accepts an `-OEMOverride` parameter (defaulted from `$OEM`) so tests can exercise its branches without dynamic-scope gymnastics. Engine call-sites unchanged.

## [v1.4.0] - 2026-04-22

Wide-net feature release. Closes the five follow-ups carried over from the 1.3.1 hardening pass: per-user filesystem cleanup, Authenticode verification, hardware-ID seed lists, and a Pester test harness.

### Added
- Per-user filesystem sweep. Phase 7 now iterates every real user profile (via `ProfileList`) plus the Default template and removes `AppData\Local\Dell`-style directories per OEM. Previously only the current admin's AppData was cleaned; leftovers in other user profiles and the Default template survived.
- Authenticode signature verification on Package Cache installers. Before running any `.exe` from `%ProgramData%\Package Cache`, the file's signature is checked against a list of trusted OEM publishers (`Dell Inc`, `HP Inc`, `Lenovo`, `Alienware`, `Microsoft Corporation`, etc.). Fails closed - unsigned or foreign-signed installers are skipped with a report entry. Overridable via `-SkipSignatureVerification`.
- `HardwareIdSeeds` schema on every OEM definition plus a new `-HardwareIdSeedsFile <path>` parameter that reads additional hardware IDs from a text file (one per line, `#` for comments). Seeds flow into the Phase 8 `DenyDeviceIDs` policy alongside live-detected devices, so hardware IDs for Alienware controllers that happen to be unplugged at cleanup time still get blocked.
- `ProfileRelativePaths` schema on every OEM definition. Declares which per-user directories to sweep; currently ships Dell/HP/Lenovo defaults covering `AppData\Local` and `AppData\Roaming` variants.
- Pester 5 test harness at `tests/NuclearDellRemover.Tests.ps1`. 32 tests cover `Build-MergedConfig` (including the 1.3.1 `KeepOnPreserve` regression), preserve/gate checks, HTML encoding, undo manifest persistence, signature verification, profile enumeration, and seed-file parsing. Runs without administrator rights and without touching the target system.
- Hidden `-LoadOnly` parameter. Dot-source-friendly mode for the test harness: defines every engine helper and `$Script:OEMTargets` / `$Script:Config` in the caller's scope, then returns without admin check or cleanup execution.

### Changed
- `Test-ShouldPreserveApp`, `Test-ShouldSkipSupportAssistByVersion`, `Add-UndoEntry`, `Save-UndoManifest`, and `Test-InstallerIsTrusted` now accept their flag/path inputs as explicit parameters (defaulted from the outer script scope). Engine call-sites need no changes, but tests can exercise every code path without dynamic-scope fragility.
- Unattended elevation relaunch forwards `-SkipSignatureVerification` and `-HardwareIdSeedsFile` on top of the paths added in 1.3.1.
- `$Script:Config` now carries `TrustedInstallerSigners` - an editable allowlist of Authenticode subject substrings that Package Cache signature verification accepts.

## [v1.3.1] - 2026-04-22

Production hardening pass. No new features; corrects regressions, tightens resilience, and improves automation surface.

### Fixed
- `KeepOnPreserve` (powers `-KeepDellCommandUpdate`) was never copied into the merged config. The keep-DCU feature was silently a no-op. Now merged with the rest of the OEM keys.
- `Stop-Service -Force` in Phase 2 was replaced with `sc.exe stop`. The cmdlet renders a blocking progress dialog under silent automation even when stdout is redirected.
- Engine always exited 0 regardless of outcome. Unattended runs now exit with `0` (clean), `2` (completed with remnants), or `3` (exception during phase execution) so Intune/SCCM/RMM can detect failures.
- `$Matches` was overwritten inside the pnputil text-parser fallback, so the driver entry recorded the INF name as its provider. The fragile regex parser is removed entirely; `Get-WindowsDriver` is the sole discovery path (ships with Win10 1809+/Win11) and missing-cmdlet is a warn-and-skip.
- Hardware-ID dedup hashtable used case-sensitive comparison; identical hardware IDs in different casings were inserted twice. Switched to `StringComparer.OrdinalIgnoreCase`.
- `-Unattended` elevated self-relaunch dropped `-LogPath`, `-ReportPath`, and `-UndoManifestPath` when the caller supplied them. All switches and paths are now forwarded with proper quoting; exit code is captured via `-PassThru`.
- `Build-MergedConfig` now uses `ContainsKey` for every OEM key so a partial OEM definition never silently drops data.
- `New-HTMLReport` no longer throws on WMI failure. `Win32_ComputerSystem`/`Win32_OperatingSystem` queries are guarded and fall back to `Unknown` in the report.
- Log writer forces `-Encoding UTF8` (PS 5.1 default is ANSI and mangled OEM names with non-ASCII characters).
- Restore-point throttle relax path now restores the original value in a `finally` block and removes the `SystemRestore` key if the script created it.
- Strict-mode hazard in GUI: any `FindName` miss would throw on `.IsChecked`. Startup now throws immediately on missing controls with a clear message, and every checkbox read goes through a `Get-CheckState` helper that returns a safe default.

### Changed
- Post-uninstall polling default trimmed from 300 s / 30 s to 120 s / 10 s. With a worst case of ten Dell apps this cuts verification wait from up to 50 min to 20 min.
- Package Cache scan is now a single `Get-ChildItem -Recurse` pass with in-memory name filtering instead of N walks per pattern.
- Package Cache silent-arg retry loop honors exit code `1618` (install-in-progress) as terminating; stops retrying against a balky installer.
- Main engine flow (`Invoke-NuclearOEMRemover`) wraps phase execution in `try/finally` so the undo manifest is always persisted even on a mid-run throw. Verification itself is wrapped so a verification exception does not prevent report generation.
- Empty or whitespace-only OEM Start-menu pattern now short-circuits the desktop shortcut sweep instead of matching every `.lnk`.
- Side-panel `Run Options` group is wrapped in a `ScrollViewer` (`MaxHeight=360`) so the eight new run-option controls remain reachable on smaller displays.

## [v1.3.0] - 2026-04-22

Reinstall-Proof + Enterprise release. Targets the universal "bloatware keeps coming back" problem and adds Intune/RMM automation support.

### Reinstall-Proof hardening
- Blocks OEM driver delivery through Windows Update via `ExcludeWUDriversInQualityUpdate`, `DontSearchWindowsUpdate`, and related DriverSearching policies. The documented fix for the Alienware Command Center / Dell Update auto-return loop.
- Enumerates attached OEM devices and populates the Device Installation Restrictions `DenyDeviceIDs` policy with their hardware IDs so WU cannot push drivers that silently reintroduce the user-mode apps.
- Iterates every user profile (plus the `Default` NTUSER.DAT template) when applying CDM and Start menu suggestion blocks, so new users inherit the hardened state instead of just the current admin.
- Adds post-uninstall polling (N-able pattern): after a Win32 uninstaller returns 0, the registry Uninstall key is re-queried every 30 s for up to 5 min before the removal is reported as verified.
- Adds an N-able style version gate for SupportAssist. Installations at or above the gate are preserved unless `-Force` is supplied.
- Adds `-KeepDellCommandUpdate`. DCU is preserved for BIOS/driver management and its lockdown keys (`ShowSetupPopup`, `ConfigApplied`, tray/notification suppression) are applied under `HKLM\SOFTWARE\Dell\UpdateService\Clients\CommandUpdate\Preferences\CFG`.

### New Phase 9: Residue Cleanup
- Removes OEM driver packages with `pnputil /delete-driver <oemNN.inf> /uninstall /force`, filtered by provider (Dell, PC-Doctor, HP, Lenovo, Alienware, WavesAudio). Catches PC-Doctor, Dell Data Vault, and similar leftovers.
- Removes firewall rules whose `DisplayName` or `DisplayGroup` matches OEM vendors.
- Removes Defender `ExclusionPath`, `ExclusionProcess`, and `ExclusionExtension` entries OEM installers add for their own binaries.
- Cancels any pending BITS transfers queued by OEM updaters.

### Enterprise and operator UX
- Public `-Unattended` switch runs the cleanup engine headless (Intune, SCCM, RMM, scheduled tasks) and auto-elevates when possible.
- Public `-Force`, `-KeepDellCommandUpdate`, `-SkipRestorePoint` switches. `-DryRun`, `-OEM`, and `-Unattended` are now all public CLI surface.
- Writes a per-run JSON undo manifest at `%TEMP%\NuclearOEMRemover-Undo-<timestamp>.json` for audit and reversal.
- Creates a `Checkpoint-Computer` System Restore point before live runs (skippable with `-SkipRestorePoint`), temporarily relaxing the 24 h restore-point throttle.
- Runs `winget source update` before winget uninstall attempts so stale sources do not silently miss apps.
- Dynamically walks `%ProgramData%\Package Cache` for Dell, HP, and Lenovo installer stragglers so static GUID lists do not go stale on installer version bumps.
- Sweeps OEM `.lnk` shortcuts from the Public and current-user desktops.
- GUI adds checkboxes for Keep Dell Command Update, Force (bypass version gate), Clear Residue, and Create Restore Point.
- HTML report gains a Residue summary card. Run Summary in the GUI shows all new toggle states.

## [v1.2.0] - 2026-04-22

- Made `NuclearDellRemover.ps1` the complete single-file app, with the GUI and cleanup engine embedded in one script.
- Added a premium native WPF GUI with dry-run-first defaults, OEM targeting, option toggles, live log streaming, phase tracking, stop confirmation, and report/log launch actions.
- Added internal engine support for timestamped report/log paths and GUI-safe output behavior.
- Fixed a GUI crash after dry-run completion by routing process output through a thread-safe queue before updating WPF controls.
- Mapped Alienware manufacturer detection to Dell so Alienware systems no longer default to every supported OEM profile.
- Added broader Dell coverage for MyDell, Dell Pair, Peripheral Manager, Display Manager, Trusted Device, Core Services, Device Management Agent, SupportAssist OS Recovery, and current DellInc AppX packages.
- Added Dell-specific manual uninstall fallbacks for stubborn SupportAssist, Optimizer, Display Manager, Peripheral Manager, and Dell Pair uninstallers.
- Improved winget fallback behavior with noninteractive package agreement handling.
- Redesigned the generated HTML report with stronger hierarchy, responsive cards, semantic tables, dry-run and verification states, safer HTML encoding, and reduced-motion support.
- Refined console run overview and completion copy for clearer live versus dry-run confidence.
- Polished README structure, versioning, product positioning, and GUI-first safety guidance.

## [v1.1.0]

- Added dry-run mode.
- Added HP and Lenovo support.
- Added OEM auto-detection.
- Added generated HTML report.
- Improved summary table output.

## [v1.0.0]

- Initial Dell-focused remover.
