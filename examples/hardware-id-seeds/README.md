# Hardware ID Seed Files

NuclearOEMRemover's Phase 8 populates the Windows `DenyDeviceIDs` Device Installation
Restrictions policy so Windows Update cannot reinstall OEM-helper drivers. By default it
enumerates currently-attached OEM devices via `Get-PnpDevice`. You can extend that list
with hardware IDs supplied in a text file via `-HardwareIdSeedsFile`.

## Why seed files matter

Live enumeration only sees devices that are **plugged in at cleanup time**. The common
failure case - Alienware Command Center reinstalling itself a week after cleanup - happens
because the AlienFX controller was unplugged when you ran the script, so its hardware ID
was never added to the deny list. Seed files let you feed in IDs you collected from a
reference machine or fleet audit.

## File format

Plain text, one hardware ID per line.

- Blank lines are ignored.
- Lines whose first non-whitespace character is `#` are comments.
- Trailing whitespace is trimmed.
- Hardware IDs are matched case-insensitively by Windows.

```text
# This is a comment
USB\VID_187C&PID_0529

# Next section
ROOT\DDVDD
```

## Discovering hardware IDs

Run this on a reference machine **before** cleanup while every relevant device is
connected and powered on:

```powershell
Get-PnpDevice | Where-Object {
    $_.FriendlyName -match 'Dell|Alienware|SupportAssist|PC-Doctor|Lenovo|HP' -or
    $_.Manufacturer -match 'Dell|Alienware|Hewlett|Lenovo'
} | ForEach-Object {
    $hwids = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_HardwareIds).Data
    [PSCustomObject]@{
        FriendlyName = $_.FriendlyName
        Manufacturer = $_.Manufacturer
        HardwareIds  = ($hwids -join '; ')
    }
} | Format-Table -AutoSize -Wrap
```

Copy the specific IDs you want to block into a seed file. Keep the `FriendlyName` as a
comment above each entry so future maintainers understand what a given ID represents.

## Safety warning

**Verify every hardware ID against your hardware before use.** If a seed file contains an
ID that matches a device your machine actually needs (chipset, audio codec, storage
controller), Windows will refuse to install or update that driver and the hardware will
break. The seed files shipped in this directory are examples only.

## Files in this directory

| File | Purpose |
| --- | --- |
| `dell-alienware.template.txt` | Skeleton seed file with commented examples and discovery hints for Dell / Alienware systems. Copy, customize, run. |

## Using a seed file

```powershell
# Dry run first to audit which hardware IDs would be added
.\NuclearDellRemover.ps1 -Unattended -DryRun -HardwareIdSeedsFile .\examples\hardware-id-seeds\dell-alienware.template.txt

# Live cleanup with the seed file in effect
.\NuclearDellRemover.ps1 -Unattended -HardwareIdSeedsFile C:\Fleet\production-seeds.txt
```
