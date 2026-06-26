<#
.SYNOPSIS
    Pester tests for NuclearOEMRemover engine helpers.
.DESCRIPTION
    Exercises the pure-logic portions of the engine (config merge, preserve/gate checks,
    undo manifest, HTML encoding, seed-file loader) without requiring administrator rights
    or touching the live system.

    Run with:
        Invoke-Pester -Path .\tests\NuclearDellRemover.Tests.ps1

    Requires Pester 5.0+.
#>

#Requires -Version 5.1
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    $script:RepoRoot    = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath  = Join-Path $RepoRoot 'NuclearDellRemover.ps1'

    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not find NuclearDellRemover.ps1 at $script:ScriptPath"
    }

    # Dot-source in LoadOnly mode: defines every engine helper + $Script:OEMTargets + $Script:Config
    # in this scope without requiring admin or running the cleanup.
    . $script:ScriptPath -LoadOnly
}

Describe "Build-MergedConfig" {
    It "returns empty-but-well-formed config when given no OEMs" {
        $merged = Build-MergedConfig -TargetOEMs @() -IncludeSecuritySuites $false
        # Use unary-comma to wrap arrays for pipe-into-Should so empty arrays are not unrolled to $null
        ,$merged.ProcessPatterns      | Should -BeOfType [array]
        ,$merged.KeepOnPreserve       | Should -BeOfType [array]
        ,$merged.HardwareIdSeeds      | Should -BeOfType [array]
        ,$merged.ProfileRelativePaths | Should -BeOfType [array]
        @($merged.ProcessPatterns).Count | Should -Be 0
    }

    It "propagates Dell KeepOnPreserve (the 1.3.1 regression fix)" {
        $merged = Build-MergedConfig -TargetOEMs @('Dell')
        $merged.KeepOnPreserve | Should -Contain '*Dell Command*Update*'
        $merged.KeepOnPreserve | Should -Contain '*DellCommandUpdate*'
    }

    It "propagates ProfileRelativePaths per-OEM and merges across targets" {
        $dell = Build-MergedConfig -TargetOEMs @('Dell')
        $dell.ProfileRelativePaths | Should -Contain 'AppData\Local\Dell'

        $all  = Build-MergedConfig -TargetOEMs @('Dell','HP','Lenovo')
        $all.ProfileRelativePaths | Should -Contain 'AppData\Local\Dell'
        $all.ProfileRelativePaths | Should -Contain 'AppData\Local\HP'
        $all.ProfileRelativePaths | Should -Contain 'AppData\Local\Lenovo'
    }

    It "deduplicates array keys across OEMs" {
        $all = Build-MergedConfig -TargetOEMs @('Dell','HP','Lenovo')
        $count  = @($all.ProcessPatterns).Count
        $unique = @($all.ProcessPatterns | Select-Object -Unique).Count
        $count | Should -Be $unique
    }

    It "skips an unknown OEM without throwing" {
        { Build-MergedConfig -TargetOEMs @('Dell','Asus') } | Should -Not -Throw
    }

    It "preserves ManualUninstallers shape for Dell" {
        $merged = Build-MergedConfig -TargetOEMs @('Dell')
        @($merged.ManualUninstallers).Count | Should -BeGreaterThan 0
        $merged.ManualUninstallers[0].Keys | Should -Contain 'Name'
        $merged.ManualUninstallers[0].Keys | Should -Contain 'Path'
        $merged.ManualUninstallers[0].Keys | Should -Contain 'Arguments'
    }
}

Describe "Test-ShouldPreserveApp" {
    BeforeAll {
        $script:dellTargets = Build-MergedConfig -TargetOEMs @('Dell')
    }

    It "returns false when KeepDCU is off" {
        $app = [PSCustomObject]@{ DisplayName = 'Dell Command | Update for Windows Universal' }
        Test-ShouldPreserveApp -App $app -Targets $script:dellTargets -KeepDCU $false | Should -BeFalse
    }

    It "returns true for DCU display names when KeepDCU is on" {
        $app1 = [PSCustomObject]@{ DisplayName = 'Dell Command | Update for Windows Universal' }
        $app2 = [PSCustomObject]@{ DisplayName = 'DellCommandUpdate' }
        $app3 = [PSCustomObject]@{ DisplayName = 'Dell SupportAssist' }

        Test-ShouldPreserveApp -App $app1 -Targets $script:dellTargets -KeepDCU $true | Should -BeTrue
        Test-ShouldPreserveApp -App $app2 -Targets $script:dellTargets -KeepDCU $true | Should -BeTrue
        Test-ShouldPreserveApp -App $app3 -Targets $script:dellTargets -KeepDCU $true | Should -BeFalse
    }

    It "returns false when targets has no KeepOnPreserve" {
        $hpTargets = Build-MergedConfig -TargetOEMs @('HP')
        $app = [PSCustomObject]@{ DisplayName = 'HP Wolf Security' }
        Test-ShouldPreserveApp -App $app -Targets $hpTargets -KeepDCU $true | Should -BeFalse
    }
}

Describe "Test-ShouldSkipSupportAssistByVersion" {
    # Version gate removed in v1.5.1 — SA Remediation v5.5.16.0 caused BSOD loops.
    # Function now always returns $false (never skip removal).
    It "never skips SupportAssist regardless of version (gate removed)" {
        $app = [PSCustomObject]@{ DisplayName = 'Dell SupportAssist'; DisplayVersion = '5.5.16.0' }
        Test-ShouldSkipSupportAssistByVersion -App $app -ForceFlag $false | Should -BeFalse
    }

    It "never skips even with high version numbers" {
        $app = [PSCustomObject]@{ DisplayName = 'Dell SupportAssist'; DisplayVersion = '99.0.0.0' }
        Test-ShouldSkipSupportAssistByVersion -App $app -ForceFlag $false | Should -BeFalse
    }

    It "returns false for non-SupportAssist apps" {
        $app = [PSCustomObject]@{ DisplayName = 'Dell Optimizer'; DisplayVersion = '9.99.99.99' }
        Test-ShouldSkipSupportAssistByVersion -App $app -ForceFlag $false | Should -BeFalse
    }
}

Describe "ConvertTo-ReportHtml" {
    It "returns an empty string for null" {
        ConvertTo-ReportHtml -Value $null | Should -Be ''
    }

    It "HTML-encodes angle brackets and ampersands" {
        ConvertTo-ReportHtml -Value '<script>alert("xss")</script>' | Should -Match '&lt;script&gt;'
        ConvertTo-ReportHtml -Value 'A & B' | Should -Be 'A &amp; B'
    }

    It "stringifies non-string values" {
        ConvertTo-ReportHtml -Value 42 | Should -Be '42'
        ConvertTo-ReportHtml -Value $true | Should -Be 'True'
    }
}

Describe "Get-HardwareIdSeedsFromFile" {
    BeforeAll {
        $script:tmp = Join-Path $env:TEMP "nor-hwid-$([Guid]::NewGuid().ToString('N')).txt"
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:tmp) { Remove-Item -LiteralPath $script:tmp -Force }
    }

    It "returns an empty array when the path is empty or missing" {
        Get-HardwareIdSeedsFromFile -Path $null | Should -BeNullOrEmpty
        Get-HardwareIdSeedsFromFile -Path '' | Should -BeNullOrEmpty
        Get-HardwareIdSeedsFromFile -Path "$env:TEMP\does-not-exist-$([Guid]::NewGuid().ToString('N')).txt" | Should -BeNullOrEmpty
    }

    It "reads one HWID per line and ignores blanks + comment lines" {
        @(
            '# Alienware AWCC controller',
            'USB\VID_187C&PID_0529',
            '',
            'ROOT\AlienwareOSDPackage',
            '  # indented comment',
            '   '
        ) | Set-Content -LiteralPath $script:tmp -Encoding UTF8

        $seeds = Get-HardwareIdSeedsFromFile -Path $script:tmp
        @($seeds).Count | Should -Be 2
        $seeds | Should -Contain 'USB\VID_187C&PID_0529'
        $seeds | Should -Contain 'ROOT\AlienwareOSDPackage'
    }
}

Describe "Add-UndoEntry / Save-UndoManifest" {
    BeforeEach {
        $Script:UndoManifest.Clear()
    }

    It "no-ops when IsDryRun is true" {
        Add-UndoEntry -Phase 'Test' -Action 'Noop' -Target 'X' -IsDryRun $true
        @($Script:UndoManifest).Count | Should -Be 0
    }

    It "appends structured entries when IsDryRun is false" {
        Add-UndoEntry -Phase 'Win32' -Action 'Uninstall' -Target 'Dell SupportAssist' -Before '3.0.0.0' -After 'removed' -IsDryRun $false
        @($Script:UndoManifest).Count | Should -Be 1
        $entry = $Script:UndoManifest[0]
        $entry.Phase   | Should -Be 'Win32'
        $entry.Action  | Should -Be 'Uninstall'
        $entry.Target  | Should -Be 'Dell SupportAssist'
        $entry.Before  | Should -Be '3.0.0.0'
        $entry.After   | Should -Be 'removed'
        $entry.Timestamp | Should -Not -BeNullOrEmpty
    }

    It "serializes to JSON with expected top-level keys" {
        Add-UndoEntry -Phase 'Registry' -Action 'SetDword' -Target 'HKLM:\Foo\Bar' -After 1 -IsDryRun $false

        $path = Join-Path $env:TEMP "nor-undo-test-$([Guid]::NewGuid().ToString('N')).json"
        try {
            Save-UndoManifest -IsDryRun $false -ManifestPath $path
            Test-Path -LiteralPath $path | Should -BeTrue
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $json.Version   | Should -Be $Script:Config.Version
            $json.Computer  | Should -Be $env:COMPUTERNAME
            @($json.Entries).Count | Should -Be 1
            $json.Entries[0].Action | Should -Be 'SetDword'
        } finally {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
}

Describe "Test-InstallerIsTrusted" {
    It "returns true unconditionally when SkipVerify is true" {
        Test-InstallerIsTrusted -Path 'C:\Windows\explorer.exe' -SkipVerify $true | Should -BeTrue
        # Even a non-existent file short-circuits when verification is disabled
        Test-InstallerIsTrusted -Path 'C:\does-not-exist.exe'    -SkipVerify $true | Should -BeTrue
    }

    It "returns true for Microsoft-signed system binaries" {
        $path = Join-Path $env:WINDIR 'explorer.exe'
        if (Test-Path -LiteralPath $path) {
            Test-InstallerIsTrusted -Path $path -SkipVerify $false | Should -BeTrue
        } else {
            Set-ItResult -Skipped -Because 'explorer.exe not present on this host'
        }
    }

    It "returns false for an unsigned file" {
        $tmp = Join-Path $env:TEMP "nor-unsigned-$([Guid]::NewGuid().ToString('N')).exe"
        try {
            [byte[]]$bytes = 0..255 | ForEach-Object { [byte]$_ }
            [System.IO.File]::WriteAllBytes($tmp, $bytes)
            Test-InstallerIsTrusted -Path $tmp -SkipVerify $false | Should -BeFalse
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        }
    }
}

Describe "Get-AllUserProfilePaths" {
    It "returns at least one path that exists" {
        $paths = @(Get-AllUserProfilePaths)
        $paths.Count | Should -BeGreaterThan 0
        foreach ($p in $paths) { Test-Path -LiteralPath $p | Should -BeTrue }
    }

    It "includes the Default profile template when present" {
        $default = Join-Path $env:SystemDrive 'Users\Default'
        if (Test-Path -LiteralPath $default) {
            @(Get-AllUserProfilePaths) | Should -Contain $default
        } else {
            Set-ItResult -Skipped -Because 'No Default profile on this host'
        }
    }

    It "does not return service-account profiles" {
        $paths = @(Get-AllUserProfilePaths)
        foreach ($p in $paths) {
            $p | Should -Not -Match '\\systemprofile$|\\LocalService$|\\NetworkService$'
        }
    }
}

Describe "Wait-UninstallComplete" {
    It "returns true when the display name is absent" {
        $dn = "NonExistent_NOR_Test_$([Guid]::NewGuid().ToString('N'))"
        Wait-UninstallComplete -DisplayName $dn -TimeoutSeconds 2 -IntervalSeconds 1 | Should -BeTrue
    }
}

Describe "OEM target definitions" {
    It "declares ProfileRelativePaths and HardwareIdSeeds for every supported OEM" {
        foreach ($oem in @('Dell','HP','Lenovo')) {
            $Script:OEMTargets[$oem].ContainsKey('ProfileRelativePaths') | Should -BeTrue
            $Script:OEMTargets[$oem].ContainsKey('HardwareIdSeeds')      | Should -BeTrue
        }
    }

    It "ships ManualUninstallers for Dell, HP, and Lenovo" {
        foreach ($oem in @('Dell','HP','Lenovo')) {
            $Script:OEMTargets[$oem].ContainsKey('ManualUninstallers') | Should -BeTrue
            @($Script:OEMTargets[$oem].ManualUninstallers).Count | Should -BeGreaterThan 0
        }
    }

    It "ships Dell KeepOnPreserve patterns" {
        $Script:OEMTargets.Dell.KeepOnPreserve | Should -Not -BeNullOrEmpty
    }

    It "has trusted-signer allowlist populated" {
        @($Script:Config.TrustedInstallerSigners).Count | Should -BeGreaterThan 0
        $Script:Config.TrustedInstallerSigners | Should -Contain 'Microsoft Corporation'
    }

    It "has SupportAssist version gate removed (BSOD safety)" {
        $Script:Config.ContainsKey('SupportAssistMinVersion') | Should -BeFalse
    }
}

Describe "Initialize-RunArtifactPath" {
    It "accepts a valid path under an existing directory" {
        $path = Join-Path $env:TEMP "nor-init-$([Guid]::NewGuid().ToString('N')).log"
        { Initialize-RunArtifactPath -Path $path -Label 'log' } | Should -Not -Throw
    }

    It "creates the parent directory if missing" {
        $parent = Join-Path $env:TEMP "nor-init-dir-$([Guid]::NewGuid().ToString('N'))"
        $path   = Join-Path $parent 'report.html'
        try {
            Initialize-RunArtifactPath -Path $path -Label 'report'
            Test-Path -LiteralPath $parent | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $parent) { Remove-Item -LiteralPath $parent -Recurse -Force }
        }
    }

    It "throws when the path is null or whitespace" {
        { Initialize-RunArtifactPath -Path '' -Label 'log' }   | Should -Throw
        { Initialize-RunArtifactPath -Path '   ' -Label 'log' } | Should -Throw
    }
}

Describe "Test-InstallerIsTrusted status-branch coverage" {
    It "handles missing file path with a clean rejection" {
        Test-InstallerIsTrusted -Path "C:\definitely-not-here-$([Guid]::NewGuid().ToString('N')).exe" -SkipVerify $false | Should -BeFalse
    }

    It "rejects a foreign-signer binary even when signature is valid" {
        # Temporarily shrink the trusted list so Microsoft-signed binaries become foreign.
        $original = $Script:Config.TrustedInstallerSigners
        try {
            $Script:Config.TrustedInstallerSigners = @('Not A Real Publisher XYZ')
            $path = Join-Path $env:WINDIR 'explorer.exe'
            if (Test-Path -LiteralPath $path) {
                Test-InstallerIsTrusted -Path $path -SkipVerify $false | Should -BeFalse
            } else {
                Set-ItResult -Skipped -Because 'explorer.exe not present'
            }
        } finally {
            $Script:Config.TrustedInstallerSigners = $original
        }
    }
}

Describe "Get-TargetOEMs" {
    It "returns every supported OEM when override is 'All'" {
        $result = Get-TargetOEMs -OEMOverride 'All'
        $result | Should -Contain 'Dell'
        $result | Should -Contain 'HP'
        $result | Should -Contain 'Lenovo'
    }

    It "returns the single selected OEM" {
        $result = @(Get-TargetOEMs -OEMOverride 'Dell')
        $result.Count | Should -Be 1
        $result[0]    | Should -Be 'Dell'
    }

    It "falls back to detection when override is empty" {
        # Just verifies the call path doesn't throw; the detected value depends on the host.
        { Get-TargetOEMs -OEMOverride '' } | Should -Not -Throw
    }
}

Describe "Build-MergedConfig dedup behavior" {
    It "deduplicates patterns that appear in two OEMs (e.g. overlapping wildcards)" {
        # Fabricate a shared pattern by temporarily appending one to both Dell and HP tables
        $dellOriginal = $Script:OEMTargets.Dell.ProcessPatterns.Clone()
        $hpOriginal   = $Script:OEMTargets.HP.ProcessPatterns.Clone()
        try {
            $Script:OEMTargets.Dell.ProcessPatterns = @($Script:OEMTargets.Dell.ProcessPatterns) + '*SharedPatternXYZ*'
            $Script:OEMTargets.HP.ProcessPatterns   = @($Script:OEMTargets.HP.ProcessPatterns)   + '*SharedPatternXYZ*'

            $merged = Build-MergedConfig -TargetOEMs @('Dell','HP')
            @($merged.ProcessPatterns | Where-Object { $_ -eq '*SharedPatternXYZ*' }).Count | Should -Be 1
        } finally {
            $Script:OEMTargets.Dell.ProcessPatterns = $dellOriginal
            $Script:OEMTargets.HP.ProcessPatterns   = $hpOriginal
        }
    }

    It "filters out whitespace-only patterns" {
        $dellOriginal = $Script:OEMTargets.Dell.ProcessPatterns.Clone()
        try {
            $Script:OEMTargets.Dell.ProcessPatterns = @($Script:OEMTargets.Dell.ProcessPatterns) + '  ' + ''
            $merged = Build-MergedConfig -TargetOEMs @('Dell')
            $merged.ProcessPatterns | Should -Not -Contain '  '
            $merged.ProcessPatterns | Should -Not -Contain ''
        } finally {
            $Script:OEMTargets.Dell.ProcessPatterns = $dellOriginal
        }
    }
}

Describe "Test-UninstallStringIsSafe" {
    It "accepts a normal uninstall path" {
        Test-UninstallStringIsSafe -Value 'C:\Program Files\Dell\SupportAssist\Uninstall.exe' | Should -BeTrue
    }

    It "accepts an msiexec uninstall string" {
        Test-UninstallStringIsSafe -Value 'MsiExec.exe /X{12345678-1234-1234-1234-123456789012}' | Should -BeTrue
    }

    It "rejects ampersand command chaining" {
        Test-UninstallStringIsSafe -Value 'uninstall.exe & malicious.exe' | Should -BeFalse
    }

    It "rejects pipe operator" {
        Test-UninstallStringIsSafe -Value 'uninstall.exe | evil.exe' | Should -BeFalse
    }

    It "rejects redirect operator" {
        Test-UninstallStringIsSafe -Value 'uninstall.exe > nul' | Should -BeFalse
    }

    It "rejects semicolon chaining" {
        Test-UninstallStringIsSafe -Value 'uninstall.exe; del C:\' | Should -BeFalse
    }
}
