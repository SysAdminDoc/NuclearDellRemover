# Undo Manifest Schema

Every live run of NuclearOEMRemover writes a JSON manifest to
`%TEMP%\NuclearOEMRemover-Undo-<timestamp>.json`. It is an **audit log**, not a
replay or rollback tool.

## Why audit-only

Most of the operations NuclearOEMRemover performs are not technically reversible:

- Uninstalling a Win32 app drops binaries, shortcuts, and registry entries. Re-installing
  would require the original installer package.
- `pnputil /delete-driver` removes a driver package from the Driver Store. Reinstalling
  requires the original `.inf` plus its payload.
- Stopping + deleting a service removes SCM registration. Recreating needs the original
  service binary plus its argument list and dependencies.
- Filesystem removals are immediate; robocopy-mirror-from-empty is pseudo-tombstoning.

The manifest captures what **was done**, when, by what version, and against what target,
which is what operators actually need for:

- Incident reconstruction ("what did the script touch on this machine last Tuesday?")
- Compliance evidence ("prove this system had SupportAssist removed before issue")
- Differential testing ("compare manifests across two machines to find drift")
- Post-mortem analysis after a failed live run

## Top-level schema

```jsonc
{
  "Version": "1.4.1",                      // Engine version that produced the manifest
  "StartTime": "2026-04-22T14:33:00.1234567-04:00",
  "CompletedAt": "2026-04-22T14:35:17.9876543-04:00",
  "Computer": "DESKTOP-ABC1234",
  "Entries": [
    { /* entry records - see below */ }
  ]
}
```

## Entry schema

Every entry has these fields:

| Field | Type | Description |
| --- | --- | --- |
| `Timestamp` | ISO 8601 string | When this specific action executed |
| `Phase` | string | One of: `Win32`, `Reinstall Block`, `Filesystem`, `Residue` |
| `Action` | string | Machine-readable verb (see vocabulary below) |
| `Target` | string | What was acted on (app name, registry path, file path, etc.) |
| `Before` | any (nullable) | Pre-change state when known |
| `After` | any (nullable) | Post-change marker or new value |

## Action vocabulary

| Action | Phase | Target example | Before | After |
| --- | --- | --- | --- | --- |
| `Uninstall` | Win32 | `"Dell SupportAssist"` | DisplayVersion | `"removed"` / `"pending-verify"` / `"exit-N"` |
| `PackageCacheUninstall` | Win32 | `"C:\\ProgramData\\Package Cache\\...\\DellOptimizer.exe"` | silent-arg used | `"exit-N"` |
| `SetDword` | Reinstall Block | `"HKLM:\\SOFTWARE\\...\\ExcludeWUDriversInQualityUpdate"` | old DWORD (or null) | new DWORD |
| `DenyHardwareIDs` | Reinstall Block | `"HKLM:\\...\\DenyDeviceIDs"` | null | number added |
| `DCULockdown` | Reinstall Block | `"HKLM:\\SOFTWARE\\Dell\\...\\ShowSetupPopup"` | null | DWORD value |
| `RemovePerUserDir` | Filesystem | `"C:\\Users\\jdoe\\AppData\\Local\\Dell"` | null | null |
| `DeleteShortcut` | Filesystem | `"C:\\Users\\Public\\Desktop\\Dell SupportAssist.lnk"` | null | null |
| `DeleteDriver` | Residue | `"oem47.inf"` | `"Dell Inc"` | null |
| `DeleteFirewallRule` | Residue | `"{guid}"` | rule DisplayName | null |
| `RemoveDefenderExclusion` | Residue | `"ExclusionPath=C:\\Program Files\\Dell"` | null | null |
| `CancelBITS` | Residue | BITS job DisplayName | null | null |

New actions may be added in future versions. Consumers parsing the manifest should
tolerate unknown `Action` values and treat them as "change occurred, specifics logged in
`Target`".

## Dry-run behavior

`Add-UndoEntry` is a no-op when `-DryRun` is set, so dry-run runs produce no manifest. The
HTML report is the authoritative dry-run artifact; it lists intended actions with
`Status = Skipped, Detail = Dry run`.

## Example entry

```jsonc
{
  "Timestamp": "2026-04-22T14:33:42.1029384-04:00",
  "Phase": "Win32",
  "Action": "Uninstall",
  "Target": "Dell SupportAssist",
  "Before": "3.14.2.12",
  "After": "removed"
}
```

## Consuming the manifest

Simple diff across two runs:

```powershell
$a = Get-Content "C:\Before.json" | ConvertFrom-Json
$b = Get-Content "C:\After.json"  | ConvertFrom-Json
Compare-Object $a.Entries $b.Entries -Property Phase,Action,Target
```

Count actions by phase:

```powershell
$m = Get-Content ".\NuclearOEMRemover-Undo-*.json" | ConvertFrom-Json
$m.Entries | Group-Object Phase | Select-Object Name, Count
```

Find all registry writes in the most recent run:

```powershell
$m = Get-Content (Get-ChildItem "$env:TEMP\NuclearOEMRemover-Undo-*.json" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1) | ConvertFrom-Json
$m.Entries | Where-Object Action -eq 'SetDword' |
    Select-Object Timestamp, Target, After
```

## What the manifest does NOT record

- Process kills in Phase 1 / 2.5 (transient state; not useful for audit)
- Service stop/disable/delete in Phase 2 (original startup type not captured)
- AppX package removals in Phase 3 (reinstallable via `Add-AppxPackage` from store)
- Scheduled task deletions in Phase 5
- Registry key tree deletions in Phase 6 (only DWORD writes from Phase 8 are recorded)
- Static `FilesystemPaths` removals in Phase 7 (only per-user sweep and desktop shortcuts)

If you need comprehensive audit of every single action, run with `-NoClearHost` and
pipe the log file `%TEMP%\NuclearOEMRemover-<timestamp>.log` to a SIEM. The log is
UTF-8 and contains every phase's verbose output.
