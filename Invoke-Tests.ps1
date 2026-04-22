<#
.SYNOPSIS
    Convenience runner for the NuclearOEMRemover Pester suite.

.DESCRIPTION
    Verifies Pester 5.0+ is available, optionally installs it for the current user,
    then runs the suite in tests/. Returns exit code 0 on pass, 1 on any failure.

.PARAMETER InstallIfMissing
    Install Pester 5.0+ for the current user if it is not already available.

.PARAMETER Output
    Pester output verbosity. Valid values: None, Normal, Detailed, Diagnostic. Default: Detailed.

.EXAMPLE
    .\Invoke-Tests.ps1

.EXAMPLE
    .\Invoke-Tests.ps1 -InstallIfMissing -Output Normal
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$InstallIfMissing,
    [ValidateSet('None','Normal','Detailed','Diagnostic')]
    [string]$Output = 'Detailed'
)

$ErrorActionPreference = 'Stop'

$pesterMinVersion = [Version]'5.0.0'
$available = Get-Module -ListAvailable Pester |
    Where-Object { [Version]$_.Version -ge $pesterMinVersion } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $available) {
    if (-not $InstallIfMissing) {
        Write-Host "Pester $pesterMinVersion or newer is required but was not found." -ForegroundColor Red
        Write-Host "Re-run with -InstallIfMissing, or install manually:" -ForegroundColor Yellow
        Write-Host "    Install-Module Pester -MinimumVersion $pesterMinVersion -Scope CurrentUser" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "Installing Pester $pesterMinVersion+ for CurrentUser..." -ForegroundColor Cyan
    Install-Module Pester -MinimumVersion $pesterMinVersion -Scope CurrentUser -Force -SkipPublisherCheck
}

Import-Module Pester -MinimumVersion $pesterMinVersion -Force

$testsPath = Join-Path $PSScriptRoot 'tests\NuclearDellRemover.Tests.ps1'
if (-not (Test-Path -LiteralPath $testsPath)) {
    Write-Host "Test file not found: $testsPath" -ForegroundColor Red
    exit 1
}

$result = Invoke-Pester -Path $testsPath -PassThru -Output $Output

if ($result.FailedCount -gt 0) {
    Write-Host ""
    Write-Host "FAILED: $($result.FailedCount) of $($result.TotalCount) tests" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "All $($result.PassedCount) tests passed." -ForegroundColor Green
exit 0
