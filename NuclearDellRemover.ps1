<#
.SYNOPSIS
    Premium native GUI for NuclearOEMRemover.
.DESCRIPTION
    Launches an elevated WPF control surface with the full cleanup engine embedded in this script.
    The GUI runs the embedded cleanup engine in a separate process, streams output,
    writes per-run log/report files, and defaults to safe dry-run mode.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    # Public: run the cleanup engine headless (no GUI). For Intune, SCCM, RMM, scheduled tasks.
    [switch]$Unattended,

    # Public: dry-run (report only, no destructive changes). Honored in both GUI and -Unattended modes.
    [switch]$DryRun,

    # Public: preserve Dell Command Update and apply silent-mode lockdown registry keys.
    # Most sysadmins want DCU kept for BIOS/driver management while nuking everything else.
    [switch]$KeepDellCommandUpdate,

    # Public: skip version-gate on SupportAssist (N-able pattern). Default gate = 3.2.0.90.
    [switch]$Force,

    # Public: skip creating a System Restore point before a live run.
    [switch]$SkipRestorePoint,

    # Public: override auto-detected manufacturer.
    [ValidateSet("Dell", "HP", "Lenovo", "All")]
    [string]$OEM,

    # Public: path to a text file of extra hardware IDs to append to the DenyDeviceIDs policy.
    # One hardware ID per line; lines starting with '#' are comments. Useful for fleet-specific blocks
    # (e.g. Alienware controllers not attached at cleanup time).
    [string]$HardwareIdSeedsFile,

    # Public: skip Authenticode signature verification when running installers from Package Cache.
    # Default is to require a valid OEM-signed binary before execution. Only pass this if you've
    # audited the Package Cache manually and trust its contents.
    [switch]$SkipSignatureVerification,

    [Parameter(DontShow = $true)]
    [switch]$InternalEngine,
    [Parameter(DontShow = $true)]
    [switch]$SkipReinstallBlock,
    [Parameter(DontShow = $true)]
    [switch]$SkipFilesystemCleanup,
    [Parameter(DontShow = $true)]
    [switch]$SkipResidueCleanup,
    # Hidden: dot-source friendly mode for Pester tests. Loads every engine function into the
    # caller scope and returns without running the cleanup, without requiring admin.
    [Parameter(DontShow = $true)]
    [switch]$LoadOnly,
    [Parameter(DontShow = $true)]
    [switch]$NoOpenReport,
    [Parameter(DontShow = $true)]
    [switch]$NoClearHost,
    [Parameter(DontShow = $true)]
    [string]$LogPath = "$env:TEMP\NuclearOEMRemover.log",
    [Parameter(DontShow = $true)]
    [string]$ReportPath = "$env:TEMP\NuclearOEMRemover_Report.html",
    [Parameter(DontShow = $true)]
    [string]$UndoManifestPath = "$env:TEMP\NuclearOEMRemover_Undo.json"
)

if ($InternalEngine -or $Unattended -or $LoadOnly) {
function Test-EngineIsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $LoadOnly -and -not (Test-EngineIsAdministrator)) {
    if ($Unattended) {
        # Attempt elevated self-relaunch in headless mode. Forward every passed switch + path so nothing is lost.
        $quote = { param($s) if ($s -match '[\s"]') { '"' + ($s -replace '"','\"') + '"' } else { $s } }
        $relaunchArgs = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", (& $quote $PSCommandPath),
            "-Unattended"
        )
        if ($DryRun)                 { $relaunchArgs += "-DryRun" }
        if ($KeepDellCommandUpdate)  { $relaunchArgs += "-KeepDellCommandUpdate" }
        if ($Force)                  { $relaunchArgs += "-Force" }
        if ($SkipRestorePoint)       { $relaunchArgs += "-SkipRestorePoint" }
        if ($SkipReinstallBlock)         { $relaunchArgs += "-SkipReinstallBlock" }
        if ($SkipFilesystemCleanup)      { $relaunchArgs += "-SkipFilesystemCleanup" }
        if ($SkipResidueCleanup)         { $relaunchArgs += "-SkipResidueCleanup" }
        if ($SkipSignatureVerification)  { $relaunchArgs += "-SkipSignatureVerification" }
        if ($OEM)                        { $relaunchArgs += @("-OEM", $OEM) }
        if ($HardwareIdSeedsFile)        { $relaunchArgs += @("-HardwareIdSeedsFile", (& $quote $HardwareIdSeedsFile)) }
        if ($PSBoundParameters.ContainsKey('LogPath'))          { $relaunchArgs += @("-LogPath",          (& $quote $LogPath)) }
        if ($PSBoundParameters.ContainsKey('ReportPath'))       { $relaunchArgs += @("-ReportPath",       (& $quote $ReportPath)) }
        if ($PSBoundParameters.ContainsKey('UndoManifestPath')) { $relaunchArgs += @("-UndoManifestPath", (& $quote $UndoManifestPath)) }
        try {
            $p = Start-Process -FilePath "powershell.exe" -ArgumentList ($relaunchArgs -join " ") -Verb RunAs -Wait -PassThru
            exit $p.ExitCode
        } catch {
            Write-Error "Unattended mode requires Administrator. Elevation was declined or failed: $($_.Exception.Message)"
            exit 1
        }
    }
    Write-Error "The cleanup engine requires Administrator privileges. Launch .\NuclearDellRemover.ps1 so the GUI can elevate correctly."
    exit 1
}

# ============================================================================
# CONFIGURATION
# ============================================================================

$Script:Config = @{
    Version                  = "1.4.1"
    StartTime                = Get-Date
    SupportAssistMinVersion  = "3.2.0.90"  # N-able gate: skip SA if >= this unless -Force
    # Authenticode publishers we trust when running installers from %ProgramData%\Package Cache.
    # Subject strings are matched case-insensitively. Microsoft is included because some Dell/HP
    # first-party tools ship Microsoft-signed bootstrappers inside their Package Cache drop.
    TrustedInstallerSigners  = @(
        'Dell Inc',
        'Dell Technologies Inc',
        'Dell Computer Corp',
        'Hewlett-Packard',
        'HP Inc',
        'HP Development Company',
        'Lenovo',
        'Alienware',
        'Microsoft Corporation'
    )
}

$Script:UndoManifest = [System.Collections.ArrayList]::new()

# ============================================================================
# OEM TARGET DEFINITIONS
# ============================================================================

$Script:OEMTargets = @{
    Dell = @{
        ProcessPatterns = @("*Dell*", "*SupportAssist*", "*DDV*", "*PCDR*", "*Alienware*", "*MyDell*", "*DellPair*", "*DDPM*", "*DellDisplayManager*", "*DellPeripheral*", "*DellTrustedDevice*", "*DellDeviceManagement*")
        ServicePatterns = @("*Dell*", "*SupportAssist*", "*DDV*", "*PCDR*", "*TechHub*", "*DellClientManagement*", "*Dell Trusted*", "*Dell Device Management*", "*Dell Peripheral*", "*DDPM*")
        ServiceNames    = @(
            "DellSupportAssistAgent", "Dell SupportAssist Remediation",
            "DDVDataCollector", "DDVRulesProcessor", "DDVCollectorSvcApi",
            "DellOptimizerService", "DellPowerManager", "DellUpdate",
            "DellClientManagementService", "DellTechHub", "DellAnalytics",
            "SupportAssistAgent", "DCHS", "DellDigitalDelivery",
            "Dell Core Services", "DellTrustedDevice", "Dell Trusted Device",
            "DellDeviceManagementAgent", "Dell Device Management Agent",
            "Dell Client Device Manager", "Dell Peripheral Core",
            "Dell Display and Peripheral Manager", "DDPMService",
            "DellPair", "Dell Pair"
        )
        AppxPatterns    = @(
            "*Dell*", "*DellInc*", "*DB6EA5DB*", "*WavesAudio.MaxxAudio*",
            "*DellInc.DellOptimizer*", "*DellInc.DellCommandUpdate*",
            "*DellInc.DellPowerManager*", "*DellInc.DellDigitalDelivery*",
            "*DellInc.DellSupportAssistforPCs*", "*DellInc.MyDell*",
            "*DellInc.PartnerPromo*", "*DellInc.DellMobileConnect*"
        )
        Win32Patterns   = @("*Dell*", "*SupportAssist*", "*Alienware*", "*SupportAssist Recovery Assistant*", "*Dell Optimizer Core*", "*DellOptimizerUI*", "*Dell Update*SupportAssist*Plugin*", "*Dell Core Services*", "*Dell Trusted Device*", "*Dell Pair*", "*Dell Peripheral*", "*Dell Display*Manager*", "*Dell Device Management Agent*", "*Dell Client Device Manager*", "*Dell Display and Peripheral Manager*", "*Dell Command*Configure*", "*Dell Command*Endpoint*Configure*", "*Dell Command*Monitor*")
        WingetApps      = @(
            "Dell SupportAssist", "Dell SupportAssist for Business PC",
            "Dell SupportAssist for Business PCs", "Dell SupportAssistAgent",
            "Dell SupportAssist OS Recovery", "SupportAssist Recovery Assistant",
            "Dell SupportAssist OS Recovery Plugin for Dell Update",
            "Dell SupportAssist Remediation", "Dell Update - SupportAssist Update Plugin",
            "Dell Command | Update", "Dell Command | Update for Windows Universal",
            "Dell Command | Update for Windows 10", "Dell Command | Power Manager",
            "Dell Command | Configure", "Dell Command | Endpoint Configure for Microsoft Intune",
            "Dell Command | Monitor",
            "Dell Digital Delivery", "Dell Digital Delivery Service",
            "Dell Digital Delivery Services", "Dell Power Manager",
            "Dell Power Manager Service", "Dell Optimizer", "Dell Optimizer Core",
            "DellOptimizerUI", "Dell Display Manager", "Dell Display Manager 2",
            "Dell Display Manager 2.0", "Dell Display Manager 2.1",
            "Dell Display Manager 2.2", "Dell Display and Peripheral Manager",
            "Dell Peripheral Manager", "Dell Peripheral Core", "Dell Pair",
            "Dell Core Services", "Dell Trusted Device", "Dell Client Device Manager",
            "Dell Device Management Agent", "DellInc.DellOptimizer",
            "DellInc.DellCommandUpdate", "DellInc.DellPowerManager",
            "DellInc.DellDigitalDelivery", "DellInc.DellSupportAssistforPCs",
            "DellInc.MyDell", "DellInc.PartnerPromo", "DellInc.DellMobileConnect",
            "MyDell", "Alienware Command Center"
        )
        TaskPatterns    = @("*Dell*", "*SupportAssist*", "*PCDoctor*", "*PCDR*", "*DDV*", "*MyDell*", "*Alienware*", "*DellUpdate*", "*DellCommandUpdate*", "*DellOptimizer*")
        TaskFolders     = @("Dell")
        RegistryPaths   = @(
            "HKLM:\SOFTWARE\Dell", "HKLM:\SOFTWARE\Wow6432Node\Dell",
            "HKLM:\SOFTWARE\Dell Computer Corporation",
            "HKLM:\SOFTWARE\Wow6432Node\Dell Computer Corporation",
            "HKLM:\SOFTWARE\PC-Doctor", "HKCU:\SOFTWARE\Dell",
            "HKLM:\SOFTWARE\Wow6432Node\PC-Doctor", "HKCU:\SOFTWARE\PC-Doctor",
            "HKLM:\SOFTWARE\SupportAssistAgent",
            "HKLM:\SOFTWARE\Wow6432Node\SupportAssistAgent",
            "HKCU:\SOFTWARE\SupportAssistAgent"
        )
        RunKeyPatterns  = @("*Dell*", "*SupportAssist*", "*PCDR*", "*DDV*", "*MyDell*", "*Alienware*")
        FilesystemPaths = @(
            "$env:ProgramData\Dell", "$env:ProgramData\PCDR",
            "$env:ProgramData\SupportAssist", "$env:ProgramData\PC-Doctor",
            "$env:ProgramData\DDVDataCollector", "$env:LOCALAPPDATA\Dell",
            "$env:LOCALAPPDATA\DellInc", "$env:LOCALAPPDATA\Packages\DellInc.*",
            "$env:LOCALAPPDATA\Packages\DB6EA5DB.*", "$env:APPDATA\Dell",
            "$env:APPDATA\DellInc", "$env:APPDATA\PCDR",
            "C:\Program Files\Dell\SupportAssistAgent",
            "C:\Program Files\Dell\Dell Pair",
            "C:\Program Files\Dell\Dell Peripheral Manager",
            "C:\Program Files\Dell\Dell Display Manager",
            "C:\Program Files\Dell\Dell Display Manager 2",
            "C:\Program Files\Dell\Dell Display Manager 2.0",
            "C:\Program Files\Dell\Dell Display and Peripheral Manager",
            "C:\Program Files\Dell\Dell Optimizer",
            "C:\Program Files\Dell\Dell Trusted Device",
            "C:\Program Files\Dell\Dell Data Vault",
            "C:\Program Files\Dell\CommandUpdate",
            "C:\Program Files\Dell\UpdateService",
            "C:\Program Files\Dell", "C:\Program Files (x86)\Dell",
            "C:\Program Files\PC-Doctor", "C:\Program Files (x86)\PC-Doctor",
            "C:\Dell"
        )
        StartMenuPatterns = @("*Dell*")
        ManualUninstallers = @(
            @{ Name = "Dell SupportAssist Agent"; Path = "C:\Program Files\Dell\SupportAssistAgent\bin\SupportAssistUninstaller.exe"; Arguments = "/S" },
            @{ Name = "Dell SupportAssist Agent"; Path = "C:\Program Files (x86)\Dell\SupportAssistAgent\bin\SupportAssistUninstaller.exe"; Arguments = "/S" },
            @{ Name = "Dell SupportAssist Remediation"; Path = "C:\ProgramData\Package Cache\*\DellSupportAssistRemediationServiceInstaller.exe"; Arguments = "/uninstall /quiet" },
            @{ Name = "Dell SupportAssist OS Recovery Plugin"; Path = "C:\ProgramData\Package Cache\*\DellUpdateSupportAssistPlugin.exe"; Arguments = "/uninstall /quiet" },
            @{ Name = "Dell Optimizer"; Path = "C:\Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}\DellOptimizer.exe"; Arguments = "-remove -runfromtemp -silent" },
            @{ Name = "Dell Optimizer"; Path = "C:\Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}\setup.exe"; Arguments = "-remove -runfromtemp -silent" },
            @{ Name = "Dell Display Manager"; Path = "C:\Program Files\Dell\Dell Display Manager\Uninst.exe"; Arguments = "/S" },
            @{ Name = "Dell Display Manager 2"; Path = "C:\Program Files\Dell\Dell Display Manager 2\Uninst.exe"; Arguments = "/S" },
            @{ Name = "Dell Display Manager 2.0"; Path = "C:\Program Files\Dell\Dell Display Manager 2.0\Uninst.exe"; Arguments = "/S" },
            @{ Name = "Dell Display and Peripheral Manager"; Path = "C:\Program Files\Dell\Dell Display and Peripheral Manager\Uninstall.exe"; Arguments = "/uninst /silent" },
            @{ Name = "Dell Peripheral Manager"; Path = "C:\Program Files\Dell\Dell Peripheral Manager\Uninstall.exe"; Arguments = "/S" },
            @{ Name = "Dell Pair"; Path = "C:\Program Files\Dell\Dell Pair\Uninstall.exe"; Arguments = "/S" }
        )
        # Used when -KeepDellCommandUpdate is set. Apps matching any of these patterns are preserved
        # and DCU itself is silenced via registry so it still updates BIOS/drivers but stops popping up.
        KeepOnPreserve  = @("*Dell Command*Update*", "*DellCommandUpdate*", "*Dell Update for Windows Universal*")
        # Per-user profile directories that get swept across every user profile (not just the current admin).
        # Paths are relative to the profile root (e.g. C:\Users\<name>\<relative>).
        ProfileRelativePaths = @(
            "AppData\Local\Dell",
            "AppData\Local\DellInc",
            "AppData\Local\PCDR",
            "AppData\Roaming\Dell",
            "AppData\Roaming\DellInc",
            "AppData\Roaming\PCDR"
        )
        # Hardware IDs appended to the Device Installation Restrictions DenyDeviceIDs policy. Ships empty
        # because real hardware IDs vary by model; populate via -HardwareIdSeedsFile or extend this list
        # in-repo after running `Get-PnpDevice | ? FriendlyName -match 'Dell|Alienware' | Select InstanceId`.
        HardwareIdSeeds = @()
    }
    HP = @{
        ProcessPatterns = @("*HPSupportAssist*", "*HpTouchpointAnalytics*", "*HPWolfSecurity*", "*HPSureClick*", "*HPAudioSwitch*", "*HPCommRecovery*", "*HpSystemEventUtility*", "*HPPrintScan*")
        ServicePatterns = @("*HP*", "*HpTouchpointAnalytics*", "*HPAppHelperCap*", "*HPDiagsCap*", "*HPNetworkCap*", "*HPSysInfoCap*")
        ServiceNames    = @(
            "HPSupportSolutionsFrameworkService", "HpTouchpointAnalyticsService",
            "HPAppHelperCap", "HPDiagsCap", "HPNetworkCap", "HPSysInfoCap",
            "HPJumpStartBridge", "HPJumpStartLaunchService",
            "HPPrintScanDoctorService", "HPWolfSecurityService",
            "HPSureClickSecureService", "HPCommRecovery"
        )
        AppxPatterns    = @("*AD2F1837*", "*HPPrinterControl*", "*HPQuickDrop*", "*HPSmart*", "*HPDesktopSupportUtilities*", "*HPSystemInformation*", "*HPPrivacySettings*", "*HPPCHardwareDiagnosticsWindows*", "*HPAccessoryCenter*")
        Win32Patterns   = @("*HP *", "*HP Wolf*", "*HP Sure*", "*HP Client*", "*HP Documentation*", "*HP Support*", "*Hewlett*")
        WingetApps      = @(
            "HP Support Assistant", "HP Wolf Security",
            "HP Sure Click", "HP Audio Switch", "HP Documentation",
            "HP Smart", "HP PC Hardware Diagnostics"
        )
        TaskPatterns    = @("*HP *", "*Hewlett*", "*HPSupportAssist*", "*HpTouchpoint*")
        TaskFolders     = @("Hewlett-Packard", "HP")
        RegistryPaths   = @(
            "HKLM:\SOFTWARE\HP", "HKLM:\SOFTWARE\Wow6432Node\HP",
            "HKLM:\SOFTWARE\Hewlett-Packard",
            "HKLM:\SOFTWARE\Wow6432Node\Hewlett-Packard",
            "HKCU:\SOFTWARE\HP", "HKCU:\SOFTWARE\Hewlett-Packard"
        )
        RunKeyPatterns  = @("*HP*", "*Hewlett*")
        FilesystemPaths = @(
            "$env:ProgramData\HP", "$env:ProgramData\Hewlett-Packard",
            "$env:LOCALAPPDATA\HP", "$env:APPDATA\HP",
            "C:\Program Files\HP", "C:\Program Files (x86)\HP",
            "C:\Program Files\Hewlett-Packard", "C:\Program Files (x86)\Hewlett-Packard",
            "C:\swsetup"
        )
        StartMenuPatterns = @("*HP*", "*Hewlett*")
        ProfileRelativePaths = @(
            "AppData\Local\HP",
            "AppData\Local\Hewlett-Packard",
            "AppData\Roaming\HP",
            "AppData\Roaming\Hewlett-Packard"
        )
        HardwareIdSeeds = @()
    }
    Lenovo = @{
        ProcessPatterns = @("*Lenovo*", "*ImController*", "*Vantage*", "*LenovoNow*", "*SystemUpdate*", "*FnKeyDaemon*")
        ServicePatterns = @("*Lenovo*", "*ImController*", "*Vantage*")
        ServiceNames    = @(
            "ImControllerService", "LenovoVantageService",
            "Lenovo.Modern.ImController", "Lenovo System Update Service",
            "LenovoFnAndFunctionKeys", "LenovoPowerManager",
            "LenovoNow", "SUService"
        )
        AppxPatterns    = @("*Lenovo*", "*LenovoCompanion*", "*LenovoSettings*", "*ImController*", "*E046963F.LenovoSettingsforEnterprise*", "*E0469640.LenovoUtility*")
        Win32Patterns   = @("*Lenovo*", "*ImController*", "*System Update*")
        WingetApps      = @(
            "Lenovo Vantage", "Lenovo Commercial Vantage",
            "Lenovo System Update", "Lenovo Now",
            "Lenovo Pen Settings", "Lenovo Hotkeys"
        )
        TaskPatterns    = @("*Lenovo*", "*ImController*", "*TVT*")
        TaskFolders     = @("Lenovo")
        RegistryPaths   = @(
            "HKLM:\SOFTWARE\Lenovo", "HKLM:\SOFTWARE\Wow6432Node\Lenovo",
            "HKCU:\SOFTWARE\Lenovo", "HKLM:\SOFTWARE\WOW6432Node\Lenovo"
        )
        RunKeyPatterns  = @("*Lenovo*")
        FilesystemPaths = @(
            "$env:ProgramData\Lenovo", "$env:LOCALAPPDATA\Lenovo",
            "$env:APPDATA\Lenovo", "C:\Program Files\Lenovo",
            "C:\Program Files (x86)\Lenovo", "C:\ProgramData\Lenovo",
            "C:\swtools"
        )
        StartMenuPatterns = @("*Lenovo*")
        ProfileRelativePaths = @(
            "AppData\Local\Lenovo",
            "AppData\Roaming\Lenovo"
        )
        HardwareIdSeeds = @()
    }
}

# ============================================================================
# OEM AUTO-DETECTION
# ============================================================================

function Get-DetectedOEM {
    try {
        $manufacturer = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Manufacturer
    } catch {
        Write-RunLog "Could not detect manufacturer: $($_.Exception.Message)" -Level WARN
        return "All"
    }

    if ([string]::IsNullOrWhiteSpace($manufacturer)) {
        Write-RunLog "Manufacturer was blank - defaulting to All" -Level WARN
        return "All"
    }

    Write-RunLog "Detected manufacturer: $manufacturer" -Level INFO

    if ($manufacturer -match "Dell|Alienware") { return "Dell" }
    if ($manufacturer -match "HP|Hewlett") { return "HP" }
    if ($manufacturer -match "Lenovo") { return "Lenovo" }

    Write-RunLog "Unknown manufacturer '$manufacturer' - defaulting to All" -Level WARN
    return "All"
}

# Resolve which OEMs to target. Accepts an explicit override so tests can exercise every
# branch without relying on dynamic scope lookup of the $OEM script param.
function Get-TargetOEMs {
    param(
        [AllowNull()][string]$OEMOverride = $OEM
    )

    if ($OEMOverride) {
        $selected = $OEMOverride
    } else {
        $selected = Get-DetectedOEM
    }

    if ($selected -eq "All") {
        return @("Dell", "HP", "Lenovo")
    }
    return @($selected)
}

# Merge patterns from all targeted OEMs into a single config.
# Uses defensive ContainsKey lookups so partial OEM definitions don't silently drop data.
function Build-MergedConfig {
    param([string[]]$TargetOEMs)

    $arrayKeys = @(
        "ProcessPatterns", "ServicePatterns", "ServiceNames", "AppxPatterns",
        "Win32Patterns", "WingetApps", "TaskPatterns", "TaskFolders",
        "RegistryPaths", "RunKeyPatterns", "FilesystemPaths", "StartMenuPatterns",
        "KeepOnPreserve", "ProfileRelativePaths", "HardwareIdSeeds"
    )

    $merged = @{
        ManualUninstallers = @()
    }
    foreach ($k in $arrayKeys) { $merged[$k] = @() }

    foreach ($oem in $TargetOEMs) {
        $def = $Script:OEMTargets[$oem]
        if (-not $def) {
            Write-RunLog "Target OEM profile '$oem' was not found - skipping" -Level WARN
            continue
        }

        foreach ($k in $arrayKeys) {
            if ($def.ContainsKey($k)) { $merged[$k] += $def[$k] }
        }
        if ($def.ContainsKey("ManualUninstallers")) {
            $merged.ManualUninstallers += $def.ManualUninstallers
        }
    }

    foreach ($key in $arrayKeys) {
        $merged[$key] = @($merged[$key] |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -Unique)
    }

    if ($merged.ManualUninstallers.Count -gt 0) {
        $seenManualUninstallers = @{}
        $dedupedManualUninstallers = New-Object System.Collections.ArrayList

        foreach ($manual in $merged.ManualUninstallers) {
            $dedupeKey = "$($manual.Name)|$($manual.Path)|$($manual.Arguments)"
            if (-not $seenManualUninstallers.ContainsKey($dedupeKey)) {
                $seenManualUninstallers[$dedupeKey] = $true
                [void]$dedupedManualUninstallers.Add($manual)
            }
        }

        $merged.ManualUninstallers = @($dedupedManualUninstallers)
    }

    return $merged
}

# ============================================================================
# UNDO MANIFEST
# ============================================================================
# Every live change appends a JSON entry so operators can audit or reverse the run.
# Format: { Timestamp, Phase, Action, Target, Before, After }

function Add-UndoEntry {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Target,
        [object]$Before = $null,
        [object]$After  = $null,
        [AllowNull()][object]$IsDryRun = $DryRun
    )
    if ([bool]$IsDryRun) { return }
    [void]$Script:UndoManifest.Add([PSCustomObject]@{
        Timestamp = (Get-Date).ToString("o")
        Phase     = $Phase
        Action    = $Action
        Target    = $Target
        Before    = $Before
        After     = $After
    })
}

function Save-UndoManifest {
    param(
        [AllowNull()][object]$IsDryRun    = $DryRun,
        [string]$ManifestPath             = $UndoManifestPath
    )
    if ([bool]$IsDryRun) { return }
    if ($Script:UndoManifest.Count -eq 0) { return }
    try {
        $payload = [PSCustomObject]@{
            Version      = $Script:Config.Version
            StartTime    = $Script:Config.StartTime.ToString("o")
            CompletedAt  = (Get-Date).ToString("o")
            Computer     = $env:COMPUTERNAME
            Entries      = $Script:UndoManifest
        }
        $payload | ConvertTo-Json -Depth 6 | Out-File -FilePath $ManifestPath -Encoding utf8 -Force
        Write-RunLog "Undo manifest saved: $ManifestPath ($($Script:UndoManifest.Count) entries)" -Level SUCCESS
    } catch {
        Write-RunLog "Failed to save undo manifest: $($_.Exception.Message)" -Level WARN
    }
}

# ============================================================================
# PER-USER HKCU ITERATION
# ============================================================================
# CDM / reinstall-block settings must be applied to every user profile (including Default
# for new users), not just the current admin. Loads each NTUSER.DAT, invokes a scriptblock,
# then unloads. Mirrors andrew-s-taylor/RemoveBloat.ps1's multi-user SID pattern.

function Invoke-PerUserRegistry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action  # Receives: hiveRoot (e.g. "Registry::HKEY_USERS\S-1-5-21-...")
    )

    $loadedHives = @()
    try {
        # Currently-loaded profiles
        $profileList = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue
        foreach ($entry in $profileList) {
            $sid = Split-Path $entry.Name -Leaf
            if ($sid -notmatch '^S-1-5-21-') { continue }

            $profilePath = $null
            try {
                $profilePath = (Get-ItemProperty -LiteralPath $entry.PSPath -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
            } catch { continue }

            if (-not $profilePath -or -not (Test-Path -LiteralPath $profilePath)) { continue }

            $hiveLoaded = $false
            $hivePath = "Registry::HKEY_USERS\$sid"

            if (-not (Test-Path -LiteralPath $hivePath)) {
                $hiveFile = Join-Path $profilePath 'NTUSER.DAT'
                if (-not (Test-Path -LiteralPath $hiveFile)) { continue }

                reg.exe load "HKU\$sid" "$hiveFile" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $hiveLoaded = $true
                    $loadedHives += $sid
                } else {
                    continue
                }
            }

            try { & $Action $hivePath } catch {
                Write-RunLog "Per-user registry action failed for ${sid}: $($_.Exception.Message)" -Level WARN
            }

            if ($hiveLoaded) {
                [gc]::Collect()
                reg.exe unload "HKU\$sid" 2>&1 | Out-Null
                $loadedHives = $loadedHives | Where-Object { $_ -ne $sid }
            }
        }

        # Default profile (template for new users)
        $defaultHive = Join-Path $env:SystemDrive "Users\Default\NTUSER.DAT"
        if (Test-Path -LiteralPath $defaultHive) {
            $stamp = "NOR_Default_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
            reg.exe load "HKU\$stamp" "$defaultHive" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                try { & $Action "Registry::HKEY_USERS\$stamp" } catch {
                    Write-RunLog "Per-user registry action failed for Default hive: $($_.Exception.Message)" -Level WARN
                }
                [gc]::Collect()
                reg.exe unload "HKU\$stamp" 2>&1 | Out-Null
            }
        }
    } finally {
        # Defensive: unload anything we loaded if we bailed mid-loop
        foreach ($sid in $loadedHives) {
            try {
                [gc]::Collect()
                reg.exe unload "HKU\$sid" 2>&1 | Out-Null
            } catch { }
        }
    }
}

# ============================================================================
# USER PROFILE ENUMERATION
# ============================================================================
# Lists every real user profile (ProfileImagePath) plus the Default template, for per-user
# filesystem cleanup. Only returns profiles with an existing directory.

function Get-AllUserProfilePaths {
    $paths = @()

    $profileList = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -ErrorAction SilentlyContinue
    foreach ($entry in $profileList) {
        $sid = Split-Path $entry.Name -Leaf
        # Skip service accounts (S-1-5-18/-19/-20) and anything that isn't a user SID
        if ($sid -notmatch '^S-1-5-21-') { continue }

        $profileImagePath = $null
        try {
            $profileImagePath = (Get-ItemProperty -LiteralPath $entry.PSPath -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
        } catch { continue }

        if ($profileImagePath -and (Test-Path -LiteralPath $profileImagePath)) {
            $paths += $profileImagePath
        }
    }

    # Default profile template - cleaning this prevents new users from inheriting OEM leftovers
    $defaultProfile = Join-Path $env:SystemDrive "Users\Default"
    if (Test-Path -LiteralPath $defaultProfile) {
        $paths += $defaultProfile
    }

    return $paths | Select-Object -Unique
}

# ============================================================================
# HARDWARE-ID SEED FILE LOADER
# ============================================================================
# Reads additional hardware IDs from a text file. Format: one HWID per line, '#' for comments.
# Blank lines ignored. Returns @() on any failure.

function Get-HardwareIdSeedsFromFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-RunLog "HardwareIdSeedsFile not found: $Path" -Level WARN
        return @()
    }
    try {
        $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
        $seeds = foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
            $trimmed
        }
        Write-RunLog "Loaded $(@($seeds).Count) hardware ID seeds from $Path" -Level INFO
        return @($seeds)
    } catch {
        Write-RunLog "Failed reading hardware ID seeds from ${Path}: $($_.Exception.Message)" -Level WARN
        return @()
    }
}

# ============================================================================
# AUTHENTICODE SIGNATURE VERIFICATION
# ============================================================================
# Checks a file has a valid Authenticode signature from one of our trusted OEM publishers.
# Used before executing installers from %ProgramData%\Package Cache (where an admin-attacker
# could otherwise drop a malicious DellOptimizer.exe). Controlled by -SkipSignatureVerification.

function Test-InstallerIsTrusted {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][object]$SkipVerify = $SkipSignatureVerification
    )
    if ([bool]$SkipVerify) { return $true }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-RunLog "  Rejected $Path - file not found" -Level WARN
        return $false
    }

    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
    } catch {
        Write-RunLog "  Signature check threw for ${Path}: $($_.Exception.Message)" -Level WARN
        Write-RunLog "  Pass -SkipSignatureVerification to bypass after auditing Package Cache manually" -Level INFO
        return $false
    }

    if ($sig.Status -ne 'Valid') {
        # Differentiate failure modes so the log tells the operator whether to worry or to override
        $reason = switch ($sig.Status) {
            'NotSigned'    { 'not signed' }
            'HashMismatch' { 'HASH MISMATCH - possible tampering' }
            'NotTrusted'   { 'signer chain not trusted' }
            'UnknownError' { 'verification unavailable (crypt32 catalog may be broken)' }
            default        { "signature status '$($sig.Status)'" }
        }
        $level = if ($sig.Status -eq 'HashMismatch') { 'ERROR' } else { 'WARN' }
        Write-RunLog "  Rejected $Path - $reason" -Level $level

        # Only suggest override for non-tampering failures; tampering should never be bypassed
        if ($sig.Status -in @('UnknownError', 'NotSigned')) {
            Write-RunLog "  Pass -SkipSignatureVerification if this file has been audited manually" -Level INFO
        }
        return $false
    }

    $subject = [string]$sig.SignerCertificate.Subject
    foreach ($trusted in $Script:Config.TrustedInstallerSigners) {
        if ($subject -match [regex]::Escape($trusted)) { return $true }
    }

    Write-RunLog "  Rejected $Path - signer '$subject' is not a trusted OEM publisher" -Level WARN
    return $false
}

# ============================================================================
# POST-UNINSTALL POLLING (N-able pattern)
# ============================================================================
# Dell installers return exit code 0 while the app is still tearing down in the background
# and `SupportAssistClientUI.exe` keeps respawning. Poll registry for up to 5 min, every 30s.

function Wait-UninstallComplete {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [int]$TimeoutSeconds = 120,
        [int]$IntervalSeconds = 10
    )

    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $stillThere = $false
        foreach ($p in $uninstallPaths) {
            $hit = Get-ItemProperty $p -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq $DisplayName }
            if ($hit) { $stillThere = $true; break }
        }
        if (-not $stillThere) { return $true }
        Start-Sleep -Seconds $IntervalSeconds
    }
    return $false
}

# ============================================================================
# REPORT TRACKING
# ============================================================================

$Script:ReportItems = [System.Collections.ArrayList]::new()

function Add-ReportItem {
    param(
        [string]$Phase,
        [string]$Item,
        [ValidateSet("Removed", "Skipped", "Failed")]
        [string]$Status,
        [string]$Detail = ""
    )
    [void]$Script:ReportItems.Add([PSCustomObject]@{
        Phase  = $Phase
        Item   = $Item
        Status = $Status
        Detail = $Detail
    })
}

function ConvertTo-ReportHtml {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Initialize-RunArtifactPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "The $Label path cannot be blank."
    }

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
}

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

function Write-RunLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "PHASE")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    $color = switch ($Level) {
        "INFO"    { "White" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
        "PHASE"   { "Cyan" }
    }

    if ($Level -eq "PHASE") {
        Write-Host ""
        Write-Host ("=" * 70) -ForegroundColor $color
        Write-Host "  $Message" -ForegroundColor $color
        Write-Host ("=" * 70) -ForegroundColor $color
    } else {
        Write-Host $logEntry -ForegroundColor $color
    }

    # UTF8 log: PS 5.1 default is ANSI which mangles non-ASCII (OEM names can contain em-dashes, etc.)
    Add-Content -Path $LogPath -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Show-Banner {
    Write-Host ""
    Write-Host "  NuclearOEMRemover" -ForegroundColor Red
    Write-Host "  OEM software removal audit and cleanup" -ForegroundColor DarkGray
    Write-Host "  Version $($Script:Config.Version)" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-RunOverview {
    param(
        [string[]]$TargetOEMs,
        [bool]$IsDryRun
    )

    $modeLabel = if ($IsDryRun) { "DRY RUN" } else { "LIVE CLEANUP" }
    $modeColor = if ($IsDryRun) { "Yellow" } else { "Red" }
    $modeHelp = if ($IsDryRun) {
        "No system changes will be made. Review the report before running live."
    } else {
        "System changes will be applied. Restart after completion if Windows keeps removals pending."
    }

    Write-Host "  Mode:        " -NoNewline -ForegroundColor DarkGray
    Write-Host $modeLabel -ForegroundColor $modeColor
    Write-Host "  Target OEMs: " -NoNewline -ForegroundColor DarkGray
    Write-Host ($TargetOEMs -join ", ") -ForegroundColor White
    Write-Host "  Log:         " -NoNewline -ForegroundColor DarkGray
    Write-Host $LogPath -ForegroundColor White
    Write-Host "  $modeHelp" -ForegroundColor DarkGray
    Write-Host ""
}

# ============================================================================
# DRY RUN HELPER
# ============================================================================

function Write-DryRun {
    param([string]$Message)
    Write-RunLog "[DRY RUN] Would: $Message" -Level WARN
}

# ============================================================================
# PHASE 1: KILL OEM PROCESSES
# ============================================================================

function Stop-OEMProcesses {
    param([hashtable]$Targets)

    Write-RunLog -Message "PHASE 1: Terminating OEM Processes" -Level PHASE

    $killed = 0
    $processes = Get-Process -ErrorAction SilentlyContinue

    foreach ($pattern in $Targets.ProcessPatterns) {
        $matchedProcesses = $processes | Where-Object { $_.Name -like $pattern -or $_.ProcessName -like $pattern }
        foreach ($proc in $matchedProcesses) {
            if (-not $DryRun) {
                try {
                    $proc | Stop-Process -Force -ErrorAction Stop
                    Write-RunLog "Terminated process: $($proc.Name) (PID: $($proc.Id))" -Level SUCCESS
                    Add-ReportItem -Phase "Processes" -Item "$($proc.Name) (PID: $($proc.Id))" -Status Removed
                    $killed++
                } catch {
                    Write-RunLog "Failed to terminate: $($proc.Name) - $($_.Exception.Message)" -Level WARN
                    Add-ReportItem -Phase "Processes" -Item $proc.Name -Status Failed -Detail $_.Exception.Message
                }
            } else {
                Write-DryRun "Terminate process: $($proc.Name) (PID: $($proc.Id))"
                Add-ReportItem -Phase "Processes" -Item "$($proc.Name) (PID: $($proc.Id))" -Status Skipped -Detail "Dry run"
                $killed++
            }
        }
    }

    if ($killed -eq 0) {
        Write-RunLog "No OEM processes found running" -Level INFO
    } elseif ($DryRun) {
        Write-RunLog "Dry run found $killed running OEM processes" -Level SUCCESS
    } else {
        Write-RunLog "Terminated $killed OEM processes" -Level SUCCESS
    }

    if (-not $DryRun) {
        Start-Sleep -Seconds 2
    }

    return $killed
}

# ============================================================================
# PHASE 2: STOP AND REMOVE OEM SERVICES
# ============================================================================

function Remove-OEMServices {
    param([hashtable]$Targets)

    Write-RunLog -Message "PHASE 2: Eliminating OEM Services" -Level PHASE

    $removed = 0

    # Get all services matching OEM patterns dynamically
    $oemServices = Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $svc = $_
        $match = $false
        foreach ($pattern in $Targets.ServicePatterns) {
            if ($svc.DisplayName -like $pattern -or $svc.Name -like $pattern) {
                $match = $true
                break
            }
        }
        $match
    }

    # Also check configured service names
    foreach ($svcName in $Targets.ServiceNames) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc -notin $oemServices) {
            $oemServices += $svc
        }
    }

    foreach ($svc in $oemServices) {
        Write-RunLog "Processing service: $($svc.DisplayName) [$($svc.Name)]" -Level INFO

        if (-not $DryRun) {
            # Stop via sc.exe - Stop-Service renders a blocking progress dialog under silent automation
            if ($svc.Status -eq 'Running') {
                sc.exe stop $svc.Name 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1062) {
                    Write-RunLog "  Stopped service" -Level SUCCESS
                } else {
                    Write-RunLog "  Stop returned code $LASTEXITCODE (continuing)" -Level WARN
                }
            }

            # Disable the service
            try {
                Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
                Write-RunLog "  Disabled service" -Level SUCCESS
            } catch {
                Write-RunLog "  Failed to disable: $($_.Exception.Message)" -Level WARN
            }

            # Delete the service
            try {
                sc.exe delete $svc.Name 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-RunLog "  Deleted service" -Level SUCCESS
                    Add-ReportItem -Phase "Services" -Item "$($svc.DisplayName) [$($svc.Name)]" -Status Removed
                    $removed++
                } else {
                    Write-RunLog "  Delete pending (may require reboot)" -Level WARN
                    Add-ReportItem -Phase "Services" -Item "$($svc.DisplayName) [$($svc.Name)]" -Status Failed -Detail "Delete pending reboot"
                }
            } catch {
                Write-RunLog "  Failed to delete: $($_.Exception.Message)" -Level WARN
                Add-ReportItem -Phase "Services" -Item "$($svc.DisplayName) [$($svc.Name)]" -Status Failed -Detail $_.Exception.Message
            }
        } else {
            Write-DryRun "Stop, disable, and delete service: $($svc.DisplayName) [$($svc.Name)]"
            Add-ReportItem -Phase "Services" -Item "$($svc.DisplayName) [$($svc.Name)]" -Status Skipped -Detail "Dry run"
            $removed++
        }
    }

    if ($removed -eq 0 -and $oemServices.Count -eq 0) {
        Write-RunLog "No OEM services found" -Level INFO
    } elseif ($DryRun) {
        Write-RunLog "Dry run found $removed OEM services" -Level SUCCESS
    } else {
        Write-RunLog "Processed $($oemServices.Count) services, removed $removed" -Level SUCCESS
    }

    return $removed
}

# ============================================================================
# PHASE 3: REMOVE OEM APPX PACKAGES
# ============================================================================

function Remove-OEMAppxPackages {
    param([hashtable]$Targets)

    Write-RunLog -Message "PHASE 3: Removing OEM AppX Packages" -Level PHASE

    $removed = 0

    foreach ($pattern in $Targets.AppxPatterns) {
        # Remove installed packages for all users
        $packages = Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue
        foreach ($pkg in $packages) {
            if (-not $DryRun) {
                try {
                    Write-RunLog "Removing AppX: $($pkg.Name)" -Level INFO
                    $pkg | Remove-AppxPackage -AllUsers -ErrorAction Stop
                    Write-RunLog "  Removed for all users" -Level SUCCESS
                    Add-ReportItem -Phase "AppX" -Item $pkg.Name -Status Removed
                    $removed++
                } catch {
                    Write-RunLog "  Failed: $($_.Exception.Message)" -Level WARN
                    try {
                        $pkg | Remove-AppxPackage -ErrorAction Stop
                        Write-RunLog "  Removed for current user only" -Level SUCCESS
                        Add-ReportItem -Phase "AppX" -Item $pkg.Name -Status Removed -Detail "Current user only"
                        $removed++
                    } catch {
                        Write-RunLog "  Complete failure: $($_.Exception.Message)" -Level ERROR
                        Add-ReportItem -Phase "AppX" -Item $pkg.Name -Status Failed -Detail $_.Exception.Message
                    }
                }
            } else {
                Write-DryRun "Remove AppX package: $($pkg.Name)"
                Add-ReportItem -Phase "AppX" -Item $pkg.Name -Status Skipped -Detail "Dry run"
                $removed++
            }
        }

        # Remove provisioned packages
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $pattern }

        foreach ($pkg in $provisioned) {
            if (-not $DryRun) {
                try {
                    Write-RunLog "Removing provisioned: $($pkg.DisplayName)" -Level INFO
                    Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                    Write-RunLog "  Removed provisioned package" -Level SUCCESS
                    Add-ReportItem -Phase "AppX" -Item "$($pkg.DisplayName) (provisioned)" -Status Removed
                    $removed++
                } catch {
                    Write-RunLog "  Failed: $($_.Exception.Message)" -Level WARN
                    Add-ReportItem -Phase "AppX" -Item "$($pkg.DisplayName) (provisioned)" -Status Failed -Detail $_.Exception.Message
                }
            } else {
                Write-DryRun "Remove provisioned package: $($pkg.DisplayName)"
                Add-ReportItem -Phase "AppX" -Item "$($pkg.DisplayName) (provisioned)" -Status Skipped -Detail "Dry run"
                $removed++
            }
        }
    }

    if ($removed -eq 0) {
        Write-RunLog "No OEM AppX packages found" -Level INFO
    } elseif ($DryRun) {
        Write-RunLog "Dry run found $removed matching AppX packages" -Level SUCCESS
    } else {
        Write-RunLog "Removed $removed AppX packages" -Level SUCCESS
    }

    return $removed
}

# ============================================================================
# PHASE 4: UNINSTALL OEM WIN32 APPLICATIONS
# ============================================================================

function Test-ShouldPreserveApp {
    param(
        [Parameter(Mandatory)][object]$App,
        [hashtable]$Targets,
        # Default pulled from the outer script scope so engine call-sites don't have to change.
        # Tests override by passing explicitly, avoiding dynamic-scope fragility.
        [AllowNull()][object]$KeepDCU = $KeepDellCommandUpdate
    )
    if (-not [bool]$KeepDCU) { return $false }
    if (-not $Targets.ContainsKey("KeepOnPreserve")) { return $false }
    foreach ($pattern in $Targets.KeepOnPreserve) {
        if ($App.DisplayName -like $pattern) { return $true }
    }
    return $false
}

function Test-ShouldSkipSupportAssistByVersion {
    param(
        [object]$App,
        [AllowNull()][object]$ForceFlag = $Force
    )
    if ([bool]$ForceFlag) { return $false }
    if ($App.DisplayName -notlike "*SupportAssist*") { return $false }
    if (-not $App.DisplayVersion) { return $false }
    try {
        $installed = [Version]$App.DisplayVersion
        $gate      = [Version]$Script:Config.SupportAssistMinVersion
        return ($installed -ge $gate)
    } catch {
        return $false
    }
}

function Remove-OEMWin32Apps {
    param([hashtable]$Targets)

    Write-RunLog -Message "PHASE 4: Uninstalling OEM Win32 Applications" -Level PHASE

    $removed = 0

    # Refresh winget sources up front so later `winget uninstall` calls don't silently miss apps
    if (-not $DryRun -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        try {
            winget source update 2>&1 | Out-Null
            Write-RunLog "Refreshed winget sources" -Level INFO
        } catch {
            Write-RunLog "winget source update failed: $($_.Exception.Message)" -Level WARN
        }
    }

    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $oemApps = @()

    foreach ($path in $uninstallPaths) {
        $apps = Get-ItemProperty $path -ErrorAction SilentlyContinue | Where-Object {
            $isOEM = $false
            foreach ($pattern in $Targets.Win32Patterns) {
                if ($_.Publisher -like $pattern -or $_.DisplayName -like $pattern) {
                    $isOEM = $true
                    break
                }
            }
            $isOEM
        }
        $oemApps += $apps
    }

    $oemApps = $oemApps | Sort-Object DisplayName -Unique

    foreach ($app in $oemApps) {
        # Preserve Dell Command Update if the operator opted in
        if (Test-ShouldPreserveApp -App $app -Targets $Targets) {
            Write-RunLog "Preserving (KeepDellCommandUpdate): $($app.DisplayName)" -Level INFO
            Add-ReportItem -Phase "Win32" -Item $app.DisplayName -Status Skipped -Detail "Preserved by -KeepDellCommandUpdate"
            continue
        }

        # Version-gate SupportAssist (N-able pattern) unless -Force
        if (Test-ShouldSkipSupportAssistByVersion -App $app) {
            Write-RunLog "Skipping $($app.DisplayName) $($app.DisplayVersion) - version >= gate ($($Script:Config.SupportAssistMinVersion)). Use -Force to override." -Level INFO
            Add-ReportItem -Phase "Win32" -Item "$($app.DisplayName) $($app.DisplayVersion)" -Status Skipped -Detail "Version gate; pass -Force to override"
            continue
        }

        if (-not $app.UninstallString) {
            Write-RunLog "Skipping $($app.DisplayName) - no uninstall string" -Level WARN
            Add-ReportItem -Phase "Win32" -Item $app.DisplayName -Status Skipped -Detail "No uninstall string"
            continue
        }

        if (-not $DryRun) {
            Write-RunLog "Uninstalling: $($app.DisplayName)" -Level INFO

            $uninstallString = $app.UninstallString
            $quietUninstall = $app.QuietUninstallString
            $process = $null

            try {
                if ($quietUninstall) {
                    Write-RunLog "  Using quiet uninstall" -Level INFO
                    $process = Start-Process cmd.exe -ArgumentList "/c `"$quietUninstall`"" -Wait -PassThru -WindowStyle Hidden
                }
                elseif ($uninstallString -match "msiexec") {
                    $guid = [regex]::Match($uninstallString, '\{[A-F0-9-]+\}', 'IgnoreCase').Value
                    if ($guid) {
                        Write-RunLog "  MSI uninstall: $guid" -Level INFO
                        $process = Start-Process msiexec.exe -ArgumentList "/x $guid /qn /norestart REBOOT=ReallySuppress" -Wait -PassThru -WindowStyle Hidden
                    }
                }
                elseif ($uninstallString -match "InstallShield") {
                    Write-RunLog "  InstallShield uninstall" -Level INFO
                    $process = Start-Process cmd.exe -ArgumentList "/c `"$uninstallString`" -remove -runfromtemp -silent" -Wait -PassThru -WindowStyle Hidden
                }
                else {
                    Write-RunLog "  Generic uninstall with silent switches" -Level INFO
                    $silentArgs = @("/S", "/silent", "/quiet", "-silent", "-quiet", "/qn", "-s")

                    foreach ($arg in $silentArgs) {
                        $process = Start-Process cmd.exe -ArgumentList "/c `"$uninstallString $arg`"" -Wait -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
                        if ($process.ExitCode -eq 0) { break }
                    }
                }

                if ($process -and $process.ExitCode -eq 0) {
                    Write-RunLog "  Successfully uninstalled (verifying removal)" -Level SUCCESS
                    $verified = Wait-UninstallComplete -DisplayName $app.DisplayName -TimeoutSeconds 120 -IntervalSeconds 10
                    if ($verified) {
                        Write-RunLog "  Removal verified in registry" -Level SUCCESS
                        Add-ReportItem -Phase "Win32" -Item $app.DisplayName -Status Removed
                        Add-UndoEntry -Phase "Win32" -Action "Uninstall" -Target $app.DisplayName -Before $app.DisplayVersion -After "removed"
                    } else {
                        Write-RunLog "  Exit 0 but registry entry still present after 2min - may need reboot" -Level WARN
                        Add-ReportItem -Phase "Win32" -Item $app.DisplayName -Status Removed -Detail "Uninstall returned 0 but registry entry persists; reboot may be needed"
                        Add-UndoEntry -Phase "Win32" -Action "Uninstall" -Target $app.DisplayName -Before $app.DisplayVersion -After "pending-verify"
                    }
                    $removed++
                } elseif ($process) {
                    Write-RunLog "  Exit code: $($process.ExitCode)" -Level WARN
                    Add-ReportItem -Phase "Win32" -Item $app.DisplayName -Status Removed -Detail "Exit code $($process.ExitCode)"
                    Add-UndoEntry -Phase "Win32" -Action "Uninstall" -Target $app.DisplayName -Before $app.DisplayVersion -After "exit-$($process.ExitCode)"
                    $removed++
                }
            } catch {
                Write-RunLog "  Failed: $($_.Exception.Message)" -Level ERROR
                Add-ReportItem -Phase "Win32" -Item $app.DisplayName -Status Failed -Detail $_.Exception.Message
            }
        } else {
            Write-DryRun "Uninstall Win32 app: $($app.DisplayName)"
            Add-ReportItem -Phase "Win32" -Item $app.DisplayName -Status Skipped -Detail "Dry run"
            $removed++
        }
    }

    # Also try winget for stragglers
    Write-RunLog "Checking winget for remaining OEM apps..." -Level INFO
    $wingetCommand = Get-Command winget -ErrorAction SilentlyContinue
    if ($wingetCommand -or $DryRun) {
        foreach ($appName in $Targets.WingetApps) {
            if (-not $DryRun) {
                try {
                    winget uninstall "$appName" --silent --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-RunLog "  Winget removed: $appName" -Level SUCCESS
                        Add-ReportItem -Phase "Win32" -Item "$appName (winget)" -Status Removed
                        $removed++
                    }
                } catch {
                    Write-Verbose "winget uninstall did not remove ${appName}: $($_.Exception.Message)"
                }
            } else {
                Write-DryRun "Winget uninstall: $appName"
                Add-ReportItem -Phase "Win32" -Item "$appName (winget)" -Status Skipped -Detail "Dry run"
            }
        }
    } else {
        Write-RunLog "winget not found - skipping winget fallback" -Level WARN
    }

    # Dell and other OEM tools often ship EXE uninstallers that are not exposed cleanly in ARP.
    if ($Targets.ContainsKey("ManualUninstallers") -and $Targets.ManualUninstallers.Count -gt 0) {
        Write-RunLog "Running OEM-specific manual uninstall fallbacks..." -Level INFO
        $successCodes = @(0, 3010, 1641)
        $alreadyAbsentCodes = @(1605, 1614)

        foreach ($manual in $Targets.ManualUninstallers) {
            $manualTargets = @(Get-Item -Path $manual.Path -ErrorAction SilentlyContinue)
            if ($manualTargets.Count -eq 0) { continue }

            foreach ($manualTarget in $manualTargets) {
                $itemName = "$($manual.Name): $($manualTarget.FullName)"

                if (-not $DryRun) {
                    try {
                        Write-RunLog "  Manual uninstall: $itemName" -Level INFO
                        $process = Start-Process -FilePath $manualTarget.FullName -ArgumentList $manual.Arguments -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                        $exitCode = $process.ExitCode

                        if ($null -eq $exitCode -or $successCodes -contains [int]$exitCode) {
                            $detail = if ($exitCode -in @(3010, 1641)) { "Reboot required" } else { "" }
                            Write-RunLog "  Manual uninstall completed: $($manual.Name)" -Level SUCCESS
                            Add-ReportItem -Phase "Win32" -Item "$($itemName) (manual)" -Status Removed -Detail $detail
                            $removed++
                        } elseif ($alreadyAbsentCodes -contains [int]$exitCode) {
                            Write-RunLog "  Already absent: $($manual.Name)" -Level INFO
                            Add-ReportItem -Phase "Win32" -Item "$($itemName) (manual)" -Status Skipped -Detail "Already absent"
                        } else {
                            Write-RunLog "  Manual uninstall exit code $exitCode for $($manual.Name)" -Level WARN
                            Add-ReportItem -Phase "Win32" -Item "$($itemName) (manual)" -Status Failed -Detail "Exit code $exitCode"
                        }
                    } catch {
                        Write-RunLog "  Manual uninstall failed: $($_.Exception.Message)" -Level WARN
                        Add-ReportItem -Phase "Win32" -Item "$($itemName) (manual)" -Status Failed -Detail $_.Exception.Message
                    }
                } else {
                    Write-DryRun "Manual uninstall: $itemName $($manual.Arguments)"
                    Add-ReportItem -Phase "Win32" -Item "$($itemName) (manual)" -Status Skipped -Detail "Dry run"
                    $removed++
                }
            }
        }
    }

    # Dynamic Package Cache walk - picks up newer installer versions that static ManualUninstallers miss.
    # Single-pass scan; name matching done in-memory to avoid N cache walks.
    $packageCacheRoot = Join-Path $env:ProgramData "Package Cache"
    if (Test-Path -LiteralPath $packageCacheRoot) {
        Write-RunLog "Scanning $packageCacheRoot for stragglers..." -Level INFO
        $cacheNameRegex = '^(Dell(SupportAssist|Update|Optimizer|Pair|PeripheralManager|DisplayManager|TrustedDevice|CommandUpdate|PowerManager|ClientManagement|DigitalDelivery)|.*SupportAssistRemediation|.*DellUpdateSupportAssistPlugin|HPSupportAssistant|HPWolf|LenovoVantage|LenovoSystemUpdate)'
        $keepRegex      = 'DellCommandUpdate|DellUpdateForWindowsUniversal'
        $cacheSilentArgs = @("/uninstall /quiet /norestart", "-remove -silent", "/S", "/silent", "/uninstall /silent")

        # Success (removed), already-absent, and install-in-progress (1618) all terminate the retry loop.
        $terminatingExitCodes = @(0, 3010, 1605, 1614, 1618, 1641)

        $allExes = Get-ChildItem -Path $packageCacheRoot -Recurse -File -Filter "*.exe" -ErrorAction SilentlyContinue
        $cacheHits = $allExes | Where-Object { $_.Name -match $cacheNameRegex }

        foreach ($installer in $cacheHits) {
            if ($KeepDellCommandUpdate -and $installer.Name -match $keepRegex) {
                Write-RunLog "  Skipping (KeepDellCommandUpdate): $($installer.Name)" -Level INFO
                continue
            }
            if ($DryRun) {
                Write-DryRun "Package Cache uninstall: $($installer.FullName)"
                Add-ReportItem -Phase "Win32" -Item "$($installer.Name) (package cache)" -Status Skipped -Detail "Dry run"
                $removed++
                continue
            }

            # Authenticode gate: never run an installer from Package Cache unless it's validly signed
            # by a trusted OEM publisher. Mitigates a write-access-to-PackageCache attacker scenario.
            if (-not (Test-InstallerIsTrusted -Path $installer.FullName)) {
                Add-ReportItem -Phase "Win32" -Item "$($installer.Name) (package cache)" -Status Skipped -Detail "Signature not trusted (use -SkipSignatureVerification to override)"
                continue
            }

            $handled = $false
            foreach ($sa in $cacheSilentArgs) {
                try {
                    Write-RunLog "  Package Cache uninstall: $($installer.Name) $sa" -Level INFO
                    $p = Start-Process -FilePath $installer.FullName -ArgumentList $sa -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                    $code = $p.ExitCode
                    if ($null -eq $code -or $terminatingExitCodes -contains [int]$code) {
                        Add-ReportItem -Phase "Win32" -Item "$($installer.Name) (package cache)" -Status Removed -Detail "Exit $code"
                        Add-UndoEntry -Phase "Win32" -Action "PackageCacheUninstall" -Target $installer.FullName -Before "$sa" -After "exit-$code"
                        $removed++
                        $handled = $true
                        break
                    }
                } catch {
                    Write-Verbose "Package cache uninstall attempt failed: $($_.Exception.Message)"
                    continue
                }
            }
            if (-not $handled) {
                Add-ReportItem -Phase "Win32" -Item "$($installer.Name) (package cache)" -Status Failed -Detail "All silent-arg variants returned non-terminating exit codes"
            }
        }
    }

    if ($removed -eq 0 -and $oemApps.Count -eq 0) {
        Write-RunLog "No OEM Win32 applications found" -Level INFO
    } elseif ($DryRun) {
        Write-RunLog "Dry run queued $removed Win32 cleanup checks" -Level SUCCESS
    } else {
        Write-RunLog "Uninstalled $removed Win32 applications" -Level SUCCESS
    }

    return $removed
}

# ============================================================================
# PHASE 5: REMOVE OEM SCHEDULED TASKS
# ============================================================================

function Remove-OEMScheduledTasks {
    param([hashtable]$Targets)

    Write-RunLog -Message "PHASE 5: Removing OEM Scheduled Tasks" -Level PHASE

    $removed = 0

    $oemTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $task = $_
        $match = $false
        foreach ($pattern in $Targets.TaskPatterns) {
            if ($task.TaskName -like $pattern -or $task.TaskPath -like $pattern) {
                $match = $true
                break
            }
        }
        $match
    }

    foreach ($task in $oemTasks) {
        if (-not $DryRun) {
            try {
                Write-RunLog "Removing task: $($task.TaskPath)$($task.TaskName)" -Level INFO
                $task | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
                $task | Unregister-ScheduledTask -Confirm:$false -ErrorAction Stop
                Write-RunLog "  Removed" -Level SUCCESS
                Add-ReportItem -Phase "Tasks" -Item "$($task.TaskPath)$($task.TaskName)" -Status Removed
                $removed++
            } catch {
                Write-RunLog "  Failed: $($_.Exception.Message)" -Level WARN
                Add-ReportItem -Phase "Tasks" -Item "$($task.TaskPath)$($task.TaskName)" -Status Failed -Detail $_.Exception.Message
            }
        } else {
            Write-DryRun "Remove scheduled task: $($task.TaskPath)$($task.TaskName)"
            Add-ReportItem -Phase "Tasks" -Item "$($task.TaskPath)$($task.TaskName)" -Status Skipped -Detail "Dry run"
            $removed++
        }
    }

    # Remove OEM task folders
    foreach ($folder in $Targets.TaskFolders) {
        if (-not $DryRun) {
            try {
                $taskService = New-Object -ComObject Schedule.Service
                $taskService.Connect()
                $rootFolder = $taskService.GetFolder("\")
                $rootFolder.DeleteFolder($folder, 0)
                Write-RunLog "Removed '$folder' scheduled task folder" -Level SUCCESS
                Add-ReportItem -Phase "Tasks" -Item "Task folder: \$folder" -Status Removed
                $removed++
            } catch {
                Write-Verbose "Scheduled task folder '$folder' was not removed: $($_.Exception.Message)"
            }
        } else {
            Write-DryRun "Remove task folder: \$folder"
            Add-ReportItem -Phase "Tasks" -Item "Task folder: \$folder" -Status Skipped -Detail "Dry run"
            $removed++
        }
    }

    if ($removed -eq 0) {
        Write-RunLog "No OEM scheduled tasks found" -Level INFO
    } elseif ($DryRun) {
        Write-RunLog "Dry run found $removed scheduled task items" -Level SUCCESS
    } else {
        Write-RunLog "Removed $removed scheduled task items" -Level SUCCESS
    }

    return $removed
}

# ============================================================================
# PHASE 6: REGISTRY CLEANUP
# ============================================================================

function Remove-OEMRegistry {
    param([hashtable]$Targets)

    Write-RunLog -Message "PHASE 6: Purging OEM Registry Entries" -Level PHASE

    $removed = 0

    foreach ($path in $Targets.RegistryPaths) {
        if (Test-Path $path) {
            if (-not $DryRun) {
                try {
                    Write-RunLog "Removing registry: $path" -Level INFO
                    Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                    Write-RunLog "  Removed" -Level SUCCESS
                    Add-ReportItem -Phase "Registry" -Item $path -Status Removed
                    $removed++
                } catch {
                    Write-RunLog "  Failed: $($_.Exception.Message)" -Level WARN
                    Add-ReportItem -Phase "Registry" -Item $path -Status Failed -Detail $_.Exception.Message
                }
            } else {
                Write-DryRun "Remove registry key: $path"
                Add-ReportItem -Phase "Registry" -Item $path -Status Skipped -Detail "Dry run"
                $removed++
            }
        }
    }

    # Clean up Run keys
    $runKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    )

    foreach ($key in $runKeys) {
        if (Test-Path $key) {
            $props = Get-ItemProperty $key -ErrorAction SilentlyContinue
            foreach ($runPattern in $Targets.RunKeyPatterns) {
                $props.PSObject.Properties | Where-Object {
                    $_.Name -notmatch "^PS" -and $_.Value -like $runPattern
                } | ForEach-Object {
                    if (-not $DryRun) {
                        try {
                            Remove-ItemProperty -Path $key -Name $_.Name -Force -ErrorAction Stop
                            Write-RunLog "Removed Run entry: $($_.Name)" -Level SUCCESS
                            Add-ReportItem -Phase "Registry" -Item "Run: $($_.Name)" -Status Removed
                            $removed++
                        } catch {
                            Write-RunLog "Failed to remove Run entry: $($_.Name)" -Level WARN
                            Add-ReportItem -Phase "Registry" -Item "Run: $($_.Name)" -Status Failed -Detail $_.Exception.Message
                        }
                    } else {
                        Write-DryRun "Remove Run entry: $($_.Name) from $key"
                        Add-ReportItem -Phase "Registry" -Item "Run: $($_.Name)" -Status Skipped -Detail "Dry run"
                        $removed++
                    }
                }
            }
        }
    }

    if ($removed -eq 0) {
        Write-RunLog "No OEM registry entries found" -Level INFO
    } elseif ($DryRun) {
        Write-RunLog "Dry run found $removed registry items" -Level SUCCESS
    } else {
        Write-RunLog "Removed $removed registry items" -Level SUCCESS
    }

    return $removed
}

# ============================================================================
# PHASE 7: FILESYSTEM CLEANUP
# ============================================================================

function Remove-OEMFilesystem {
    param([hashtable]$Targets)

    Write-RunLog -Message "PHASE 7: Cleaning OEM Filesystem Remnants" -Level PHASE

    if ($SkipFilesystemCleanup) {
        Write-RunLog "Filesystem cleanup skipped by parameter" -Level WARN
        return 0
    }

    $removed = 0

    foreach ($path in $Targets.FilesystemPaths) {
        if (Test-Path $path) {
            if (-not $DryRun) {
                try {
                    Write-RunLog "Removing: $path" -Level INFO

                    $acl = Get-Acl $path -ErrorAction SilentlyContinue
                    if ($acl) {
                        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
                        if ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
                            Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue |
                                Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
                        }
                    }

                    Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                    Write-RunLog "  Removed" -Level SUCCESS
                    Add-ReportItem -Phase "Filesystem" -Item $path -Status Removed
                    $removed++
                } catch {
                    try {
                        $emptyDir = "$env:TEMP\EmptyDir_$(Get-Random)"
                        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
                        robocopy $emptyDir $path /MIR /R:1 /W:1 2>&1 | Out-Null
                        Remove-Item $path -Force -Recurse -ErrorAction SilentlyContinue
                        Remove-Item $emptyDir -Force -ErrorAction SilentlyContinue
                        Write-RunLog "  Removed (robocopy method)" -Level SUCCESS
                        Add-ReportItem -Phase "Filesystem" -Item "$path (robocopy)" -Status Removed
                        $removed++
                    } catch {
                        Write-RunLog "  Failed: $($_.Exception.Message)" -Level WARN
                        Add-ReportItem -Phase "Filesystem" -Item $path -Status Failed -Detail $_.Exception.Message
                    }
                }
            } else {
                Write-DryRun "Remove directory: $path"
                Add-ReportItem -Phase "Filesystem" -Item $path -Status Skipped -Detail "Dry run"
                $removed++
            }
        }
    }

    # Iterate every user profile for OEM AppData leftovers. Matches Phase 8's per-user HKCU pattern
    # so new users (via Default) and other existing users get cleaned, not just the current admin.
    $profileRelatives = @($Targets.ProfileRelativePaths)
    if ($profileRelatives.Count -gt 0) {
        $userProfiles = Get-AllUserProfilePaths
        foreach ($userHome in $userProfiles) {
            foreach ($rel in $profileRelatives) {
                if ([string]::IsNullOrWhiteSpace($rel)) { continue }
                $target = Join-Path $userHome $rel
                if (-not (Test-Path -LiteralPath $target)) { continue }

                if ($DryRun) {
                    Write-DryRun "Remove per-user directory: $target"
                    Add-ReportItem -Phase "Filesystem" -Item "Per-user: $target" -Status Skipped -Detail "Dry run"
                    $removed++
                    continue
                }
                try {
                    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
                    Write-RunLog "Removed per-user directory: $target" -Level SUCCESS
                    Add-ReportItem -Phase "Filesystem" -Item "Per-user: $target" -Status Removed
                    Add-UndoEntry -Phase "Filesystem" -Action "RemovePerUserDir" -Target $target
                    $removed++
                } catch {
                    # Robocopy mirror-from-empty fallback for stubborn directories (ACL/junctions)
                    try {
                        $emptyDir = "$env:TEMP\EmptyDir_$(Get-Random)"
                        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
                        robocopy $emptyDir $target /MIR /R:1 /W:1 2>&1 | Out-Null
                        Remove-Item -LiteralPath $target -Force -Recurse -ErrorAction SilentlyContinue
                        Remove-Item -LiteralPath $emptyDir -Force -ErrorAction SilentlyContinue
                        Add-ReportItem -Phase "Filesystem" -Item "Per-user: $target (robocopy)" -Status Removed
                        Add-UndoEntry -Phase "Filesystem" -Action "RemovePerUserDir" -Target $target
                        $removed++
                    } catch {
                        Add-ReportItem -Phase "Filesystem" -Item "Per-user: $target" -Status Failed -Detail $_.Exception.Message
                    }
                }
            }
        }
    }

    # Sweep Public/current-user desktop OEM shortcuts (left behind by many uninstallers)
    $desktopRoots = @(
        (Join-Path $env:PUBLIC "Desktop"),
        ([Environment]::GetFolderPath("Desktop"))
    )
    foreach ($smPattern in $Targets.StartMenuPatterns) {
        # Guard against an accidentally-empty pattern which would match every .lnk on the desktop
        if ([string]::IsNullOrWhiteSpace($smPattern)) { continue }
        foreach ($desktop in $desktopRoots) {
            if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) { continue }
            $shortcutGlob = Join-Path $desktop "$smPattern.lnk"
            Get-Item -Path $shortcutGlob -ErrorAction SilentlyContinue | ForEach-Object {
                if (-not $DryRun) {
                    try {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                        Write-RunLog "Removed desktop shortcut: $($_.Name)" -Level SUCCESS
                        Add-ReportItem -Phase "Filesystem" -Item "Desktop: $($_.Name)" -Status Removed
                        Add-UndoEntry -Phase "Filesystem" -Action "DeleteShortcut" -Target $_.FullName
                        $removed++
                    } catch {
                        Add-ReportItem -Phase "Filesystem" -Item "Desktop: $($_.Name)" -Status Failed -Detail $_.Exception.Message
                    }
                } else {
                    Write-DryRun "Remove desktop shortcut: $($_.FullName)"
                    Add-ReportItem -Phase "Filesystem" -Item "Desktop: $($_.Name)" -Status Skipped -Detail "Dry run"
                    $removed++
                }
            }
        }
    }

    # Clean OEM items from Start Menu
    foreach ($smPattern in $Targets.StartMenuPatterns) {
        $startMenuPaths = @(
            "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\$smPattern",
            "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\$smPattern"
        )

        foreach ($pattern in $startMenuPaths) {
            Get-Item $pattern -ErrorAction SilentlyContinue | ForEach-Object {
                if (-not $DryRun) {
                    try {
                        Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
                        Write-RunLog "Removed Start Menu: $($_.Name)" -Level SUCCESS
                        Add-ReportItem -Phase "Filesystem" -Item "Start Menu: $($_.Name)" -Status Removed
                        $removed++
                    } catch {
                        Write-RunLog "Failed to remove Start Menu item: $($_.Name)" -Level WARN
                        Add-ReportItem -Phase "Filesystem" -Item "Start Menu: $($_.Name)" -Status Failed -Detail $_.Exception.Message
                    }
                } else {
                    Write-DryRun "Remove Start Menu item: $($_.Name)"
                    Add-ReportItem -Phase "Filesystem" -Item "Start Menu: $($_.Name)" -Status Skipped -Detail "Dry run"
                    $removed++
                }
            }
        }
    }

    if ($removed -eq 0) {
        Write-RunLog "No OEM filesystem items found" -Level INFO
    } elseif ($DryRun) {
        Write-RunLog "Dry run found $removed filesystem items" -Level SUCCESS
    } else {
        Write-RunLog "Removed $removed filesystem items" -Level SUCCESS
    }

    return $removed
}

# ============================================================================
# PHASE 8: BLOCK REINSTALLATION
# ============================================================================

function Initialize-RegistryKey {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
}

function Block-OEMReinstallation {
    Write-RunLog -Message "PHASE 8: Blocking Automatic Reinstallation" -Level PHASE

    if ($SkipReinstallBlock) {
        Write-RunLog "Reinstallation blocking skipped by parameter" -Level WARN
        return 0
    }

    $blocked = 0

    # Disable Windows Consumer Features
    if (-not $DryRun) {
        try {
            $cloudContentPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
            Initialize-RegistryKey -Path $cloudContentPath
            Set-ItemProperty -Path $cloudContentPath -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWord -Force
            Write-RunLog "Disabled Windows Consumer Features" -Level SUCCESS
            Add-ReportItem -Phase "Reinstall Block" -Item "DisableWindowsConsumerFeatures" -Status Removed
            $blocked++
        } catch {
            Write-RunLog "Failed to disable Consumer Features: $($_.Exception.Message)" -Level WARN
            Add-ReportItem -Phase "Reinstall Block" -Item "DisableWindowsConsumerFeatures" -Status Failed -Detail $_.Exception.Message
        }
    } else {
        Write-DryRun "Set DisableWindowsConsumerFeatures = 1"
        Add-ReportItem -Phase "Reinstall Block" -Item "DisableWindowsConsumerFeatures" -Status Skipped -Detail "Dry run"
        $blocked++
    }

    # Disable Content Delivery Manager OEM and silent app installation.
    # Applied to EVERY user hive (current, other profiles, Default template for new users).
    $cdmSettings = @{
        "OemPreInstalledAppsEnabled"       = 0
        "PreInstalledAppsEnabled"          = 0
        "PreInstalledAppsEverEnabled"      = 0
        "SilentInstalledAppsEnabled"       = 0
        "ContentDeliveryAllowed"           = 0
        "SubscribedContent-338388Enabled"  = 0
        "SubscribedContent-338389Enabled"  = 0
        "SubscribedContent-314559Enabled"  = 0
    }

    $perUserActions = {
        param($hiveRoot)
        $cdmPath = Join-Path $hiveRoot "Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        if (-not (Test-Path -LiteralPath $cdmPath)) {
            New-Item -Path $cdmPath -Force -ErrorAction SilentlyContinue | Out-Null
        }
        foreach ($setting in $cdmSettings.GetEnumerator()) {
            try {
                Set-ItemProperty -LiteralPath $cdmPath -Name $setting.Key -Value $setting.Value -Type DWord -Force -ErrorAction Stop
            } catch { }
        }
        $explorerPath = Join-Path $hiveRoot "Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        if (-not (Test-Path -LiteralPath $explorerPath)) {
            New-Item -Path $explorerPath -Force -ErrorAction SilentlyContinue | Out-Null
        }
        try {
            Set-ItemProperty -LiteralPath $explorerPath -Name "Start_IrisRecommendations" -Value 0 -Type DWord -Force -ErrorAction Stop
        } catch { }
    }

    if (-not $DryRun) {
        # Current user first (fastest, no hive load required)
        try {
            & $perUserActions "Registry::HKEY_CURRENT_USER"
            $blocked += ($cdmSettings.Count + 1)
            foreach ($k in $cdmSettings.Keys) {
                Add-ReportItem -Phase "Reinstall Block" -Item "HKCU:$k" -Status Removed -Detail "Set to $($cdmSettings[$k])"
                Add-UndoEntry -Phase "Reinstall Block" -Action "SetDword" -Target "HKCU:Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\$k" -After $cdmSettings[$k]
            }
            Add-ReportItem -Phase "Reinstall Block" -Item "HKCU:Start_IrisRecommendations" -Status Removed -Detail "Set to 0"
        } catch {
            Write-RunLog "Failed current-user CDM settings: $($_.Exception.Message)" -Level WARN
        }

        # All other profiles + Default
        try {
            Invoke-PerUserRegistry -Action $perUserActions
            Add-ReportItem -Phase "Reinstall Block" -Item "CDM/Iris (all profiles + Default)" -Status Removed -Detail "Applied to every NTUSER.DAT"
            Write-RunLog "CDM + Iris settings applied across all user hives (including Default)" -Level SUCCESS
            $blocked++
        } catch {
            Write-RunLog "Per-user CDM iteration failed: $($_.Exception.Message)" -Level WARN
        }
    } else {
        foreach ($k in $cdmSettings.Keys) {
            Write-DryRun "Set $k = $($cdmSettings[$k]) (HKCU + all user profiles + Default)"
            Add-ReportItem -Phase "Reinstall Block" -Item $k -Status Skipped -Detail "Dry run - per-user"
            $blocked++
        }
        Write-DryRun "Set Start_IrisRecommendations = 0 (HKCU + all user profiles + Default)"
        Add-ReportItem -Phase "Reinstall Block" -Item "Start_IrisRecommendations" -Status Skipped -Detail "Dry run - per-user"
        $blocked++
    }

    # Block OEM driver delivery via Windows Update - the universal "it keeps coming back" fix.
    $wuPolicies = @(
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate";       Name = "ExcludeWUDriversInQualityUpdate"; Value = 1 },
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"; Name = "DontSearchWindowsUpdate";         Value = 1 },
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"; Name = "DontPromptForWindowsUpdate";      Value = 1 },
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"; Name = "SearchOrderConfig";               Value = 0 }
    )

    foreach ($policy in $wuPolicies) {
        if (-not $DryRun) {
            try {
                Initialize-RegistryKey -Path $policy.Path
                $before = (Get-ItemProperty -LiteralPath $policy.Path -Name $policy.Name -ErrorAction SilentlyContinue).$($policy.Name)
                Set-ItemProperty -Path $policy.Path -Name $policy.Name -Value $policy.Value -Type DWord -Force
                Add-ReportItem -Phase "Reinstall Block" -Item "$($policy.Path)\$($policy.Name)" -Status Removed -Detail "Set to $($policy.Value)"
                Add-UndoEntry -Phase "Reinstall Block" -Action "SetDword" -Target "$($policy.Path)\$($policy.Name)" -Before $before -After $policy.Value
                $blocked++
            } catch {
                Write-RunLog "Failed WU policy $($policy.Name): $($_.Exception.Message)" -Level WARN
                Add-ReportItem -Phase "Reinstall Block" -Item $policy.Name -Status Failed -Detail $_.Exception.Message
            }
        } else {
            Write-DryRun "Set $($policy.Path)\$($policy.Name) = $($policy.Value)"
            Add-ReportItem -Phase "Reinstall Block" -Item $policy.Name -Status Skipped -Detail "Dry run"
            $blocked++
        }
    }
    Write-RunLog "Applied Windows Update driver-delivery blocks" -Level SUCCESS

    # Block installation of OEM device hardware IDs via Device Installation Restrictions policy.
    # Enumerates currently-attached OEM devices and adds each hardware ID to DenyDeviceIDs.
    # This is the Group Policy equivalent of "Prevent installation of devices that match these device IDs".
    $restrictionsPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
    $denyDeviceIdsPath = "$restrictionsPath\DenyDeviceIDs"

    if (-not $DryRun) {
        try {
            Initialize-RegistryKey -Path $restrictionsPath
            Initialize-RegistryKey -Path $denyDeviceIdsPath
            Set-ItemProperty -Path $restrictionsPath -Name "DenyDeviceIDs"            -Value 1 -Type DWord -Force
            Set-ItemProperty -Path $restrictionsPath -Name "DenyDeviceIDsRetroactive" -Value 0 -Type DWord -Force

            # Preserve existing deny list (avoid clobbering admin-defined entries), append our discoveries.
            # Case-insensitive comparer: Windows treats hardware IDs as case-insensitive.
            $existing = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $props = @()
            $denyKey = Get-Item -LiteralPath $denyDeviceIdsPath -ErrorAction SilentlyContinue
            if ($denyKey) { $props = @($denyKey.Property) }
            foreach ($prop in $props) {
                $val = (Get-ItemProperty -LiteralPath $denyDeviceIdsPath -Name $prop -ErrorAction SilentlyContinue).$prop
                if ($val) { $existing[$val] = $prop }
            }

            $oemDevices = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
                ($_.Manufacturer -match 'Dell|Alienware|Hewlett|HP\b|Lenovo') -or
                ($_.FriendlyName  -match 'Dell|Alienware|SupportAssist|PC-Doctor|Lenovo.*Vantage|HP Wolf|MaxxAudio')
            }

            # Collect hardware IDs from three sources: live devices, OEM-config seeds, and operator seed file
            $hwidCandidates = New-Object System.Collections.Generic.List[string]

            foreach ($dev in $oemDevices) {
                try {
                    $discovered = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName DEVPKEY_Device_HardwareIds -ErrorAction SilentlyContinue).Data
                    foreach ($hw in @($discovered)) { if ($hw) { [void]$hwidCandidates.Add([string]$hw) } }
                } catch { }
            }

            foreach ($seed in @($Targets.HardwareIdSeeds)) {
                if ($seed) { [void]$hwidCandidates.Add([string]$seed) }
            }

            foreach ($seed in (Get-HardwareIdSeedsFromFile -Path $HardwareIdSeedsFile)) {
                if ($seed) { [void]$hwidCandidates.Add([string]$seed) }
            }

            $nextIndex = 1
            while ($existing.Values -contains "$nextIndex") { $nextIndex++ }
            $added = 0

            foreach ($hwid in $hwidCandidates) {
                if ([string]::IsNullOrWhiteSpace($hwid)) { continue }
                if ($existing.ContainsKey($hwid)) { continue }
                try {
                    Set-ItemProperty -Path $denyDeviceIdsPath -Name "$nextIndex" -Value $hwid -Type String -Force
                    $existing[$hwid] = "$nextIndex"
                    $added++
                    $nextIndex++
                } catch { }
            }

            if ($added -gt 0) {
                Add-ReportItem -Phase "Reinstall Block" -Item "Hardware-ID device install block" -Status Removed -Detail "$added OEM hardware IDs denied"
                Add-UndoEntry -Phase "Reinstall Block" -Action "DenyHardwareIDs" -Target $denyDeviceIdsPath -After $added
                Write-RunLog "Blocked $added OEM hardware IDs from driver installation" -Level SUCCESS
            } else {
                Add-ReportItem -Phase "Reinstall Block" -Item "Hardware-ID device install block" -Status Skipped -Detail "No new OEM hardware IDs detected"
            }
            $blocked++
        } catch {
            Write-RunLog "Hardware-ID block failed: $($_.Exception.Message)" -Level WARN
            Add-ReportItem -Phase "Reinstall Block" -Item "Hardware-ID device install block" -Status Failed -Detail $_.Exception.Message
        }
    } else {
        Write-DryRun "Enable DenyDeviceIDs and populate with OEM hardware IDs"
        Add-ReportItem -Phase "Reinstall Block" -Item "Hardware-ID device install block" -Status Skipped -Detail "Dry run"
        $blocked++
    }

    # Dell Command Update lockdown (only when operator opted to keep DCU for BIOS/driver mgmt).
    # Silences first-run popup, marks config applied, and disables auto-check scheduler behavior.
    if ($KeepDellCommandUpdate) {
        $dcuKeys = @{
            "ShowSetupPopup"             = 0
            "ConfigApplied"              = 1
            "DisableMultipleNotification"= 1
            "DisableSystemTrayIcon"      = 1
        }
        $dcuPath = "HKLM:\SOFTWARE\Dell\UpdateService\Clients\CommandUpdate\Preferences\CFG"
        if (-not $DryRun) {
            try {
                Initialize-RegistryKey -Path $dcuPath
                foreach ($kv in $dcuKeys.GetEnumerator()) {
                    Set-ItemProperty -Path $dcuPath -Name $kv.Key -Value $kv.Value -Type DWord -Force
                    Add-UndoEntry -Phase "Reinstall Block" -Action "DCULockdown" -Target "$dcuPath\$($kv.Key)" -After $kv.Value
                }
                Add-ReportItem -Phase "Reinstall Block" -Item "Dell Command Update lockdown" -Status Removed -Detail "Silenced popups / tray"
                Write-RunLog "Applied Dell Command Update lockdown (kept for BIOS/driver management)" -Level SUCCESS
                $blocked++
            } catch {
                Write-RunLog "DCU lockdown failed: $($_.Exception.Message)" -Level WARN
                Add-ReportItem -Phase "Reinstall Block" -Item "Dell Command Update lockdown" -Status Failed -Detail $_.Exception.Message
            }
        } else {
            Write-DryRun "Apply DCU lockdown registry keys under $dcuPath"
            Add-ReportItem -Phase "Reinstall Block" -Item "Dell Command Update lockdown" -Status Skipped -Detail "Dry run"
            $blocked++
        }
    }

    if ($DryRun) {
        Write-RunLog "Dry run evaluated $blocked reinstallation prevention settings" -Level SUCCESS
    } else {
        Write-RunLog "Applied $blocked reinstallation prevention settings" -Level SUCCESS
    }
    Write-RunLog "NOTE: To leave OEM reinstall paths available in future runs, turn off Block Reinstall in the GUI or manually revert these registry settings." -Level INFO

    return $blocked
}

# ============================================================================
# PHASE 9: RESIDUE CLEANUP
# ============================================================================
# Cleanup vectors that survive normal uninstallers: OEM driver packages, firewall rules,
# Defender exclusions OEMs add for their own installers, and pending BITS transfers.

function Invoke-OEMResidueCleanup {
    param([hashtable]$Targets)

    Write-RunLog -Message "PHASE 9: Residue Cleanup (Drivers / Firewall / Defender / BITS)" -Level PHASE

    if ($SkipResidueCleanup) {
        Write-RunLog "Residue cleanup skipped by parameter" -Level WARN
        return 0
    }

    $count = 0

    # --- Driver packages via pnputil ---
    # Uses Get-WindowsDriver (DISM module) - ships with Win10 1809+ and Win11.
    # If the cmdlet is unavailable we log and skip rather than attempt fragile text parsing of pnputil output.
    try {
        $providerRegex = 'Dell|PC-Doctor|Hewlett|^HP |Lenovo|Alienware|WavesAudio'
        $drivers = @()
        if (Get-Command Get-WindowsDriver -ErrorAction SilentlyContinue) {
            try {
                $drivers = @(Get-WindowsDriver -Online -ErrorAction Stop | Where-Object {
                    $_.ProviderName -match $providerRegex
                })
            } catch {
                Write-RunLog "Get-WindowsDriver failed: $($_.Exception.Message). Skipping driver cleanup." -Level WARN
            }
        } else {
            Write-RunLog "Get-WindowsDriver cmdlet not available. Skipping driver cleanup." -Level WARN
        }

        foreach ($drv in $drivers) {
            $inf = $drv.Driver
            if (-not $inf) { continue }
            if (-not $DryRun) {
                $null = & pnputil.exe /delete-driver $inf /uninstall /force 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-RunLog "  Removed driver package: $inf ($($drv.ProviderName))" -Level SUCCESS
                    Add-ReportItem -Phase "Residue" -Item "Driver: $inf" -Status Removed -Detail $drv.ProviderName
                    Add-UndoEntry -Phase "Residue" -Action "DeleteDriver" -Target $inf -Before $drv.ProviderName
                    $count++
                } else {
                    Write-RunLog "  pnputil returned $LASTEXITCODE for $inf (driver may be in use)" -Level WARN
                    Add-ReportItem -Phase "Residue" -Item "Driver: $inf" -Status Failed -Detail "pnputil exit $LASTEXITCODE"
                }
            } else {
                Write-DryRun "pnputil /delete-driver $inf /uninstall /force ($($drv.ProviderName))"
                Add-ReportItem -Phase "Residue" -Item "Driver: $inf" -Status Skipped -Detail "Dry run ($($drv.ProviderName))"
                $count++
            }
        }
    } catch {
        Write-RunLog "Driver enumeration failed: $($_.Exception.Message)" -Level WARN
    }

    # --- Firewall rules ---
    try {
        $firewallRegex = '(?i)Dell|SupportAssist|PC-Doctor|Alienware|MaxxAudio|Hewlett|^HP\b|HP Wolf|HP Sure|Lenovo|ImController|Vantage'
        $rules = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -match $firewallRegex -or $_.DisplayGroup -match $firewallRegex
        }
        foreach ($rule in $rules) {
            if (-not $DryRun) {
                try {
                    $rule | Remove-NetFirewallRule -ErrorAction Stop
                    Write-RunLog "  Removed firewall rule: $($rule.DisplayName)" -Level SUCCESS
                    Add-ReportItem -Phase "Residue" -Item "Firewall: $($rule.DisplayName)" -Status Removed
                    Add-UndoEntry -Phase "Residue" -Action "DeleteFirewallRule" -Target $rule.Name -Before $rule.DisplayName
                    $count++
                } catch {
                    Add-ReportItem -Phase "Residue" -Item "Firewall: $($rule.DisplayName)" -Status Failed -Detail $_.Exception.Message
                }
            } else {
                Write-DryRun "Remove firewall rule: $($rule.DisplayName)"
                Add-ReportItem -Phase "Residue" -Item "Firewall: $($rule.DisplayName)" -Status Skipped -Detail "Dry run"
                $count++
            }
        }
    } catch {
        Write-RunLog "Firewall rule cleanup failed: $($_.Exception.Message)" -Level WARN
    }

    # --- Defender exclusions the OEM added for its own installers (leaves attack surface) ---
    try {
        $defenderRegex = '(?i)Dell|SupportAssist|PC-Doctor|Alienware|DDV|Hewlett|\\HP\\|Lenovo|ImController|Vantage'
        $mp = Get-MpPreference -ErrorAction SilentlyContinue
        if ($mp) {
            foreach ($prop in @('ExclusionPath','ExclusionProcess','ExclusionExtension')) {
                $values = @($mp.$prop) | Where-Object { $_ -and $_ -match $defenderRegex }
                foreach ($v in $values) {
                    if (-not $DryRun) {
                        try {
                            switch ($prop) {
                                'ExclusionPath'      { Remove-MpPreference -ExclusionPath $v -ErrorAction Stop }
                                'ExclusionProcess'   { Remove-MpPreference -ExclusionProcess $v -ErrorAction Stop }
                                'ExclusionExtension' { Remove-MpPreference -ExclusionExtension $v -ErrorAction Stop }
                            }
                            Write-RunLog "  Removed Defender exclusion ($prop): $v" -Level SUCCESS
                            Add-ReportItem -Phase "Residue" -Item "Defender $prop" -Status Removed -Detail $v
                            Add-UndoEntry -Phase "Residue" -Action "RemoveDefenderExclusion" -Target "$prop=$v"
                            $count++
                        } catch {
                            Add-ReportItem -Phase "Residue" -Item "Defender $prop" -Status Failed -Detail "$v - $($_.Exception.Message)"
                        }
                    } else {
                        Write-DryRun "Remove Defender exclusion ($prop): $v"
                        Add-ReportItem -Phase "Residue" -Item "Defender $prop" -Status Skipped -Detail "Dry run - $v"
                        $count++
                    }
                }
            }
        }
    } catch {
        Write-RunLog "Defender exclusion scan failed: $($_.Exception.Message)" -Level WARN
    }

    # --- BITS transfers OEM updaters have queued ---
    try {
        $bitsRegex = '(?i)Dell|SupportAssist|Alienware|Hewlett|\\HP\\|HP Wolf|Lenovo|Vantage'
        $jobs = Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -match $bitsRegex -or $_.Description -match $bitsRegex
        }
        foreach ($j in $jobs) {
            if (-not $DryRun) {
                try {
                    $j | Remove-BitsTransfer -ErrorAction Stop
                    Write-RunLog "  Cancelled BITS transfer: $($j.DisplayName)" -Level SUCCESS
                    Add-ReportItem -Phase "Residue" -Item "BITS: $($j.DisplayName)" -Status Removed
                    Add-UndoEntry -Phase "Residue" -Action "CancelBITS" -Target $j.DisplayName
                    $count++
                } catch {
                    Add-ReportItem -Phase "Residue" -Item "BITS: $($j.DisplayName)" -Status Failed -Detail $_.Exception.Message
                }
            } else {
                Write-DryRun "Cancel BITS transfer: $($j.DisplayName)"
                Add-ReportItem -Phase "Residue" -Item "BITS: $($j.DisplayName)" -Status Skipped -Detail "Dry run"
                $count++
            }
        }
    } catch {
        Write-RunLog "BITS scan failed: $($_.Exception.Message)" -Level WARN
    }

    if ($count -eq 0) {
        Write-RunLog "No residue found" -Level INFO
    } elseif ($DryRun) {
        Write-RunLog "Dry run found $count residue items" -Level SUCCESS
    } else {
        Write-RunLog "Cleared $count residue items" -Level SUCCESS
    }

    return $count
}

# ============================================================================
# VERIFICATION
# ============================================================================

function Test-OEMRemoval {
    param([hashtable]$Targets)

    Write-RunLog -Message "VERIFICATION: Checking for OEM Remnants" -Level PHASE

    $issues = @()

    # Check for remaining AppX packages
    $remainingAppx = foreach ($pattern in $Targets.AppxPatterns) {
        Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue
    }
    if ($remainingAppx) {
        $issues += "Remaining AppX packages: $($remainingAppx.Name -join ', ')"
    }

    # Check for remaining services
    $remainingServices = Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $svc = $_
        $match = $false
        foreach ($pattern in $Targets.ServicePatterns) {
            if ($svc.DisplayName -like $pattern -or $svc.Name -like $pattern) {
                $match = $true
                break
            }
        }
        $match
    }
    if ($remainingServices) {
        $issues += "Remaining services: $($remainingServices.DisplayName -join ', ')"
    }

    # Check for remaining scheduled tasks
    $remainingTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $task = $_
        $match = $false
        foreach ($pattern in $Targets.TaskPatterns) {
            if ($task.TaskName -like $pattern -or $task.TaskPath -like $pattern) {
                $match = $true
                break
            }
        }
        $match
    }
    if ($remainingTasks) {
        $issues += "Remaining scheduled tasks: $($remainingTasks.TaskName -join ', ')"
    }

    # Check for remaining processes
    $remainingProcesses = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $proc = $_
        $match = $false
        foreach ($pattern in $Targets.ProcessPatterns) {
            if ($proc.Name -like $pattern) {
                $match = $true
                break
            }
        }
        $match
    }
    if ($remainingProcesses) {
        $issues += "Remaining processes: $($remainingProcesses.Name -join ', ')"
    }

    if ($DryRun) {
        Write-RunLog "VERIFICATION SKIPPED: Dry run mode - no changes were made" -Level WARN
        return $true
    }

    if ($issues.Count -eq 0) {
        Write-RunLog "VERIFICATION PASSED: No OEM remnants detected" -Level SUCCESS
        return $true
    } else {
        Write-RunLog "VERIFICATION WARNING: Some OEM items may remain" -Level WARN
        foreach ($issue in $issues) {
            Write-RunLog "  - $issue" -Level WARN
        }
        Write-RunLog "A system restart may be required to complete removal" -Level INFO
        return $false
    }
}

# ============================================================================
# HTML REPORT
# ============================================================================

function New-HTMLReport {
    param(
        [hashtable]$Results,
        [bool]$Verified,
        [string[]]$TargetOEMs,
        [TimeSpan]$Elapsed
    )

    $reportPath = $ReportPath

    # WMI can fail on broken/managed systems; never let report generation throw because of it.
    $sysInfo = $null
    $osInfo  = $null
    try { $sysInfo = Get-CimInstance Win32_ComputerSystem   -ErrorAction Stop } catch { Write-RunLog "Win32_ComputerSystem query failed: $($_.Exception.Message)" -Level WARN }
    try { $osInfo  = Get-CimInstance Win32_OperatingSystem  -ErrorAction Stop } catch { Write-RunLog "Win32_OperatingSystem query failed: $($_.Exception.Message)" -Level WARN }
    $manufacturerRaw = if ($sysInfo) { $sysInfo.Manufacturer } else { "Unknown" }
    $modelRaw        = if ($sysInfo) { $sysInfo.Model }        else { "Unknown" }
    $osRaw           = if ($osInfo)  { "$($osInfo.Caption) ($($osInfo.Version))" } else { "Unknown" }

    if ($DryRun) {
        $summaryDetails = @{
            Processes  = "Running OEM executables that would be stopped"
            Services   = "Services that would be stopped, disabled, and deleted"
            AppX       = "Installed and provisioned Store packages that would be removed"
            Win32      = "Desktop app cleanup checks that would run"
            Tasks      = "Scheduled tasks and OEM task folders that would be removed"
            Registry   = "OEM registry keys and startup entries that would be removed"
            Filesystem = "OEM directories and Start Menu remnants that would be removed"
            Reinstall  = "Windows consumer/OEM app reinstall settings that would be changed"
            Residue    = "OEM drivers, firewall rules, Defender exclusions, and BITS jobs that would be cleared"
        }
    } else {
        $summaryDetails = @{
            Processes  = "Running OEM executables stopped"
            Services   = "Services stopped, disabled, and deleted"
            AppX       = "Installed and provisioned Store packages removed"
            Win32      = "Desktop apps removed through ARP, winget, or fallback uninstallers"
            Tasks      = "Scheduled tasks and OEM task folders removed"
            Registry   = "OEM registry keys and startup entries removed"
            Filesystem = "OEM directories and Start Menu remnants removed"
            Reinstall  = "Windows consumer/OEM app reinstall paths blocked"
            Residue    = "OEM driver packages, firewall rules, Defender exclusions, and BITS jobs cleared"
        }
    }

    $residueCount = 0
    if ($Results.ContainsKey("ResidueItems")) { $residueCount = [int]$Results.ResidueItems }

    $summaryRows = @(
        [PSCustomObject]@{ Phase = "Processes";   Count = $Results.Processes + $Results.ProcessesSecondPass; Detail = $summaryDetails.Processes },
        [PSCustomObject]@{ Phase = "Services";    Count = $Results.Services; Detail = $summaryDetails.Services },
        [PSCustomObject]@{ Phase = "AppX";        Count = $Results.AppxPackages; Detail = $summaryDetails.AppX },
        [PSCustomObject]@{ Phase = "Win32 Apps";  Count = $Results.Win32Apps; Detail = $summaryDetails.Win32 },
        [PSCustomObject]@{ Phase = "Tasks";       Count = $Results.ScheduledTasks; Detail = $summaryDetails.Tasks },
        [PSCustomObject]@{ Phase = "Registry";    Count = $Results.RegistryItems; Detail = $summaryDetails.Registry },
        [PSCustomObject]@{ Phase = "Filesystem";  Count = $Results.FilesystemItems; Detail = $summaryDetails.Filesystem },
        [PSCustomObject]@{ Phase = "Reinstall";   Count = $Results.ReinstallBlocks; Detail = $summaryDetails.Reinstall },
        [PSCustomObject]@{ Phase = "Residue";     Count = $residueCount; Detail = $summaryDetails.Residue }
    )

    $totalProcessed = ($summaryRows | Measure-Object -Property Count -Sum).Sum
    if ($null -eq $totalProcessed) { $totalProcessed = 0 }
    $totalProcessed = [int]$totalProcessed

    $summaryHtml = ""
    foreach ($row in $summaryRows) {
        $phase = ConvertTo-ReportHtml $row.Phase
        $detail = ConvertTo-ReportHtml $row.Detail
        $countClass = if ($row.Count -gt 0) { "has-count" } else { "zero-count" }
        $summaryHtml += @"
      <article class="metric-card $countClass">
        <div>
          <p class="metric-label">$phase</p>
          <p class="metric-help">$detail</p>
        </div>
        <strong class="metric-value">$($row.Count)</strong>
      </article>
"@
    }

    # Build report item rows
    $rowsHtml = ""
    foreach ($item in $Script:ReportItems) {
        $statusClass = switch ($item.Status) {
            "Removed" { "removed" }
            "Skipped" { "skipped" }
            "Failed"  { "failed" }
        }
        $phase = ConvertTo-ReportHtml $item.Phase
        $itemName = ConvertTo-ReportHtml $item.Item
        $detail = if ([string]::IsNullOrWhiteSpace([string]$item.Detail)) { "None" } else { ConvertTo-ReportHtml $item.Detail }
        $status = ConvertTo-ReportHtml $item.Status

        $rowsHtml += @"
        <tr class="result-row is-$statusClass">
          <td><span class="phase-name">$phase</span></td>
          <td class="item-cell">$itemName</td>
          <td><span class="status-label status-$statusClass"><span class="status-dot" aria-hidden="true"></span>$status</span></td>
          <td class="detail-cell">$detail</td>
        </tr>
"@
    }

    if ([string]::IsNullOrWhiteSpace($rowsHtml)) {
        $emptyCopy = if ($DryRun) {
            "Dry run found no matching OEM items for the selected target set."
        } else {
            "No matching OEM items were found. The selected target surface appears clean."
        }

        $rowsHtml = @"
        <tr class="empty-row">
          <td colspan="4">
            <div class="empty-state">
              <strong>No Matching Items</strong>
              <span>$(ConvertTo-ReportHtml $emptyCopy)</span>
            </div>
          </td>
        </tr>
"@
    }

    $dryRunBanner = ""
    if ($DryRun) {
        $dryRunBanner = @"
      <aside class="notice notice-warning" role="status" aria-live="polite">
        <strong>Dry Run</strong>
        <span>No changes were made. Review this report, then turn off Dry run in the GUI when ready.</span>
      </aside>
"@
    }

    $verificationClass = if ($Verified) { "success" } else { "danger" }
    $verificationLabel = if ($Verified) { "Verified" } else { "Review Needed" }
    $verificationHelp = if ($Verified) {
        "No matching OEM remnants were detected in the final verification pass."
    } elseif ($DryRun) {
        "Verification is informational in dry-run mode because no changes were applied."
    } else {
        "Some OEM remnants may remain. Restart Windows, then run the remover again."
    }

    $runMode = if ($DryRun) { "Dry Run" } else { "Live Cleanup" }
    $generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss K")
    $manufacturer = ConvertTo-ReportHtml $manufacturerRaw
    $model = ConvertTo-ReportHtml $modelRaw
    $os = ConvertTo-ReportHtml $osRaw
    $targetText = ConvertTo-ReportHtml ($TargetOEMs -join ", ")
    $elapsedText = ConvertTo-ReportHtml ($Elapsed.ToString("mm\:ss"))
    $generatedText = ConvertTo-ReportHtml $generatedAt
    $logPathText = ConvertTo-ReportHtml $LogPath
    $verificationHelpText = ConvertTo-ReportHtml $verificationHelp

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="theme-color" content="#0b0f17">
  <title>NuclearOEMRemover Report</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #0b0f17;
    --surface: #111827;
    --surface-raised: #162033;
    --line: #2d3748;
    --line-soft: #1f2937;
    --text: #edf2f7;
    --muted: #9aa7b7;
    --faint: #6b7788;
    --accent: #66a6ff;
    --danger: #ff6b6b;
    --danger-bg: #261316;
    --success: #5ee2a0;
    --success-bg: #10251b;
    --warning: #f6c768;
    --warning-bg: #2a2111;
    --radius: 8px;
  }

  * { box-sizing: border-box; }

  html {
    background: var(--bg);
    scroll-behavior: smooth;
  }

  body {
    margin: 0;
    min-width: 320px;
    background: var(--bg);
    color: var(--text);
    font-family: "Segoe UI", Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, Arial, sans-serif;
    line-height: 1.5;
    -webkit-font-smoothing: antialiased;
    text-rendering: optimizeLegibility;
  }

  a { color: var(--accent); }

  .skip-link {
    position: absolute;
    left: 24px;
    top: 16px;
    z-index: 10;
    transform: translateY(-140%);
    border-radius: 6px;
    background: var(--accent);
    color: #07111f;
    padding: 10px 14px;
    font-weight: 700;
    transition: transform 120ms ease;
  }

  .skip-link:focus-visible {
    transform: translateY(0);
    outline: 3px solid #2d5f9f;
    outline-offset: 3px;
  }

  .page-shell {
    width: min(1180px, calc(100% - 40px));
    margin: 0 auto;
  }

  .hero {
    border-bottom: 1px solid var(--line-soft);
    background: #0e1522;
    padding: 44px 0 32px;
  }

  .eyebrow {
    margin: 0 0 10px;
    color: var(--accent);
    font-size: 12px;
    font-weight: 800;
    letter-spacing: .08em;
    text-transform: uppercase;
  }

  h1, h2 {
    text-wrap: balance;
  }

  [id] {
    scroll-margin-top: 24px;
  }

  h1 {
    margin: 0;
    max-width: 820px;
    color: var(--text);
    font-size: clamp(32px, 5vw, 56px);
    line-height: 1.02;
    letter-spacing: 0;
  }

  .subtitle {
    max-width: 760px;
    margin: 16px 0 0;
    color: var(--muted);
    font-size: 17px;
  }

  .run-metadata {
    display: grid;
    grid-template-columns: repeat(4, minmax(120px, max-content));
    column-gap: 28px;
    row-gap: 14px;
    margin-top: 24px;
    padding-top: 18px;
    border-top: 1px solid var(--line-soft);
  }

  .run-metadata div {
    min-width: 0;
  }

  .run-metadata dt {
    margin: 0;
    color: var(--faint);
    font-size: 11px;
    font-weight: 800;
    letter-spacing: .06em;
    text-transform: uppercase;
  }

  .run-metadata dd {
    margin: 4px 0 0;
    color: var(--text);
    font-size: 13px;
    font-weight: 700;
    overflow-wrap: anywhere;
  }

  .main {
    padding: 28px 0 44px;
  }

  .notice {
    display: flex;
    gap: 12px;
    align-items: flex-start;
    margin-bottom: 20px;
    border: 1px solid;
    border-radius: var(--radius);
    padding: 14px 16px;
  }

  .notice strong { min-width: 92px; }
  .notice code { color: inherit; font-weight: 800; }
  .notice-warning { border-color: #7a612b; background: var(--warning-bg); color: #ffe5ad; }
  .notice-success { border-color: #2f7a55; background: var(--success-bg); color: #c6ffe0; }
  .notice-danger { border-color: #883638; background: var(--danger-bg); color: #ffc7c7; }

  .section {
    margin-top: 28px;
  }

  .section-header {
    display: flex;
    align-items: end;
    justify-content: space-between;
    gap: 18px;
    margin-bottom: 14px;
  }

  h2 {
    margin: 0;
    font-size: 21px;
    line-height: 1.2;
  }

  .section-note {
    margin: 4px 0 0;
    color: var(--muted);
    font-size: 13px;
  }

  .info-grid,
  .metric-grid {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 12px;
  }

  .info-card,
  .metric-card {
    min-width: 0;
    border: 1px solid var(--line-soft);
    border-radius: var(--radius);
    background: var(--surface);
    padding: 14px;
  }

  .info-label,
  .metric-label {
    margin: 0;
    color: var(--faint);
    font-size: 11px;
    font-weight: 800;
    letter-spacing: .06em;
    text-transform: uppercase;
  }

  .info-value {
    margin: 6px 0 0;
    color: var(--text);
    font-size: 15px;
    font-weight: 700;
    overflow-wrap: anywhere;
  }

  .metric-card {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 14px;
  }

  .metric-card.has-count {
    border-color: #2f7a55;
    background: #111f1a;
  }

  .metric-help {
    margin: 6px 0 0;
    color: var(--muted);
    font-size: 12px;
  }

  .metric-value {
    color: var(--text);
    font-size: 30px;
    line-height: 1;
    font-variant-numeric: tabular-nums;
  }

  .zero-count .metric-value { color: var(--faint); }

  .table-wrap {
    overflow-x: auto;
    border: 1px solid var(--line-soft);
    border-radius: var(--radius);
    background: var(--surface);
  }

  table {
    width: 100%;
    min-width: 760px;
    border-collapse: collapse;
  }

  caption.sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
  }

  th {
    position: sticky;
    top: 0;
    z-index: 1;
    background: var(--surface-raised);
    color: var(--muted);
    padding: 12px 14px;
    border-bottom: 1px solid var(--line);
    font-size: 11px;
    font-weight: 800;
    letter-spacing: .06em;
    text-align: left;
    text-transform: uppercase;
  }

  td {
    padding: 13px 14px;
    border-bottom: 1px solid var(--line-soft);
    color: var(--text);
    vertical-align: top;
    overflow-wrap: anywhere;
  }

  tr:last-child td { border-bottom: 0; }

  .result-row {
    transition: background-color 120ms ease;
  }

  .result-row:hover {
    background: #151e2d;
  }

  .phase-name {
    color: var(--muted);
    font-weight: 700;
  }

  .item-cell {
    max-width: 520px;
    font-family: Consolas, "SFMono-Regular", ui-monospace, monospace;
    font-size: 12px;
  }

  .detail-cell {
    color: var(--muted);
  }

  .status-label {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    color: var(--muted);
    font-size: 12px;
    font-weight: 800;
    letter-spacing: .02em;
    text-transform: uppercase;
    white-space: nowrap;
  }

  .status-dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: currentColor;
  }

  .status-removed {
    color: var(--success);
  }

  .status-skipped {
    color: var(--warning);
  }

  .status-failed {
    color: var(--danger);
  }

  .status-success {
    color: var(--success);
  }

  .status-danger {
    color: var(--danger);
  }

  .empty-state {
    display: grid;
    gap: 4px;
    justify-items: center;
    padding: 34px 16px;
    text-align: center;
  }

  .empty-state strong { color: var(--text); }
  .empty-state span { color: var(--muted); }

  .footer {
    margin-top: 34px;
    border-top: 1px solid var(--line-soft);
    padding-top: 18px;
    color: var(--faint);
    font-size: 12px;
  }

  @media (max-width: 900px) {
    .info-grid,
    .metric-grid {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
  }

  @media (max-width: 620px) {
    .page-shell {
      width: min(100% - 28px, 1180px);
    }

    .hero {
      padding: 32px 0 24px;
    }

    .info-grid,
    .metric-grid {
      grid-template-columns: 1fr;
    }

    .notice,
    .section-header {
      display: grid;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    html { scroll-behavior: auto; }
    .skip-link,
    .result-row {
      transition-duration: 1ms;
    }
  }
</style>
</head>
<body>
  <a class="skip-link" href="#main">Skip to report</a>
  <header class="hero">
    <div class="page-shell">
      <p class="eyebrow">Removal Report</p>
      <h1>NuclearOEMRemover v$($Script:Config.Version)</h1>
      <p class="subtitle">A focused audit of OEM cleanup activity, final verification state, and every item processed during this run.</p>
      <dl class="run-metadata" aria-label="Run metadata">
        <div>
          <dt>Mode</dt>
          <dd>$runMode</dd>
        </div>
        <div>
          <dt>Targets</dt>
          <dd>$targetText</dd>
        </div>
        <div>
          <dt>Elapsed</dt>
          <dd>$elapsedText</dd>
        </div>
        <div>
          <dt>Verification</dt>
          <dd class="status-$verificationClass">$verificationLabel</dd>
        </div>
      </dl>
    </div>
  </header>

  <main id="main" class="main page-shell">
    $dryRunBanner
    <aside class="notice notice-$verificationClass" role="status">
      <strong>$verificationLabel</strong>
      <span>$verificationHelpText</span>
    </aside>

    <section class="section" aria-labelledby="environment-heading">
      <div class="section-header">
        <div>
          <h2 id="environment-heading">Run Context</h2>
          <p class="section-note">System details captured at report generation.</p>
        </div>
      </div>
      <div class="info-grid">
        <article class="info-card">
          <p class="info-label">Manufacturer</p>
          <p class="info-value">$manufacturer</p>
        </article>
        <article class="info-card">
          <p class="info-label">Model</p>
          <p class="info-value">$model</p>
        </article>
        <article class="info-card">
          <p class="info-label">Operating System</p>
          <p class="info-value">$os</p>
        </article>
        <article class="info-card">
          <p class="info-label">Log Path</p>
          <p class="info-value">$logPathText</p>
        </article>
      </div>
    </section>

    <section class="section" aria-labelledby="summary-heading">
      <div class="section-header">
        <div>
          <h2 id="summary-heading">Phase Summary</h2>
          <p class="section-note">$totalProcessed total actions recorded across 8 cleanup phases.</p>
        </div>
      </div>
      <div class="metric-grid">
$summaryHtml
      </div>
    </section>

    <section class="section" aria-labelledby="results-heading">
      <div class="section-header">
        <div>
          <h2 id="results-heading">Detailed Results</h2>
          <p class="section-note">Every action is labeled with a status and supporting detail where available.</p>
        </div>
      </div>
      <div class="table-wrap">
        <table>
          <caption class="sr-only">Detailed OEM removal results</caption>
          <thead>
            <tr>
              <th scope="col">Phase</th>
              <th scope="col">Item</th>
              <th scope="col">Status</th>
              <th scope="col">Detail</th>
            </tr>
          </thead>
          <tbody>
$rowsHtml
          </tbody>
        </table>
      </div>
    </section>

    <footer class="footer">
      Generated $generatedText by NuclearOEMRemover v$($Script:Config.Version)
    </footer>
  </main>
</body>
</html>
"@

    $html | Out-File -FilePath $reportPath -Encoding utf8 -Force
    Write-RunLog "HTML report saved to: $reportPath" -Level SUCCESS
    return $reportPath
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

function Invoke-NuclearOEMRemover {
    if (-not $NoClearHost) {
        Clear-Host
    }

    try {
        Initialize-RunArtifactPath -Path $LogPath -Label "log"
        Initialize-RunArtifactPath -Path $ReportPath -Label "report"
        $Script:ReportItems.Clear()
    } catch {
        Write-Error "Could not initialize report/log paths: $($_.Exception.Message)"
        exit 1
    }

    Show-Banner

    # Resolve targets
    $targetOEMs = Get-TargetOEMs
    $mergedTargets = Build-MergedConfig -TargetOEMs $targetOEMs
    Show-RunOverview -TargetOEMs $targetOEMs -IsDryRun ([bool]$DryRun)

    Write-RunLog "NuclearOEMRemover v$($Script:Config.Version) starting..." -Level INFO
    Write-RunLog "Log file: $LogPath" -Level INFO
    Write-RunLog "Target OEMs: $($targetOEMs -join ', ')" -Level INFO
    Write-RunLog "Parameters: DryRun=$DryRun, KeepDCU=$KeepDellCommandUpdate, Force=$Force, SkipReinstallBlock=$SkipReinstallBlock, SkipFilesystemCleanup=$SkipFilesystemCleanup, SkipResidueCleanup=$SkipResidueCleanup, SkipRestorePoint=$SkipRestorePoint" -Level INFO

    # System Restore checkpoint - one-line safety net before live destructive changes.
    if (-not $DryRun -and -not $SkipRestorePoint) {
        # System Protection throttles to one restore point per 24h by default; temporarily relax.
        $srPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore"
        $srKeyCreatedByUs = $false
        $originalFreq = $null
        try {
            if (-not (Test-Path $srPath)) {
                New-Item -Path $srPath -Force | Out-Null
                $srKeyCreatedByUs = $true
            }
            $originalFreq = (Get-ItemProperty -Path $srPath -Name "SystemRestorePointCreationFrequency" -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
            Set-ItemProperty -Path $srPath -Name "SystemRestorePointCreationFrequency" -Value 0 -Type DWord -Force

            try {
                Checkpoint-Computer -Description "NuclearOEMRemover v$($Script:Config.Version) pre-run" -RestorePointType "APPLICATION_UNINSTALL" -ErrorAction Stop
                Write-RunLog "System Restore point created" -Level SUCCESS
                Add-ReportItem -Phase "Safety" -Item "System Restore point" -Status Removed -Detail "Pre-run checkpoint created"
            } catch {
                Write-RunLog "Could not create restore point (system protection may be disabled): $($_.Exception.Message)" -Level WARN
            }
        } catch {
            Write-RunLog "Restore-point setup failed: $($_.Exception.Message)" -Level WARN
        } finally {
            # Always restore the throttle setting + clean up the key if we created it
            try {
                if ($null -ne $originalFreq) {
                    Set-ItemProperty -Path $srPath -Name "SystemRestorePointCreationFrequency" -Value $originalFreq -Type DWord -Force -ErrorAction SilentlyContinue
                } else {
                    Remove-ItemProperty -Path $srPath -Name "SystemRestorePointCreationFrequency" -ErrorAction SilentlyContinue
                }
                if ($srKeyCreatedByUs -and (Test-Path $srPath)) {
                    $emptyKey = @(Get-ChildItem -Path $srPath -ErrorAction SilentlyContinue).Count -eq 0 -and
                                @((Get-Item -Path $srPath -ErrorAction SilentlyContinue).Property).Count -eq 0
                    if ($emptyKey) { Remove-Item -Path $srPath -Force -ErrorAction SilentlyContinue }
                }
            } catch { }
        }
    }

    # Results tracking
    $results = @{
        Processes          = 0
        ProcessesSecondPass = 0
        Services           = 0
        AppxPackages       = 0
        Win32Apps          = 0
        ScheduledTasks     = 0
        RegistryItems      = 0
        FilesystemItems    = 0
        ReinstallBlocks    = 0
        ResidueItems       = 0
    }

    # Execute all phases in a try/finally so undo manifest is always persisted even on a mid-run throw.
    $verified = $false
    $phaseFault = $null
    try {
        $results.Processes = Stop-OEMProcesses -Targets $mergedTargets
        $results.Services = Remove-OEMServices -Targets $mergedTargets

        # Second process kill - OEM services love to respawn executables immediately
        Write-RunLog -Message "PHASE 2.5: Second Process Kill (Catching Respawns)" -Level PHASE
        if (-not $DryRun) { Start-Sleep -Seconds 1 }
        $results.ProcessesSecondPass = Stop-OEMProcesses -Targets $mergedTargets
        if ($results.ProcessesSecondPass -gt 0) {
            Write-RunLog "Caught $($results.ProcessesSecondPass) respawned processes" -Level SUCCESS
        }

        $results.AppxPackages    = Remove-OEMAppxPackages     -Targets $mergedTargets
        $results.Win32Apps       = Remove-OEMWin32Apps        -Targets $mergedTargets
        $results.ScheduledTasks  = Remove-OEMScheduledTasks   -Targets $mergedTargets
        $results.RegistryItems   = Remove-OEMRegistry         -Targets $mergedTargets
        $results.FilesystemItems = Remove-OEMFilesystem       -Targets $mergedTargets
        $results.ReinstallBlocks = Block-OEMReinstallation
        $results.ResidueItems    = Invoke-OEMResidueCleanup   -Targets $mergedTargets
    } catch {
        $phaseFault = $_
        Write-RunLog "FATAL during phase execution: $($_.Exception.Message)" -Level ERROR
    } finally {
        # Persist undo manifest even on a fault so the operator has rollback data for whatever did complete
        Save-UndoManifest
    }

    # Verification runs even after partial failure so the report reflects reality
    try {
        $verified = Test-OEMRemoval -Targets $mergedTargets
    } catch {
        Write-RunLog "Verification threw: $($_.Exception.Message)" -Level WARN
        $verified = $false
    }

    # Summary
    Write-RunLog -Message "OPERATION COMPLETE" -Level PHASE

    $elapsed = (Get-Date) - $Script:Config.StartTime

    # Phase summary table
    Write-Host ""
    Write-Host "  NUCLEAR OEM REMOVER - SUMMARY" -ForegroundColor Cyan
    Write-Host "  =============================" -ForegroundColor Cyan
    Write-Host ""

    if ($DryRun) {
        $tableData = @(
            @{ Phase = "Processes Found";    Count = $results.Processes + $results.ProcessesSecondPass },
            @{ Phase = "Services Found";     Count = $results.Services },
            @{ Phase = "AppX Found";         Count = $results.AppxPackages },
            @{ Phase = "Win32 Checks";       Count = $results.Win32Apps },
            @{ Phase = "Task Items Found";   Count = $results.ScheduledTasks },
            @{ Phase = "Registry Found";     Count = $results.RegistryItems },
            @{ Phase = "Filesystem Found";   Count = $results.FilesystemItems },
            @{ Phase = "Reinstall Checks";   Count = $results.ReinstallBlocks },
            @{ Phase = "Residue Checks";     Count = $results.ResidueItems }
        )
    } else {
        $tableData = @(
            @{ Phase = "Processes Killed";    Count = $results.Processes + $results.ProcessesSecondPass },
            @{ Phase = "Services Removed";    Count = $results.Services },
            @{ Phase = "AppX Removed";        Count = $results.AppxPackages },
            @{ Phase = "Win32 Uninstalled";   Count = $results.Win32Apps },
            @{ Phase = "Tasks Removed";       Count = $results.ScheduledTasks },
            @{ Phase = "Registry Cleaned";    Count = $results.RegistryItems },
            @{ Phase = "Directories Cleaned"; Count = $results.FilesystemItems },
            @{ Phase = "Reinstall Blocks";    Count = $results.ReinstallBlocks },
            @{ Phase = "Residue Cleared";     Count = $results.ResidueItems }
        )
    }

    Write-Host ("  {0,-24} {1,6}" -f "Phase", "Count") -ForegroundColor White
    Write-Host ("  {0,-24} {1,6}" -f "------------------------", "------") -ForegroundColor DarkGray

    foreach ($row in $tableData) {
        $clr = if ($row.Count -gt 0) { "Green" } else { "DarkGray" }
        Write-Host ("  {0,-24} {1,6}" -f $row.Phase, $row.Count) -ForegroundColor $clr
    }

    Write-Host ""
    Write-Host "  Target OEMs:   $($targetOEMs -join ', ')" -ForegroundColor White
    Write-Host "  Verification:  $(if ($verified) { 'PASSED' } else { 'ISSUES FOUND' })" -ForegroundColor $(if ($verified) { "Green" } else { "Yellow" })
    Write-Host "  Elapsed Time:  $($elapsed.ToString('mm\:ss'))" -ForegroundColor White
    Write-Host "  Log File:      $LogPath" -ForegroundColor White

    if ($DryRun) {
        Write-Host ""
        Write-Host "  Dry run complete. No changes were made; turn off Dry run in the GUI when ready." -ForegroundColor Yellow
    }

    Write-Host ""

    if (-not $verified -and -not $DryRun) {
        Write-Host "  RECOMMENDATION: Restart your computer and run this script again." -ForegroundColor Yellow
        Write-Host ""
    }

    if (-not $DryRun) {
        Write-Host "  Cleanup complete. " -ForegroundColor Green -NoNewline
        Write-Host "Restart if any removals are pending." -ForegroundColor White
        Write-Host ""
    }

    # Generate HTML report
    $reportPath = New-HTMLReport -Results $results -Verified $verified -TargetOEMs $targetOEMs -Elapsed $elapsed
    Write-Host "  HTML Report: $reportPath" -ForegroundColor Cyan
    if (-not $DryRun -and $Script:UndoManifest.Count -gt 0 -and (Test-Path -LiteralPath $UndoManifestPath)) {
        Write-Host "  Undo Manifest: $UndoManifestPath" -ForegroundColor Cyan
    }
    Write-Host ""

    # Open report in default browser
    if (-not $NoOpenReport) {
        try {
            Start-Process $reportPath -ErrorAction Stop
        } catch {
            Write-RunLog "Could not open HTML report automatically: $($_.Exception.Message)" -Level WARN
        }
    }

    # Propagate a meaningful exit code for Intune/SCCM/RMM:
    #   0 = success (clean / dry-run),
    #   2 = completed but verification found remnants (reboot may clear),
    #   3 = exception during phase execution
    $exitCode = 0
    if ($phaseFault) { $exitCode = 3 }
    elseif (-not $DryRun -and -not $verified) { $exitCode = 2 }

    return [PSCustomObject]@{ Results = $results; ExitCode = $exitCode }
}

# Dot-source escape for the Pester harness. All engine helpers + $Script:OEMTargets + $Script:Config
# are now loaded into the caller's scope; return without touching the target system.
if ($LoadOnly) {
    return
}

# Run the engine and forward the exit code
$engineResult = Invoke-NuclearOEMRemover
$engineExit = 0
if ($engineResult -and $engineResult.ExitCode) { $engineExit = [int]$engineResult.ExitCode }
exit $engineExit
}

Set-StrictMode -Version 2.0

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-SelfRelaunch {
    param([bool]$RequireElevation)

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }

    $arguments = @(
        "-NoProfile",
        "-STA",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "`"$scriptPath`""
    ) -join " "

    $startInfo = @{
        FilePath     = "powershell.exe"
        ArgumentList = $arguments
    }

    if ($RequireElevation) {
        $startInfo.Verb = "RunAs"
    }

    Start-Process @startInfo
    exit
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
    Invoke-SelfRelaunch -RequireElevation (-not (Test-IsAdministrator))
}

if (-not (Test-IsAdministrator)) {
    Invoke-SelfRelaunch -RequireElevation $true
}

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

if (-not ("NuclearOEMRemover.ProcessOutputCapture" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

namespace NuclearOEMRemover
{
    public sealed class ProcessOutputCapture
    {
        private readonly ConcurrentQueue<string> outputLines = new ConcurrentQueue<string>();
        private readonly ConcurrentQueue<string> errorLines = new ConcurrentQueue<string>();

        public void OnOutputDataReceived(object sender, DataReceivedEventArgs e)
        {
            if (!String.IsNullOrWhiteSpace(e.Data))
            {
                outputLines.Enqueue(e.Data);
            }
        }

        public void OnErrorDataReceived(object sender, DataReceivedEventArgs e)
        {
            if (!String.IsNullOrWhiteSpace(e.Data))
            {
                errorLines.Enqueue(e.Data);
            }
        }

        public bool TryDequeueOutput(out string line)
        {
            return outputLines.TryDequeue(out line);
        }

        public bool TryDequeueError(out string line)
        {
            return errorLines.TryDequeue(out line);
        }
    }
}
'@
}

$Script:RepoRoot = Split-Path -Parent $PSCommandPath
$Script:ScriptPath = $PSCommandPath
if (-not $Script:ScriptPath) { $Script:ScriptPath = $MyInvocation.MyCommand.Path }
$Script:IconPath = Join-Path $Script:RepoRoot "icon.ico"
$Script:BrandImagePath = Join-Path $Script:RepoRoot "icon.png"
$Script:CurrentProcess = $null
$Script:IsRunning = $false
$Script:IsCanceled = $false
$Script:PhaseIndex = 0
$Script:LastReportPath = $null
$Script:LastLogPath = $null
$Script:LastUndoPath = $null
$Script:OutputCapture = $null
$Script:OutputTimer = $null
$Script:RunCompletionHandled = $false
$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="NuclearOEMRemover"
    Width="1180"
    Height="760"
    MinWidth="980"
    MinHeight="720"
    WindowStartupLocation="CenterScreen"
    Background="#0B0F17"
    FontFamily="Segoe UI"
    TextOptions.TextFormattingMode="Display"
    TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>
    <SolidColorBrush x:Key="PageBg" Color="#0B0F17"/>
    <SolidColorBrush x:Key="PanelBg" Color="#111827"/>
    <SolidColorBrush x:Key="RaisedBg" Color="#162033"/>
    <SolidColorBrush x:Key="Line" Color="#2D3748"/>
    <SolidColorBrush x:Key="LineSoft" Color="#1F2937"/>
    <SolidColorBrush x:Key="Text" Color="#EDF2F7"/>
    <SolidColorBrush x:Key="Muted" Color="#9AA7B7"/>
    <SolidColorBrush x:Key="Faint" Color="#6B7788"/>
    <SolidColorBrush x:Key="Accent" Color="#66A6FF"/>
    <SolidColorBrush x:Key="AccentDark" Color="#25466F"/>
    <SolidColorBrush x:Key="Success" Color="#5EE2A0"/>
    <SolidColorBrush x:Key="Warning" Color="#F6C768"/>
    <SolidColorBrush x:Key="Danger" Color="#FF6B6B"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>

    <Style x:Key="EyebrowText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="TextWrapping" Value="NoWrap"/>
    </Style>

    <Style x:Key="SectionLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="MinHeight" Value="38"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="BorderBrush" Value="#7DB6FF"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="#07111F"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Root" CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Root" Property="Background" Value="#7DB6FF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Root" Property="Background" Value="#4D91E8"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Root" Property="BorderBrush" Value="#C9E0FF"/>
                <Setter TargetName="Root" Property="BorderThickness" Value="2"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Root" Property="Opacity" Value=".48"/>
                <Setter Property="Cursor" Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
      <Setter Property="Background" Value="#141E2F"/>
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#1B2A42"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
      <Setter Property="Background" Value="#FF6B6B"/>
      <Setter Property="Foreground" Value="#160506"/>
      <Setter Property="BorderBrush" Value="#FF9A9A"/>
    </Style>

    <Style x:Key="SegmentRadio" TargetType="RadioButton">
      <Setter Property="MinHeight" Value="34"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Root" CornerRadius="8" Background="#101827" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Root" Property="BorderBrush" Value="{StaticResource Line}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Root" Property="Background" Value="{StaticResource AccentDark}"/>
                <Setter TargetName="Root" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="{StaticResource Text}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Root" Property="BorderBrush" Value="#C9E0FF"/>
                <Setter TargetName="Root" Property="BorderThickness" Value="2"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PolishedCheck" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
  </Window.Resources>

  <Grid Background="{StaticResource PageBg}">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#0E1522" BorderBrush="{StaticResource LineSoft}" BorderThickness="0,0,0,1" Padding="24,18">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Width="52" Height="52" CornerRadius="10" Background="#121D2E" BorderBrush="{StaticResource Line}" BorderThickness="1" Margin="0,0,16,0">
          <Image x:Name="BrandImage" Width="40" Height="40" Stretch="Uniform"/>
        </Border>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock Style="{StaticResource EyebrowText}" Text="OEM CLEANUP CONTROL SURFACE"/>
          <TextBlock Text="NuclearOEMRemover" FontSize="30" FontWeight="SemiBold" Margin="0,3,0,0"/>
          <TextBlock Text="Run a safe audit first, then remove OEM software with a clean report trail." Foreground="{StaticResource Muted}" FontSize="14" Margin="0,4,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="2" VerticalAlignment="Center" HorizontalAlignment="Right">
          <Grid HorizontalAlignment="Right">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Ellipse Width="8" Height="8" Fill="{StaticResource Success}" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock Grid.Column="1" Text="Administrator" Foreground="{StaticResource Text}" FontWeight="SemiBold" FontSize="13"/>
          </Grid>
          <TextBlock x:Name="HeaderStatus" Text="Ready" Foreground="{StaticResource Muted}" FontSize="12" HorizontalAlignment="Right" Margin="0,8,0,0"/>
        </StackPanel>
      </Grid>
    </Border>

    <Grid Grid.Row="1" Margin="22">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="350"/>
        <ColumnDefinition Width="20"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="{StaticResource PanelBg}" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" CornerRadius="8">
        <Grid Margin="18">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <StackPanel Grid.Row="0">
            <TextBlock Text="Target" Style="{StaticResource SectionLabel}"/>
            <WrapPanel Margin="0,0,0,8">
              <RadioButton x:Name="AutoRadio" Style="{StaticResource SegmentRadio}" Content="Auto" IsChecked="True" GroupName="OEM"/>
              <RadioButton x:Name="DellRadio" Style="{StaticResource SegmentRadio}" Content="Dell" GroupName="OEM"/>
              <RadioButton x:Name="HPRadio" Style="{StaticResource SegmentRadio}" Content="HP" GroupName="OEM"/>
              <RadioButton x:Name="LenovoRadio" Style="{StaticResource SegmentRadio}" Content="Lenovo" GroupName="OEM"/>
              <RadioButton x:Name="AllRadio" Style="{StaticResource SegmentRadio}" Content="All" GroupName="OEM"/>
            </WrapPanel>
          </StackPanel>

          <Border Grid.Row="1" Height="1" Background="{StaticResource LineSoft}" Margin="0,2,0,14"/>

          <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" MaxHeight="360">
          <StackPanel>
            <TextBlock Text="Run Options" Style="{StaticResource SectionLabel}"/>
            <CheckBox x:Name="DryRunCheck" Style="{StaticResource PolishedCheck}" IsChecked="True" Content="Dry run first"/>
            <TextBlock Text="Recommended no-change audit." Foreground="{StaticResource Faint}" FontSize="12" Margin="24,-6,0,10"/>

            <CheckBox x:Name="BlockReinstallCheck" Style="{StaticResource PolishedCheck}" IsChecked="True" Content="Block automatic OEM reinstall"/>
            <TextBlock Text="Applies Windows policy settings." Foreground="{StaticResource Faint}" FontSize="12" Margin="24,-6,0,10"/>

            <CheckBox x:Name="FilesystemCheck" Style="{StaticResource PolishedCheck}" IsChecked="True" Content="Clean filesystem remnants"/>
            <TextBlock Text="Removes folders and Start Menu leftovers." Foreground="{StaticResource Faint}" FontSize="12" Margin="24,-6,0,10"/>

            <CheckBox x:Name="ResidueCheck" Style="{StaticResource PolishedCheck}" IsChecked="True" Content="Clear residue (drivers, firewall, Defender, BITS)"/>
            <TextBlock Text="Drops OEM INFs, rules, and queued transfers." Foreground="{StaticResource Faint}" FontSize="12" Margin="24,-6,0,10"/>

            <CheckBox x:Name="KeepDCUCheck" Style="{StaticResource PolishedCheck}" Content="Keep Dell Command Update (silenced)"/>
            <TextBlock Text="Preserves DCU for BIOS/drivers, silences popups." Foreground="{StaticResource Faint}" FontSize="12" Margin="24,-6,0,10"/>

            <CheckBox x:Name="ForceCheck" Style="{StaticResource PolishedCheck}" Content="Force (bypass SupportAssist version gate)"/>
            <TextBlock Text="Removes SupportAssist even if a recent version." Foreground="{StaticResource Faint}" FontSize="12" Margin="24,-6,0,10"/>

            <CheckBox x:Name="RestorePointCheck" Style="{StaticResource PolishedCheck}" IsChecked="True" Content="Create restore point before live run"/>
            <TextBlock Text="Safety net. Skipped in dry-run mode." Foreground="{StaticResource Faint}" FontSize="12" Margin="24,-6,0,10"/>

            <CheckBox x:Name="OpenReportCheck" Style="{StaticResource PolishedCheck}" IsChecked="True" Content="Open report when complete"/>
          </StackPanel>
          </ScrollViewer>

          <Border Grid.Row="3" Height="1" Background="{StaticResource LineSoft}" Margin="0,8,0,14"/>

          <StackPanel Grid.Row="4">
            <TextBlock Text="Run Summary" Style="{StaticResource SectionLabel}"/>
            <Border Background="#0B111D" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" CornerRadius="8" Padding="10" Margin="0,0,0,0">
                <TextBlock x:Name="RunSummary" FontFamily="Consolas" FontSize="12" Foreground="{StaticResource Muted}" TextWrapping="Wrap"/>
            </Border>
          </StackPanel>

          <StackPanel Grid.Row="6">
            <Button x:Name="StartButton" Style="{StaticResource PrimaryButton}" Content="Start Dry Run" Margin="0,0,0,8"/>
            <Button x:Name="StopButton" Style="{StaticResource DangerButton}" Content="Stop Run" IsEnabled="False" Margin="0,0,0,8"/>

            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Button x:Name="OpenReportButton" Grid.Column="0" Style="{StaticResource SecondaryButton}" Content="Open Report" IsEnabled="False"/>
              <Button x:Name="OpenLogButton" Grid.Column="2" Style="{StaticResource SecondaryButton}" Content="Open Log" IsEnabled="False"/>
            </Grid>
          </StackPanel>
        </Grid>
      </Border>

      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="170"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="{StaticResource PanelBg}" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" CornerRadius="8" Padding="20" Margin="0,0,0,18">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="220"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
              <TextBlock x:Name="StatusTitle" Text="Ready for dry run" FontSize="22" FontWeight="SemiBold"/>
              <TextBlock x:Name="StatusBody" Text="Choose an OEM target, review the run summary, then start with a no-change audit." Foreground="{StaticResource Muted}" FontSize="13" Margin="0,6,0,0"/>
            </StackPanel>
            <StackPanel Grid.Column="1" VerticalAlignment="Center">
              <ProgressBar x:Name="RunProgress" Height="8" Minimum="0" Maximum="100" Value="0" Background="#0B111D" Foreground="{StaticResource Accent}"/>
              <TextBlock x:Name="ProgressLabel" Text="0%" Foreground="{StaticResource Faint}" FontSize="12" HorizontalAlignment="Right" Margin="0,8,0,0"/>
            </StackPanel>
          </Grid>
        </Border>

        <Border Grid.Row="1" Background="{StaticResource PanelBg}" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" CornerRadius="8" Padding="18" Margin="0,0,0,18">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TextBlock Text="Cleanup Phases" Style="{StaticResource SectionLabel}"/>
            <UniformGrid Grid.Row="1" Columns="5" Rows="2" Margin="0,8,0,0">
              <Border x:Name="PhaseProcesses" CornerRadius="8" Background="#0F1726" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" Padding="10" Margin="0,0,8,8">
                <TextBlock Text="Processes" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource Muted}" FontWeight="SemiBold"/>
              </Border>
              <Border x:Name="PhaseServices" CornerRadius="8" Background="#0F1726" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" Padding="10" Margin="0,0,8,8">
                <TextBlock Text="Services" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource Muted}" FontWeight="SemiBold"/>
              </Border>
              <Border x:Name="PhaseAppx" CornerRadius="8" Background="#0F1726" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" Padding="10" Margin="0,0,8,8">
                <TextBlock Text="AppX" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource Muted}" FontWeight="SemiBold"/>
              </Border>
              <Border x:Name="PhaseWin32" CornerRadius="8" Background="#0F1726" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" Padding="10" Margin="0,0,8,8">
                <TextBlock Text="Win32" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource Muted}" FontWeight="SemiBold"/>
              </Border>
              <Border x:Name="PhaseTasks" CornerRadius="8" Background="#0F1726" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" Padding="10" Margin="0,0,0,8">
                <TextBlock Text="Tasks" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource Muted}" FontWeight="SemiBold"/>
              </Border>
              <Border x:Name="PhaseRegistry" CornerRadius="8" Background="#0F1726" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" Padding="10" Margin="0,0,8,0">
                <TextBlock Text="Registry" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource Muted}" FontWeight="SemiBold"/>
              </Border>
              <Border x:Name="PhaseFilesystem" CornerRadius="8" Background="#0F1726" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" Padding="10" Margin="0,0,8,0">
                <TextBlock Text="Files" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource Muted}" FontWeight="SemiBold"/>
              </Border>
              <Border x:Name="PhaseReinstall" CornerRadius="8" Background="#0F1726" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" Padding="10" Margin="0,0,8,0">
                <TextBlock Text="Reinstall" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource Muted}" FontWeight="SemiBold"/>
              </Border>
              <Border x:Name="PhaseVerify" CornerRadius="8" Background="#0F1726" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" Padding="10" Margin="0,0,8,0">
                <TextBlock Text="Verify" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource Muted}" FontWeight="SemiBold"/>
              </Border>
              <Border x:Name="PhaseReport" CornerRadius="8" Background="#0F1726" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" Padding="10">
                <TextBlock Text="Report" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource Muted}" FontWeight="SemiBold"/>
              </Border>
            </UniformGrid>
          </Grid>
        </Border>

        <Border Grid.Row="2" Background="{StaticResource PanelBg}" BorderBrush="{StaticResource LineSoft}" BorderThickness="1" CornerRadius="8" Padding="0">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border BorderBrush="{StaticResource LineSoft}" BorderThickness="0,0,0,1" Padding="18,14">
              <Grid>
                <TextBlock Text="Run Log" Style="{StaticResource SectionLabel}" Margin="0"/>
                <TextBlock x:Name="ReportPathText" Text="No report yet" Foreground="{StaticResource Faint}" FontSize="12" HorizontalAlignment="Right"/>
              </Grid>
            </Border>
            <TextBox x:Name="LogBox" Grid.Row="1" Background="#090D14" Foreground="#C9D8EA" BorderThickness="0" FontFamily="Consolas" FontSize="12" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="16"/>
          </Grid>
        </Border>
      </Grid>
    </Grid>

    <Border Grid.Row="2" Background="#090D14" BorderBrush="{StaticResource LineSoft}" BorderThickness="0,1,0,0" Padding="18,10">
      <TextBlock x:Name="FooterStatus" Text="Ready. Dry run is selected by default." Foreground="{StaticResource Faint}" FontSize="12"/>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

if (Test-Path $Script:IconPath) {
    $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$Script:IconPath)
}

$controlNames = @(
    "BrandImage", "HeaderStatus", "AutoRadio", "DellRadio", "HPRadio", "LenovoRadio", "AllRadio",
    "DryRunCheck", "BlockReinstallCheck", "FilesystemCheck", "ResidueCheck",
    "KeepDCUCheck", "ForceCheck", "RestorePointCheck", "OpenReportCheck", "RunSummary",
    "StartButton", "StopButton", "OpenReportButton", "OpenLogButton", "StatusTitle", "StatusBody",
    "RunProgress", "ProgressLabel", "LogBox", "ReportPathText", "FooterStatus",
    "PhaseProcesses", "PhaseServices", "PhaseAppx", "PhaseWin32", "PhaseTasks",
    "PhaseRegistry", "PhaseFilesystem", "PhaseReinstall", "PhaseVerify", "PhaseReport"
)

$ui = @{}
foreach ($name in $controlNames) {
    $ctl = $window.FindName($name)
    if (-not $ctl) {
        throw "GUI initialization failed: control '$name' not found in XAML. Check for a typo in controlNames or the window markup."
    }
    $ui[$name] = $ctl
}

# Null/missing-safe checkbox read - under Set-StrictMode -Version 2.0 a null property throws.
# Use this whenever reading .IsChecked on a control we added later in the UI.
function Get-CheckState {
    param([object]$Control, [bool]$Default = $false)
    if (-not $Control) { return $Default }
    $val = $Control.IsChecked
    if ($null -eq $val) { return $Default }
    return [bool]$val
}

if (Test-Path $Script:BrandImagePath) {
    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = [Uri]$Script:BrandImagePath
    $bitmap.EndInit()
    $ui.BrandImage.Source = $bitmap
}

$Script:PhaseControls = @(
    $ui.PhaseProcesses,
    $ui.PhaseServices,
    $ui.PhaseAppx,
    $ui.PhaseWin32,
    $ui.PhaseTasks,
    $ui.PhaseRegistry,
    $ui.PhaseFilesystem,
    $ui.PhaseReinstall,
    $ui.PhaseVerify,
    $ui.PhaseReport
)

function New-SolidBrush {
    param([string]$Color)
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Color))
}

$Brushes = @{
    PhaseIdleBorder = New-SolidBrush "#1F2937"
    PhaseIdleBg     = New-SolidBrush "#0F1726"
    PhaseActiveBg   = New-SolidBrush "#25466F"
    PhaseActiveLine = New-SolidBrush "#66A6FF"
    PhaseDoneBg     = New-SolidBrush "#143425"
    PhaseDoneLine   = New-SolidBrush "#5EE2A0"
    PhaseText       = New-SolidBrush "#EDF2F7"
    PhaseMuted      = New-SolidBrush "#9AA7B7"
}

function Set-PhaseVisual {
    param(
        [System.Windows.Controls.Border]$Control,
        [ValidateSet("Idle", "Active", "Done")]
        [string]$State
    )

    switch ($State) {
        "Idle" {
            $Control.Background = $Brushes.PhaseIdleBg
            $Control.BorderBrush = $Brushes.PhaseIdleBorder
            $Control.Child.Foreground = $Brushes.PhaseMuted
        }
        "Active" {
            $Control.Background = $Brushes.PhaseActiveBg
            $Control.BorderBrush = $Brushes.PhaseActiveLine
            $Control.Child.Foreground = $Brushes.PhaseText
        }
        "Done" {
            $Control.Background = $Brushes.PhaseDoneBg
            $Control.BorderBrush = $Brushes.PhaseDoneLine
            $Control.Child.Foreground = $Brushes.PhaseText
        }
    }
}

function Reset-Phases {
    $Script:PhaseIndex = 0
    foreach ($phase in $Script:PhaseControls) {
        Set-PhaseVisual -Control $phase -State Idle
    }
}

function Set-PhaseIndex {
    param([int]$Index)

    if ($Index -lt 1) { return }
    if ($Index -gt $Script:PhaseControls.Count) { $Index = $Script:PhaseControls.Count }
    if ($Index -le $Script:PhaseIndex) { return }

    for ($i = 0; $i -lt $Script:PhaseControls.Count; $i++) {
        if ($i -lt ($Index - 1)) {
            Set-PhaseVisual -Control $Script:PhaseControls[$i] -State Done
        } elseif ($i -eq ($Index - 1)) {
            Set-PhaseVisual -Control $Script:PhaseControls[$i] -State Active
        } else {
            Set-PhaseVisual -Control $Script:PhaseControls[$i] -State Idle
        }
    }

    $Script:PhaseIndex = $Index
    $percent = [Math]::Min(95, [Math]::Round(($Index - 1) / [Math]::Max(1, ($Script:PhaseControls.Count - 1)) * 100))
    $ui.RunProgress.Value = $percent
    $ui.ProgressLabel.Text = "$percent%"
}

function Complete-Phases {
    foreach ($phase in $Script:PhaseControls) {
        Set-PhaseVisual -Control $phase -State Done
    }

    $ui.RunProgress.Value = 100
    $ui.ProgressLabel.Text = "100%"
}

function Add-LogLine {
    param([string]$Line)

    $ui.LogBox.AppendText($Line + [Environment]::NewLine)
    $ui.LogBox.ScrollToEnd()
}

function Receive-ProcessOutput {
    if (-not $Script:OutputCapture) { return }

    $line = $null
    while ($Script:OutputCapture.TryDequeueOutput([ref]$line)) {
        Add-LogLine $line
        Update-RunStateFromLine $line
        $line = $null
    }

    while ($Script:OutputCapture.TryDequeueError([ref]$line)) {
        Add-LogLine "[stderr] $line"
        $line = $null
    }
}

function Stop-OutputTimer {
    if ($Script:OutputTimer) {
        $Script:OutputTimer.Stop()
        $Script:OutputTimer = $null
    }
}

function Open-LocalArtifact {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$FilePath,
        [string]$ArgumentList
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-LogLine "[GUI] File not found: $Path"
        return
    }

    try {
        if ($FilePath) {
            if ($ArgumentList) {
                Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -ErrorAction Stop
            } else {
                Start-Process -FilePath $FilePath -ErrorAction Stop
            }
        } else {
            Start-Process -FilePath $Path -ErrorAction Stop
        }
    } catch {
        Add-LogLine "[GUI] Could not open file: $($_.Exception.Message)"
    }
}

function Get-SelectedOEM {
    if ($ui.DellRadio.IsChecked) { return "Dell" }
    if ($ui.HPRadio.IsChecked) { return "HP" }
    if ($ui.LenovoRadio.IsChecked) { return "Lenovo" }
    if ($ui.AllRadio.IsChecked) { return "All" }
    return $null
}

function Get-RunArguments {
    $argumentList = New-Object System.Collections.Generic.List[string]
    $argumentList.Add("-NoProfile")
    $argumentList.Add("-ExecutionPolicy")
    $argumentList.Add("Bypass")
    $argumentList.Add("-File")
    $argumentList.Add($Script:ScriptPath)
    $argumentList.Add("-InternalEngine")
    $argumentList.Add("-NoOpenReport")
    $argumentList.Add("-NoClearHost")

    $selectedOEM = Get-SelectedOEM
    if ($selectedOEM) {
        $argumentList.Add("-OEM")
        $argumentList.Add($selectedOEM)
    }

    if (Get-CheckState $ui.DryRunCheck)                 { $argumentList.Add("-DryRun") }
    if (-not (Get-CheckState $ui.BlockReinstallCheck -Default $true)) { $argumentList.Add("-SkipReinstallBlock") }
    if (-not (Get-CheckState $ui.FilesystemCheck     -Default $true)) { $argumentList.Add("-SkipFilesystemCleanup") }
    if (-not (Get-CheckState $ui.ResidueCheck        -Default $true)) { $argumentList.Add("-SkipResidueCleanup") }
    if (Get-CheckState $ui.KeepDCUCheck)               { $argumentList.Add("-KeepDellCommandUpdate") }
    if (Get-CheckState $ui.ForceCheck)                 { $argumentList.Add("-Force") }
    if (-not (Get-CheckState $ui.RestorePointCheck   -Default $true)) { $argumentList.Add("-SkipRestorePoint") }

    $argumentList.Add("-LogPath")
    $argumentList.Add($Script:LastLogPath)
    $argumentList.Add("-ReportPath")
    $argumentList.Add($Script:LastReportPath)
    $argumentList.Add("-UndoManifestPath")
    $argumentList.Add($Script:LastUndoPath)

    return $argumentList.ToArray()
}

function Format-RunSummary {
    $selectedOEM = Get-SelectedOEM
    if (-not $selectedOEM) { $selectedOEM = "Auto" }

    $mode       = if (Get-CheckState $ui.DryRunCheck)                        { "Dry Run" }         else { "Live Cleanup" }
    $reinstall  = if (Get-CheckState $ui.BlockReinstallCheck -Default $true) { "On" }              else { "Off" }
    $filesystem = if (Get-CheckState $ui.FilesystemCheck     -Default $true) { "On" }              else { "Off" }
    $residue    = if (Get-CheckState $ui.ResidueCheck        -Default $true) { "On" }              else { "Off" }
    $keepDcu    = if (Get-CheckState $ui.KeepDCUCheck)                       { "Keep DCU" }        else { "Remove DCU" }
    $force      = if (Get-CheckState $ui.ForceCheck)                         { "Force on" }        else { "Gated" }
    $restore    = if (Get-CheckState $ui.RestorePointCheck   -Default $true) { "Restore-point on" } else { "No restore point" }

    $parts = @(
        "Target: $selectedOEM",
        "Mode: $mode",
        "Reinstall block: $reinstall",
        "Filesystem: $filesystem",
        "Residue: $residue",
        $keepDcu,
        $force,
        $restore
    )

    return ($parts -join " | ")
}

function Update-RunSummary {
    $ui.RunSummary.Text = Format-RunSummary

    if (Get-CheckState $ui.DryRunCheck) {
        $ui.StartButton.Content = "Start Dry Run"
        $ui.StatusTitle.Text = "Ready for dry run"
        $ui.StatusBody.Text = "Choose an OEM target, review the run summary, then start with a no-change audit."
    } else {
        $ui.StartButton.Content = "Start Live Cleanup"
        $ui.StatusTitle.Text = "Live cleanup selected"
        $ui.StatusBody.Text = "This will remove matching OEM software. A confirmation appears before launch."
    }
}

function ConvertTo-ProcessArgument {
    param([string]$Argument)

    if ($Argument -notmatch '[\s"`]') { return $Argument }
    return '"' + ($Argument -replace '"', '\"') + '"'
}

function Update-RunStateFromLine {
    param([string]$Line)

    if ($Line -match "PHASE 1:") { Set-PhaseIndex 1; return }
    if ($Line -match "PHASE 2:") { Set-PhaseIndex 2; return }
    if ($Line -match "PHASE 3:") { Set-PhaseIndex 3; return }
    if ($Line -match "PHASE 4:") { Set-PhaseIndex 4; return }
    if ($Line -match "PHASE 5:") { Set-PhaseIndex 5; return }
    if ($Line -match "PHASE 6:") { Set-PhaseIndex 6; return }
    if ($Line -match "PHASE 7:") { Set-PhaseIndex 7; return }
    if ($Line -match "PHASE 8:") { Set-PhaseIndex 8; return }
    if ($Line -match "PHASE 9:") { Set-PhaseIndex 8; return }  # Residue maps to Reinstall tile
    if ($Line -match "VERIFICATION:") { Set-PhaseIndex 9; return }
    if ($Line -match "HTML report saved to:") { Set-PhaseIndex 10; return }
}

function Set-RunningState {
    param([bool]$Running)

    $Script:IsRunning = $Running
    $ui.StartButton.IsEnabled = -not $Running
    $ui.StopButton.IsEnabled = $Running
    $ui.OpenReportButton.IsEnabled = (-not $Running -and $Script:LastReportPath -and (Test-Path $Script:LastReportPath))
    $ui.OpenLogButton.IsEnabled = (-not $Running -and $Script:LastLogPath -and (Test-Path $Script:LastLogPath))

    foreach ($control in @(
        $ui.AutoRadio, $ui.DellRadio, $ui.HPRadio, $ui.LenovoRadio, $ui.AllRadio,
        $ui.DryRunCheck, $ui.BlockReinstallCheck, $ui.FilesystemCheck, $ui.ResidueCheck,
        $ui.KeepDCUCheck, $ui.ForceCheck, $ui.RestorePointCheck, $ui.OpenReportCheck
    )) {
        $control.IsEnabled = -not $Running
    }
}

function Complete-Run {
    param([int]$ExitCode)

    if ($Script:RunCompletionHandled) { return }
    $Script:RunCompletionHandled = $true
    Stop-OutputTimer
    Receive-ProcessOutput

    Set-RunningState $false

    if ($Script:IsCanceled) {
        $ui.StatusTitle.Text = "Run stopped"
        $ui.StatusBody.Text = "The cleanup process was stopped by the operator."
        $ui.HeaderStatus.Text = "Stopped"
        $ui.FooterStatus.Text = "Run stopped. Review the log before starting again."
        Add-LogLine "[GUI] Run stopped by operator."
        return
    }

    if ($ExitCode -eq 0) {
        Complete-Phases
        $mode = if ((Get-CheckState $ui.DryRunCheck)) { "Dry run" } else { "Cleanup" }
        $ui.StatusTitle.Text = "$mode complete"
        $ui.StatusBody.Text = "Review the report for phase counts, verification state, and detailed results."
        $ui.HeaderStatus.Text = "Complete"
        $ui.FooterStatus.Text = "Complete. Report and log are ready."
        Add-LogLine "[GUI] Process completed successfully."

        if ((Get-CheckState $ui.OpenReportCheck -Default $true) -and $Script:LastReportPath -and (Test-Path $Script:LastReportPath)) {
            Open-LocalArtifact -Path $Script:LastReportPath
        }
    } else {
        $ui.StatusTitle.Text = "Run finished with issues"
        $ui.StatusBody.Text = "The cleanup process returned exit code $ExitCode. Review the log and report if available."
        $ui.HeaderStatus.Text = "Needs review"
        $ui.FooterStatus.Text = "Run returned exit code $ExitCode."
        Add-LogLine "[GUI] Process exited with code $ExitCode."
    }

    $ui.ReportPathText.Text = if ($Script:LastReportPath) { $Script:LastReportPath } else { "No report yet" }
    $ui.OpenReportButton.IsEnabled = ($Script:LastReportPath -and (Test-Path $Script:LastReportPath))
    $ui.OpenLogButton.IsEnabled = ($Script:LastLogPath -and (Test-Path $Script:LastLogPath))

    try {
        if ($Script:CurrentProcess) {
            $Script:CurrentProcess.Dispose()
        }
    } catch {
        Add-LogLine "[GUI] Could not dispose cleanup process handle: $($_.Exception.Message)"
    }

    $Script:CurrentProcess = $null
    $Script:OutputCapture = $null
}

function Start-Run {
    if ($Script:IsRunning) { return }

    if (-not (Get-CheckState $ui.DryRunCheck)) {
        $message = "Live cleanup will remove matching OEM applications, services, tasks, registry entries, and files.`n`nRun a dry run first unless you already reviewed the expected changes."
        $confirm = [System.Windows.MessageBox]::Show(
            $window,
            $message,
            "Start Live Cleanup?",
            [System.Windows.MessageBoxButton]::OKCancel,
            [System.Windows.MessageBoxImage]::Warning
        )

        if ($confirm -ne [System.Windows.MessageBoxResult]::OK) { return }
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $Script:LastLogPath = Join-Path $env:TEMP "NuclearOEMRemover-$timestamp.log"
    $Script:LastReportPath = Join-Path $env:TEMP "NuclearOEMRemover-Report-$timestamp.html"
    $Script:LastUndoPath = Join-Path $env:TEMP "NuclearOEMRemover-Undo-$timestamp.json"
    $Script:IsCanceled = $false
    $Script:RunCompletionHandled = $false
    $Script:OutputCapture = [NuclearOEMRemover.ProcessOutputCapture]::new()

    Reset-Phases
    $ui.LogBox.Clear()
    $ui.RunProgress.Value = 0
    $ui.ProgressLabel.Text = "0%"
    $ui.ReportPathText.Text = $Script:LastReportPath
    $ui.HeaderStatus.Text = "Running"
    $ui.StatusTitle.Text = if ((Get-CheckState $ui.DryRunCheck)) { "Dry run in progress" } else { "Live cleanup in progress" }
    $ui.StatusBody.Text = "Output is streaming below. Keep this window open until the report is generated."
    $ui.FooterStatus.Text = "Running. Report will be written to $Script:LastReportPath"
    Set-RunningState $true

    Add-LogLine "[GUI] Run summary: $(Format-RunSummary)"
    Add-LogLine "[GUI] Report: $Script:LastReportPath"
    Add-LogLine "[GUI] Log: $Script:LastLogPath"
    Add-LogLine ""

    $runArgs = Get-RunArguments
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = (($runArgs | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " ")
    $psi.WorkingDirectory = $Script:RepoRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    $outputHandler = [System.Diagnostics.DataReceivedEventHandler]$Script:OutputCapture.OnOutputDataReceived
    $errorHandler = [System.Diagnostics.DataReceivedEventHandler]$Script:OutputCapture.OnErrorDataReceived

    $process.add_OutputDataReceived($outputHandler)
    $process.add_ErrorDataReceived($errorHandler)

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $timer.Add_Tick({
        Receive-ProcessOutput

        if ($Script:IsRunning -and $Script:CurrentProcess -and $Script:CurrentProcess.HasExited) {
            try {
                $Script:CurrentProcess.WaitForExit()
            } catch {
                Add-LogLine "[GUI] Could not finish reading process output cleanly: $($_.Exception.Message)"
            }
            Receive-ProcessOutput
            Complete-Run -ExitCode $Script:CurrentProcess.ExitCode
        }
    })
    $Script:OutputTimer = $timer

    try {
        [void]$process.Start()
        $Script:CurrentProcess = $process
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        $Script:OutputTimer.Start()
    } catch {
        Stop-OutputTimer
        $Script:CurrentProcess = $null
        $Script:OutputCapture = $null
        Set-RunningState $false
        $ui.StatusTitle.Text = "Could not start"
        $ui.StatusBody.Text = $_.Exception.Message
        $ui.HeaderStatus.Text = "Launch failed"
        Add-LogLine "[GUI] Failed to launch cleanup process: $($_.Exception.Message)"
    }
}

function Stop-Run {
    if (-not $Script:IsRunning -or -not $Script:CurrentProcess) { return }

    $confirm = [System.Windows.MessageBox]::Show(
        $window,
        "Stop the current run? Partial cleanup may already have occurred if this is a live run.",
        "Stop Run?",
        [System.Windows.MessageBoxButton]::OKCancel,
        [System.Windows.MessageBoxImage]::Warning
    )

    if ($confirm -ne [System.Windows.MessageBoxResult]::OK) { return }

    $Script:IsCanceled = $true
    try {
        if (-not $Script:CurrentProcess.HasExited) {
            $Script:CurrentProcess.Kill()
        }
    } catch {
        Add-LogLine "[GUI] Failed to stop process: $($_.Exception.Message)"
    }
}

function Open-Report {
    if ($Script:LastReportPath) {
        Open-LocalArtifact -Path $Script:LastReportPath
    }
}

function Open-Log {
    if ($Script:LastLogPath) {
        Open-LocalArtifact -Path $Script:LastLogPath -FilePath "notepad.exe" -ArgumentList "`"$Script:LastLogPath`""
    }
}

foreach ($control in @(
    $ui.AutoRadio, $ui.DellRadio, $ui.HPRadio, $ui.LenovoRadio, $ui.AllRadio,
    $ui.DryRunCheck, $ui.BlockReinstallCheck, $ui.FilesystemCheck, $ui.ResidueCheck,
    $ui.KeepDCUCheck, $ui.ForceCheck, $ui.RestorePointCheck
)) {
    $control.Add_Click({ Update-RunSummary })
}

$ui.StartButton.Add_Click({ Start-Run })
$ui.StopButton.Add_Click({ Stop-Run })
$ui.OpenReportButton.Add_Click({ Open-Report })
$ui.OpenLogButton.Add_Click({ Open-Log })

$window.Add_Closing({
    param($closeSource, $closingEventArgs)
    $null = $closeSource

    if ($Script:IsRunning -and $Script:CurrentProcess -and -not $Script:CurrentProcess.HasExited) {
        $confirm = [System.Windows.MessageBox]::Show(
            $window,
            "A cleanup run is still active. Stop it and close the GUI?",
            "Run Still Active",
            [System.Windows.MessageBoxButton]::OKCancel,
            [System.Windows.MessageBoxImage]::Warning
        )

        if ($confirm -ne [System.Windows.MessageBoxResult]::OK) {
            $closingEventArgs.Cancel = $true
            return
        }

        $Script:IsCanceled = $true
        try {
            $Script:CurrentProcess.Kill()
        } catch {
            Add-LogLine "[GUI] Failed to stop process while closing: $($_.Exception.Message)"
        }
        Stop-OutputTimer
    }
})

Reset-Phases
Update-RunSummary

[void]$window.ShowDialog()
