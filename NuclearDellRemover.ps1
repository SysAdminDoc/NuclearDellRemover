<#
.SYNOPSIS
    NuclearOEMRemover - Complete OEM Bloatware Elimination (Dell, HP, Lenovo)
.DESCRIPTION
    Scorched earth removal of ALL OEM pre-installed software from Windows 11.
    Removes AppX packages, Win32 applications, services, scheduled tasks,
    registry entries, and filesystem remnants. Blocks automatic reinstallation
    via Windows policies (reversible).

    Supports Dell, HP, and Lenovo with auto-detection or manual override.
    Filename kept as NuclearDellRemover.ps1 for backwards compatibility.
.NOTES
    Author: Matt
    Version: 1.1.0
    Requires: Administrator privileges
    Target: Windows 11
.EXAMPLE
    .\NuclearDellRemover.ps1
    .\NuclearDellRemover.ps1 -DryRun
    .\NuclearDellRemover.ps1 -OEM HP
    .\NuclearDellRemover.ps1 -OEM All -DryRun
    .\NuclearDellRemover.ps1 -SkipReinstallBlock
    .\NuclearDellRemover.ps1 -Verbose
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$SkipReinstallBlock,
    [switch]$SkipFilesystemCleanup,
    [switch]$DryRun,
    [ValidateSet("Dell", "HP", "Lenovo", "All")]
    [string]$OEM,
    [string]$LogPath = "$env:TEMP\NuclearOEMRemover.log"
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$Script:Config = @{
    Version   = "1.1.0"
    StartTime = Get-Date
}

# ============================================================================
# OEM TARGET DEFINITIONS
# ============================================================================

$Script:OEMTargets = @{
    Dell = @{
        ProcessPatterns = @("*Dell*", "*SupportAssist*", "*DDV*", "*PCDR*", "*Alienware*")
        ServicePatterns = @("*Dell*", "*SupportAssist*", "*DDV*", "*PCDR*")
        ServiceNames    = @(
            "DellSupportAssistAgent", "Dell SupportAssist Remediation",
            "DDVDataCollector", "DDVRulesProcessor", "DDVCollectorSvcApi",
            "DellOptimizerService", "DellPowerManager", "DellUpdate",
            "DellClientManagementService", "DellTechHub", "DellAnalytics",
            "SupportAssistAgent", "DCHS", "DellDigitalDelivery"
        )
        AppxPatterns    = @("*Dell*", "*DellInc*", "*WavesAudio.MaxxAudio*")
        Win32Patterns   = @("*Dell*", "*SupportAssist*", "*Alienware*")
        WingetApps      = @(
            "Dell SupportAssist", "Dell Command | Update", "Dell Digital Delivery",
            "Dell Power Manager", "Dell Optimizer", "Dell Display Manager",
            "Alienware Command Center"
        )
        TaskPatterns    = @("*Dell*", "*SupportAssist*", "*PCDoctor*", "*PCDR*")
        TaskFolders     = @("Dell")
        RegistryPaths   = @(
            "HKLM:\SOFTWARE\Dell", "HKLM:\SOFTWARE\Wow6432Node\Dell",
            "HKLM:\SOFTWARE\PC-Doctor", "HKCU:\SOFTWARE\Dell",
            "HKCU:\SOFTWARE\PC-Doctor"
        )
        RunKeyPatterns  = @("*Dell*")
        FilesystemPaths = @(
            "$env:ProgramData\Dell", "$env:ProgramData\PCDR",
            "$env:ProgramData\SupportAssist", "$env:ProgramData\PC-Doctor",
            "$env:ProgramData\DDVDataCollector", "$env:LOCALAPPDATA\Dell",
            "$env:APPDATA\Dell", "$env:APPDATA\PCDR",
            "C:\Program Files\Dell", "C:\Program Files (x86)\Dell",
            "C:\Program Files\PC-Doctor", "C:\Program Files (x86)\PC-Doctor",
            "C:\Dell"
        )
        StartMenuPatterns = @("*Dell*")
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
    }
}

# ============================================================================
# OEM AUTO-DETECTION
# ============================================================================

function Get-DetectedOEM {
    $manufacturer = (Get-CimInstance Win32_ComputerSystem).Manufacturer
    Write-Log "Detected manufacturer: $manufacturer" -Level INFO

    if ($manufacturer -match "Dell") { return "Dell" }
    if ($manufacturer -match "HP|Hewlett") { return "HP" }
    if ($manufacturer -match "Lenovo") { return "Lenovo" }

    Write-Log "Unknown manufacturer '$manufacturer' - defaulting to All" -Level WARN
    return "All"
}

# Resolve which OEMs to target
function Get-TargetOEMs {
    if ($OEM) {
        $selected = $OEM
    } else {
        $selected = Get-DetectedOEM
    }

    if ($selected -eq "All") {
        return @("Dell", "HP", "Lenovo")
    }
    return @($selected)
}

# Merge patterns from all targeted OEMs into a single config
function Build-MergedConfig {
    param([string[]]$TargetOEMs)

    $merged = @{
        ProcessPatterns   = @()
        ServicePatterns   = @()
        ServiceNames      = @()
        AppxPatterns      = @()
        Win32Patterns     = @()
        WingetApps        = @()
        TaskPatterns      = @()
        TaskFolders       = @()
        RegistryPaths     = @()
        RunKeyPatterns    = @()
        FilesystemPaths   = @()
        StartMenuPatterns = @()
    }

    foreach ($oem in $TargetOEMs) {
        $def = $Script:OEMTargets[$oem]
        $merged.ProcessPatterns   += $def.ProcessPatterns
        $merged.ServicePatterns   += $def.ServicePatterns
        $merged.ServiceNames      += $def.ServiceNames
        $merged.AppxPatterns      += $def.AppxPatterns
        $merged.Win32Patterns     += $def.Win32Patterns
        $merged.WingetApps        += $def.WingetApps
        $merged.TaskPatterns      += $def.TaskPatterns
        $merged.TaskFolders       += $def.TaskFolders
        $merged.RegistryPaths     += $def.RegistryPaths
        $merged.RunKeyPatterns    += $def.RunKeyPatterns
        $merged.FilesystemPaths   += $def.FilesystemPaths
        $merged.StartMenuPatterns += $def.StartMenuPatterns
    }

    return $merged
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

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

function Write-Log {
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

    Add-Content -Path $LogPath -Value $logEntry -ErrorAction SilentlyContinue
}

function Show-Banner {
    $banner = @"

    _   _ _   _  ____ _     _____    _    ____
   | \ | | | | |/ ___| |   | ____|  / \  |  _ \
   |  \| | | | | |   | |   |  _|   / _ \ | |_) |
   | |\  | |_| | |___| |___| |___ / ___ \|  _ <
   |_| \_|\___/ \____|_____|_____/_/   \_\_| \_\

    ___  _____ __  __   ____  _____ __  __  _____     _______ ____
   / _ \| ____|  \/  | |  _ \| ____|  \/  |/ _ \ \   / / ____|  _ \
  | | | |  _| | |\/| | | |_) |  _| | |\/| | | | \ \ / /|  _| | |_) |
  | |_| | |___| |  | | |  _ <| |___| |  | | |_| |\ V / | |___|  _ <
   \___/|_____|_|  |_| |_| \_\_____|_|  |_|\___/  \_/  |_____|_| \_\

                        v$($Script:Config.Version) - Scorched Earth Mode

"@
    Write-Host $banner -ForegroundColor Red
}

# ============================================================================
# DRY RUN HELPER
# ============================================================================

function Write-DryRun {
    param([string]$Message)
    Write-Log "[DRY RUN] Would: $Message" -Level WARN
}

# ============================================================================
# PHASE 1: KILL OEM PROCESSES
# ============================================================================

function Stop-OEMProcesses {
    param([hashtable]$Targets)

    Write-Log -Message "PHASE 1: Terminating OEM Processes" -Level PHASE

    $killed = 0
    $processes = Get-Process -ErrorAction SilentlyContinue

    foreach ($pattern in $Targets.ProcessPatterns) {
        $matches = $processes | Where-Object { $_.Name -like $pattern -or $_.ProcessName -like $pattern }
        foreach ($proc in $matches) {
            if (-not $DryRun) {
                try {
                    $proc | Stop-Process -Force -ErrorAction Stop
                    Write-Log "Terminated process: $($proc.Name) (PID: $($proc.Id))" -Level SUCCESS
                    Add-ReportItem -Phase "Processes" -Item "$($proc.Name) (PID: $($proc.Id))" -Status Removed
                    $killed++
                } catch {
                    Write-Log "Failed to terminate: $($proc.Name) - $($_.Exception.Message)" -Level WARN
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
        Write-Log "No OEM processes found running" -Level INFO
    } else {
        Write-Log "Terminated $killed OEM processes" -Level SUCCESS
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

    Write-Log -Message "PHASE 2: Eliminating OEM Services" -Level PHASE

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
        Write-Log "Processing service: $($svc.DisplayName) [$($svc.Name)]" -Level INFO

        if (-not $DryRun) {
            # Stop the service
            if ($svc.Status -eq 'Running') {
                try {
                    Stop-Service -Name $svc.Name -Force -ErrorAction Stop
                    Write-Log "  Stopped service" -Level SUCCESS
                } catch {
                    Write-Log "  Failed to stop: $($_.Exception.Message)" -Level WARN
                }
            }

            # Disable the service
            try {
                Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
                Write-Log "  Disabled service" -Level SUCCESS
            } catch {
                Write-Log "  Failed to disable: $($_.Exception.Message)" -Level WARN
            }

            # Delete the service
            try {
                $result = sc.exe delete $svc.Name 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "  Deleted service" -Level SUCCESS
                    Add-ReportItem -Phase "Services" -Item "$($svc.DisplayName) [$($svc.Name)]" -Status Removed
                    $removed++
                } else {
                    Write-Log "  Delete pending (may require reboot)" -Level WARN
                    Add-ReportItem -Phase "Services" -Item "$($svc.DisplayName) [$($svc.Name)]" -Status Failed -Detail "Delete pending reboot"
                }
            } catch {
                Write-Log "  Failed to delete: $($_.Exception.Message)" -Level WARN
                Add-ReportItem -Phase "Services" -Item "$($svc.DisplayName) [$($svc.Name)]" -Status Failed -Detail $_.Exception.Message
            }
        } else {
            Write-DryRun "Stop, disable, and delete service: $($svc.DisplayName) [$($svc.Name)]"
            Add-ReportItem -Phase "Services" -Item "$($svc.DisplayName) [$($svc.Name)]" -Status Skipped -Detail "Dry run"
            $removed++
        }
    }

    if ($removed -eq 0 -and $oemServices.Count -eq 0) {
        Write-Log "No OEM services found" -Level INFO
    } else {
        Write-Log "Processed $($oemServices.Count) services, removed $removed" -Level SUCCESS
    }

    return $removed
}

# ============================================================================
# PHASE 3: REMOVE OEM APPX PACKAGES
# ============================================================================

function Remove-OEMAppxPackages {
    param([hashtable]$Targets)

    Write-Log -Message "PHASE 3: Removing OEM AppX Packages" -Level PHASE

    $removed = 0

    foreach ($pattern in $Targets.AppxPatterns) {
        # Remove installed packages for all users
        $packages = Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue
        foreach ($pkg in $packages) {
            if (-not $DryRun) {
                try {
                    Write-Log "Removing AppX: $($pkg.Name)" -Level INFO
                    $pkg | Remove-AppxPackage -AllUsers -ErrorAction Stop
                    Write-Log "  Removed for all users" -Level SUCCESS
                    Add-ReportItem -Phase "AppX" -Item $pkg.Name -Status Removed
                    $removed++
                } catch {
                    Write-Log "  Failed: $($_.Exception.Message)" -Level WARN
                    try {
                        $pkg | Remove-AppxPackage -ErrorAction Stop
                        Write-Log "  Removed for current user only" -Level SUCCESS
                        Add-ReportItem -Phase "AppX" -Item $pkg.Name -Status Removed -Detail "Current user only"
                        $removed++
                    } catch {
                        Write-Log "  Complete failure: $($_.Exception.Message)" -Level ERROR
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
                    Write-Log "Removing provisioned: $($pkg.DisplayName)" -Level INFO
                    Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                    Write-Log "  Removed provisioned package" -Level SUCCESS
                    Add-ReportItem -Phase "AppX" -Item "$($pkg.DisplayName) (provisioned)" -Status Removed
                    $removed++
                } catch {
                    Write-Log "  Failed: $($_.Exception.Message)" -Level WARN
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
        Write-Log "No OEM AppX packages found" -Level INFO
    } else {
        Write-Log "Removed $removed AppX packages" -Level SUCCESS
    }

    return $removed
}

# ============================================================================
# PHASE 4: UNINSTALL OEM WIN32 APPLICATIONS
# ============================================================================

function Remove-OEMWin32Apps {
    param([hashtable]$Targets)

    Write-Log -Message "PHASE 4: Uninstalling OEM Win32 Applications" -Level PHASE

    $removed = 0

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
        if (-not $app.UninstallString) {
            Write-Log "Skipping $($app.DisplayName) - no uninstall string" -Level WARN
            Add-ReportItem -Phase "Win32" -Item $app.DisplayName -Status Skipped -Detail "No uninstall string"
            continue
        }

        if (-not $DryRun) {
            Write-Log "Uninstalling: $($app.DisplayName)" -Level INFO

            $uninstallString = $app.UninstallString
            $quietUninstall = $app.QuietUninstallString

            try {
                if ($quietUninstall) {
                    Write-Log "  Using quiet uninstall" -Level INFO
                    $process = Start-Process cmd.exe -ArgumentList "/c `"$quietUninstall`"" -Wait -PassThru -WindowStyle Hidden
                }
                elseif ($uninstallString -match "msiexec") {
                    $guid = [regex]::Match($uninstallString, '\{[A-F0-9-]+\}', 'IgnoreCase').Value
                    if ($guid) {
                        Write-Log "  MSI uninstall: $guid" -Level INFO
                        $process = Start-Process msiexec.exe -ArgumentList "/x $guid /qn /norestart REBOOT=ReallySuppress" -Wait -PassThru -WindowStyle Hidden
                    }
                }
                elseif ($uninstallString -match "InstallShield") {
                    Write-Log "  InstallShield uninstall" -Level INFO
                    $process = Start-Process cmd.exe -ArgumentList "/c `"$uninstallString`" -remove -runfromtemp -silent" -Wait -PassThru -WindowStyle Hidden
                }
                else {
                    Write-Log "  Generic uninstall with silent switches" -Level INFO
                    $silentArgs = @("/S", "/silent", "/quiet", "-silent", "-quiet", "/qn", "-s")
                    $uninstallCmd = $uninstallString -replace '"', ''

                    foreach ($arg in $silentArgs) {
                        $process = Start-Process cmd.exe -ArgumentList "/c `"$uninstallCmd`" $arg" -Wait -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
                        if ($process.ExitCode -eq 0) { break }
                    }
                }

                if ($process -and $process.ExitCode -eq 0) {
                    Write-Log "  Successfully uninstalled" -Level SUCCESS
                    Add-ReportItem -Phase "Win32" -Item $app.DisplayName -Status Removed
                    $removed++
                } elseif ($process) {
                    Write-Log "  Exit code: $($process.ExitCode)" -Level WARN
                    Add-ReportItem -Phase "Win32" -Item $app.DisplayName -Status Removed -Detail "Exit code $($process.ExitCode)"
                    $removed++
                }
            } catch {
                Write-Log "  Failed: $($_.Exception.Message)" -Level ERROR
                Add-ReportItem -Phase "Win32" -Item $app.DisplayName -Status Failed -Detail $_.Exception.Message
            }
        } else {
            Write-DryRun "Uninstall Win32 app: $($app.DisplayName)"
            Add-ReportItem -Phase "Win32" -Item $app.DisplayName -Status Skipped -Detail "Dry run"
            $removed++
        }
    }

    # Also try winget for stragglers
    Write-Log "Checking winget for remaining OEM apps..." -Level INFO
    foreach ($appName in $Targets.WingetApps) {
        if (-not $DryRun) {
            try {
                $result = winget uninstall "$appName" --silent --accept-source-agreements 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "  Winget removed: $appName" -Level SUCCESS
                    Add-ReportItem -Phase "Win32" -Item "$appName (winget)" -Status Removed
                    $removed++
                }
            } catch {
                # Silently continue - app may not exist
            }
        } else {
            Write-DryRun "Winget uninstall: $appName"
        }
    }

    if ($removed -eq 0 -and $oemApps.Count -eq 0) {
        Write-Log "No OEM Win32 applications found" -Level INFO
    } else {
        Write-Log "Uninstalled $removed Win32 applications" -Level SUCCESS
    }

    return $removed
}

# ============================================================================
# PHASE 5: REMOVE OEM SCHEDULED TASKS
# ============================================================================

function Remove-OEMScheduledTasks {
    param([hashtable]$Targets)

    Write-Log -Message "PHASE 5: Removing OEM Scheduled Tasks" -Level PHASE

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
                Write-Log "Removing task: $($task.TaskPath)$($task.TaskName)" -Level INFO
                $task | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
                $task | Unregister-ScheduledTask -Confirm:$false -ErrorAction Stop
                Write-Log "  Removed" -Level SUCCESS
                Add-ReportItem -Phase "Tasks" -Item "$($task.TaskPath)$($task.TaskName)" -Status Removed
                $removed++
            } catch {
                Write-Log "  Failed: $($_.Exception.Message)" -Level WARN
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
                Write-Log "Removed '$folder' scheduled task folder" -Level SUCCESS
            } catch {
                # Folder may not exist or may not be empty
            }
        } else {
            Write-DryRun "Remove task folder: \$folder"
        }
    }

    if ($removed -eq 0) {
        Write-Log "No OEM scheduled tasks found" -Level INFO
    } else {
        Write-Log "Removed $removed scheduled tasks" -Level SUCCESS
    }

    return $removed
}

# ============================================================================
# PHASE 6: REGISTRY CLEANUP
# ============================================================================

function Remove-OEMRegistry {
    param([hashtable]$Targets)

    Write-Log -Message "PHASE 6: Purging OEM Registry Entries" -Level PHASE

    $removed = 0

    foreach ($path in $Targets.RegistryPaths) {
        if (Test-Path $path) {
            if (-not $DryRun) {
                try {
                    Write-Log "Removing registry: $path" -Level INFO
                    Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                    Write-Log "  Removed" -Level SUCCESS
                    Add-ReportItem -Phase "Registry" -Item $path -Status Removed
                    $removed++
                } catch {
                    Write-Log "  Failed: $($_.Exception.Message)" -Level WARN
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
                            Write-Log "Removed Run entry: $($_.Name)" -Level SUCCESS
                            Add-ReportItem -Phase "Registry" -Item "Run: $($_.Name)" -Status Removed
                            $removed++
                        } catch {
                            Write-Log "Failed to remove Run entry: $($_.Name)" -Level WARN
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
        Write-Log "No OEM registry entries found" -Level INFO
    } else {
        Write-Log "Removed $removed registry items" -Level SUCCESS
    }

    return $removed
}

# ============================================================================
# PHASE 7: FILESYSTEM CLEANUP
# ============================================================================

function Remove-OEMFilesystem {
    param([hashtable]$Targets)

    Write-Log -Message "PHASE 7: Cleaning OEM Filesystem Remnants" -Level PHASE

    if ($SkipFilesystemCleanup) {
        Write-Log "Filesystem cleanup skipped by parameter" -Level WARN
        return 0
    }

    $removed = 0

    foreach ($path in $Targets.FilesystemPaths) {
        if (Test-Path $path) {
            if (-not $DryRun) {
                try {
                    Write-Log "Removing: $path" -Level INFO

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
                    Write-Log "  Removed" -Level SUCCESS
                    Add-ReportItem -Phase "Filesystem" -Item $path -Status Removed
                    $removed++
                } catch {
                    try {
                        $emptyDir = "$env:TEMP\EmptyDir_$(Get-Random)"
                        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
                        robocopy $emptyDir $path /MIR /R:1 /W:1 2>&1 | Out-Null
                        Remove-Item $path -Force -Recurse -ErrorAction SilentlyContinue
                        Remove-Item $emptyDir -Force -ErrorAction SilentlyContinue
                        Write-Log "  Removed (robocopy method)" -Level SUCCESS
                        Add-ReportItem -Phase "Filesystem" -Item "$path (robocopy)" -Status Removed
                        $removed++
                    } catch {
                        Write-Log "  Failed: $($_.Exception.Message)" -Level WARN
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
                        Write-Log "Removed Start Menu: $($_.Name)" -Level SUCCESS
                        Add-ReportItem -Phase "Filesystem" -Item "Start Menu: $($_.Name)" -Status Removed
                        $removed++
                    } catch {
                        Write-Log "Failed to remove Start Menu item: $($_.Name)" -Level WARN
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
        Write-Log "No OEM filesystem items found" -Level INFO
    } else {
        Write-Log "Removed $removed filesystem items" -Level SUCCESS
    }

    return $removed
}

# ============================================================================
# PHASE 8: BLOCK REINSTALLATION
# ============================================================================

function Block-OEMReinstallation {
    Write-Log -Message "PHASE 8: Blocking Automatic Reinstallation" -Level PHASE

    if ($SkipReinstallBlock) {
        Write-Log "Reinstallation blocking skipped by parameter" -Level WARN
        return 0
    }

    $blocked = 0

    # Disable Windows Consumer Features
    if (-not $DryRun) {
        try {
            $cloudContentPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
            if (-not (Test-Path $cloudContentPath)) {
                New-Item -Path $cloudContentPath -Force | Out-Null
            }
            Set-ItemProperty -Path $cloudContentPath -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWord -Force
            Write-Log "Disabled Windows Consumer Features" -Level SUCCESS
            Add-ReportItem -Phase "Reinstall Block" -Item "DisableWindowsConsumerFeatures" -Status Removed
            $blocked++
        } catch {
            Write-Log "Failed to disable Consumer Features: $($_.Exception.Message)" -Level WARN
            Add-ReportItem -Phase "Reinstall Block" -Item "DisableWindowsConsumerFeatures" -Status Failed -Detail $_.Exception.Message
        }
    } else {
        Write-DryRun "Set DisableWindowsConsumerFeatures = 1"
        Add-ReportItem -Phase "Reinstall Block" -Item "DisableWindowsConsumerFeatures" -Status Skipped -Detail "Dry run"
        $blocked++
    }

    # Disable Content Delivery Manager OEM and silent app installation
    $cdmPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
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

    foreach ($setting in $cdmSettings.GetEnumerator()) {
        if (-not $DryRun) {
            try {
                Set-ItemProperty -Path $cdmPath -Name $setting.Key -Value $setting.Value -Type DWord -Force -ErrorAction Stop
                $blocked++
            } catch {
                Write-Log "Failed to set $($setting.Key): $($_.Exception.Message)" -Level WARN
            }
        } else {
            Write-DryRun "Set $($setting.Key) = $($setting.Value)"
            $blocked++
        }
    }
    Write-Log "Configured Content Delivery Manager settings" -Level SUCCESS

    # Disable suggested apps in Start Menu
    if (-not $DryRun) {
        try {
            $explorerPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            Set-ItemProperty -Path $explorerPath -Name "Start_IrisRecommendations" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Log "Disabled Start Menu suggestions" -Level SUCCESS
            $blocked++
        } catch {
            Write-Log "Failed to disable Start suggestions" -Level WARN
        }
    } else {
        Write-DryRun "Set Start_IrisRecommendations = 0"
        $blocked++
    }

    Write-Log "Applied $blocked reinstallation prevention settings" -Level SUCCESS
    Write-Log "NOTE: To re-enable OEM software installation later, run with -SkipReinstallBlock or manually revert registry settings" -Level INFO

    return $blocked
}

# ============================================================================
# VERIFICATION
# ============================================================================

function Test-OEMRemoval {
    param([hashtable]$Targets)

    Write-Log -Message "VERIFICATION: Checking for OEM Remnants" -Level PHASE

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
        Write-Log "VERIFICATION SKIPPED: Dry run mode - no changes were made" -Level WARN
        return $true
    }

    if ($issues.Count -eq 0) {
        Write-Log "VERIFICATION PASSED: No OEM remnants detected" -Level SUCCESS
        return $true
    } else {
        Write-Log "VERIFICATION WARNING: Some OEM items may remain" -Level WARN
        foreach ($issue in $issues) {
            Write-Log "  - $issue" -Level WARN
        }
        Write-Log "A system restart may be required to complete removal" -Level INFO
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

    $reportPath = "$env:TEMP\NuclearOEMRemover_Report.html"

    $sysInfo = Get-CimInstance Win32_ComputerSystem
    $osInfo = Get-CimInstance Win32_OperatingSystem

    # Build report item rows
    $rowsHtml = ""
    foreach ($item in $Script:ReportItems) {
        $bgColor = switch ($item.Status) {
            "Removed" { "#1a3a1a" }
            "Skipped" { "#3a3a1a" }
            "Failed"  { "#3a1a1a" }
        }
        $fgColor = switch ($item.Status) {
            "Removed" { "#4caf50" }
            "Skipped" { "#ffb300" }
            "Failed"  { "#ef5350" }
        }
        $rowsHtml += "<tr style='background:$bgColor'><td>$($item.Phase)</td><td>$($item.Item)</td><td style='color:$fgColor;font-weight:bold'>$($item.Status)</td><td>$($item.Detail)</td></tr>`n"
    }

    if ($rowsHtml -eq "") {
        $rowsHtml = "<tr><td colspan='4' style='text-align:center;color:#888'>No items found to process</td></tr>"
    }

    $summaryRows = @(
        @("Processes Killed", $Results.Processes + $Results.ProcessesSecondPass),
        @("Services Removed", $Results.Services),
        @("AppX Removed", $Results.AppxPackages),
        @("Win32 Uninstalled", $Results.Win32Apps),
        @("Tasks Removed", $Results.ScheduledTasks),
        @("Registry Cleaned", $Results.RegistryItems),
        @("Dirs Cleaned", $Results.FilesystemItems),
        @("Reinstall Blocks", $Results.ReinstallBlocks)
    )

    $summaryHtml = ""
    foreach ($row in $summaryRows) {
        $val = $row[1]
        $clr = if ($val -gt 0) { "#4caf50" } else { "#888" }
        $summaryHtml += "<tr><td>$($row[0])</td><td style='color:$clr;font-weight:bold;text-align:right'>$val</td></tr>`n"
    }

    $dryRunBanner = ""
    if ($DryRun) {
        $dryRunBanner = "<div style='background:#3a3a1a;border:2px solid #ffb300;color:#ffb300;padding:12px;text-align:center;font-size:18px;font-weight:bold;margin-bottom:20px;border-radius:8px'>DRY RUN - No changes were made</div>"
    }

    $verifiedText = if ($Verified) { "<span style='color:#4caf50'>PASSED</span>" } else { "<span style='color:#ef5350'>ISSUES FOUND</span>" }

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>NuclearOEMRemover Report</title>
<style>
  body { background:#0d1117; color:#c9d1d9; font-family:'Segoe UI',sans-serif; margin:0; padding:20px; }
  h1 { color:#ef5350; border-bottom:2px solid #ef5350; padding-bottom:10px; }
  h2 { color:#58a6ff; margin-top:30px; }
  table { border-collapse:collapse; width:100%; margin:10px 0; }
  th { background:#161b22; color:#58a6ff; text-align:left; padding:10px 14px; border:1px solid #30363d; }
  td { padding:8px 14px; border:1px solid #30363d; }
  .info-grid { display:grid; grid-template-columns:1fr 1fr; gap:10px; margin:10px 0; }
  .info-card { background:#161b22; border:1px solid #30363d; border-radius:8px; padding:14px; }
  .info-label { color:#8b949e; font-size:12px; text-transform:uppercase; }
  .info-value { color:#c9d1d9; font-size:16px; font-weight:bold; margin-top:4px; }
  .summary-table td { background:#161b22; }
  .footer { margin-top:30px; color:#8b949e; font-size:12px; text-align:center; border-top:1px solid #30363d; padding-top:10px; }
</style>
</head>
<body>
<h1>NuclearOEMRemover v$($Script:Config.Version) - Report</h1>
$dryRunBanner

<div class="info-grid">
  <div class="info-card">
    <div class="info-label">Manufacturer</div>
    <div class="info-value">$($sysInfo.Manufacturer)</div>
  </div>
  <div class="info-card">
    <div class="info-label">Model</div>
    <div class="info-value">$($sysInfo.Model)</div>
  </div>
  <div class="info-card">
    <div class="info-label">OS</div>
    <div class="info-value">$($osInfo.Caption) ($($osInfo.Version))</div>
  </div>
  <div class="info-card">
    <div class="info-label">Target OEMs</div>
    <div class="info-value">$($TargetOEMs -join ', ')</div>
  </div>
  <div class="info-card">
    <div class="info-label">Elapsed Time</div>
    <div class="info-value">$($Elapsed.ToString('mm\:ss'))</div>
  </div>
  <div class="info-card">
    <div class="info-label">Verification</div>
    <div class="info-value">$verifiedText</div>
  </div>
</div>

<h2>Summary</h2>
<table class="summary-table">
<tr><th>Phase</th><th style="text-align:right">Count</th></tr>
$summaryHtml
</table>

<h2>Detailed Results</h2>
<table>
<tr><th>Phase</th><th>Item</th><th>Status</th><th>Detail</th></tr>
$rowsHtml
</table>

<div class="footer">
  Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | NuclearOEMRemover v$($Script:Config.Version)
</div>
</body>
</html>
"@

    $html | Out-File -FilePath $reportPath -Encoding utf8 -Force
    Write-Log "HTML report saved to: $reportPath" -Level SUCCESS
    return $reportPath
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

function Invoke-NuclearOEMRemover {
    Clear-Host
    Show-Banner

    # Resolve targets
    $targetOEMs = Get-TargetOEMs
    $mergedTargets = Build-MergedConfig -TargetOEMs $targetOEMs

    Write-Log "NuclearOEMRemover v$($Script:Config.Version) starting..." -Level INFO
    Write-Log "Log file: $LogPath" -Level INFO
    Write-Log "Target OEMs: $($targetOEMs -join ', ')" -Level INFO
    Write-Log "Parameters: DryRun=$DryRun, SkipReinstallBlock=$SkipReinstallBlock, SkipFilesystemCleanup=$SkipFilesystemCleanup" -Level INFO

    if ($DryRun) {
        Write-Host ""
        Write-Host "  *** DRY RUN MODE - No changes will be made ***" -ForegroundColor Yellow
        Write-Host ""
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
    }

    # Execute all phases
    $results.Processes = Stop-OEMProcesses -Targets $mergedTargets
    $results.Services = Remove-OEMServices -Targets $mergedTargets

    # Second process kill - OEM services love to respawn executables immediately
    Write-Log -Message "PHASE 2.5: Second Process Kill (Catching Respawns)" -Level PHASE
    if (-not $DryRun) {
        Start-Sleep -Seconds 1
    }
    $results.ProcessesSecondPass = Stop-OEMProcesses -Targets $mergedTargets
    if ($results.ProcessesSecondPass -gt 0) {
        Write-Log "Caught $($results.ProcessesSecondPass) respawned processes" -Level SUCCESS
    }

    $results.AppxPackages = Remove-OEMAppxPackages -Targets $mergedTargets
    $results.Win32Apps = Remove-OEMWin32Apps -Targets $mergedTargets
    $results.ScheduledTasks = Remove-OEMScheduledTasks -Targets $mergedTargets
    $results.RegistryItems = Remove-OEMRegistry -Targets $mergedTargets
    $results.FilesystemItems = Remove-OEMFilesystem -Targets $mergedTargets
    $results.ReinstallBlocks = Block-OEMReinstallation

    # Verification
    $verified = Test-OEMRemoval -Targets $mergedTargets

    # Summary
    Write-Log -Message "OPERATION COMPLETE" -Level PHASE

    $elapsed = (Get-Date) - $Script:Config.StartTime

    # Phase summary table
    Write-Host ""
    Write-Host "  NUCLEAR OEM REMOVER - SUMMARY" -ForegroundColor Cyan
    Write-Host "  =============================" -ForegroundColor Cyan
    Write-Host ""

    $tableData = @(
        @{ Phase = "Processes Killed";    Count = $results.Processes + $results.ProcessesSecondPass },
        @{ Phase = "Services Removed";    Count = $results.Services },
        @{ Phase = "AppX Removed";        Count = $results.AppxPackages },
        @{ Phase = "Win32 Uninstalled";   Count = $results.Win32Apps },
        @{ Phase = "Tasks Removed";       Count = $results.ScheduledTasks },
        @{ Phase = "Registry Cleaned";    Count = $results.RegistryItems },
        @{ Phase = "Dirs Cleaned";        Count = $results.FilesystemItems },
        @{ Phase = "Reinstall Blocks";    Count = $results.ReinstallBlocks }
    )

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
        Write-Host "  *** DRY RUN - No changes were made. Run without -DryRun to execute. ***" -ForegroundColor Yellow
    }

    Write-Host ""

    if (-not $verified -and -not $DryRun) {
        Write-Host "  RECOMMENDATION: Restart your computer and run this script again." -ForegroundColor Yellow
        Write-Host ""
    }

    if (-not $DryRun) {
        Write-Host "  OEM bloatware has been NUKED. " -ForegroundColor Red -NoNewline
        Write-Host "You may need to restart for all changes to take effect." -ForegroundColor White
        Write-Host ""
    }

    # Generate HTML report
    $reportPath = New-HTMLReport -Results $results -Verified $verified -TargetOEMs $targetOEMs -Elapsed $elapsed
    Write-Host "  HTML Report: $reportPath" -ForegroundColor Cyan
    Write-Host ""

    # Open report in default browser
    Start-Process $reportPath

    return $results
}

# Run the script
Invoke-NuclearOEMRemover
