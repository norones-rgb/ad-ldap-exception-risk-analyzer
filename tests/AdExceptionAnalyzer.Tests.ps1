#Requires -Version 7.2
# Pester v5: Invoke-Pester -Path ./tests -Output Detailed
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src/AdExceptionAnalyzer.psm1') -Force
    $fixture = Join-Path $root 'sample-data'
    $configPath = Join-Path $root 'config/default.json'
    $asOf = [datetimeoffset]'2026-11-05T12:00:00Z'
    $snapshot = Import-AdExceptionSnapshot -DataDirectory $fixture
    $config = Read-AnalyzerConfig -Path $configPath

    function Get-TestResult {
        $unresolved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $findings = @(Get-AdRiskFindings -Snapshot $snapshot -Config $config -ReferenceDateUtc $asOf -UnresolvedReferences $unresolved)
        return [pscustomobject]@{ Findings = $findings; Unresolved = $unresolved }
    }
}

Describe 'Synthetic risk detection (fixed as-of date)' {
    It 'loads 11 users and 6 groups with no unresolved membership refs' {
        @($snapshot.Users).Count | Should -Be 11
        @($snapshot.Groups).Count | Should -Be 6
        (Get-TestResult).Unresolved.Count | Should -Be 0
    }

    It 'finds the exact expected fixture count and severities' {
        $findings = (Get-TestResult).Findings
        @($findings).Count | Should -Be 12
        @($findings | Where-Object Severity -EQ 'Critical').Count | Should -Be 1
        @($findings | Where-Object Severity -EQ 'High').Count | Should -Be 5
        @($findings | Where-Object Severity -EQ 'Medium').Count | Should -Be 6
    }

    It 'recognizes nested privileged membership and reports the disabled privileged account' {
        $findings = (Get-TestResult).Findings
        @($findings | Where-Object { $_.RuleId -eq 'PRIV-002' -and $_.SamAccountName -eq 'alice.admin' }).Count | Should -Be 1
        @($findings | Where-Object { $_.RuleId -eq 'PRIV-001' -and $_.SamAccountName -eq 'bob.disabled' }).Count | Should -Be 1
    }

    It 'reports each configured authentication and lifecycle signal' {
        $findings = (Get-TestResult).Findings
        @($findings | Where-Object { $_.RuleId -eq 'AUTH-001' -and $_.SamAccountName -eq 'eve.preauth' }).Count | Should -Be 1
        @($findings | Where-Object { $_.RuleId -eq 'AUTH-002' -and $_.SamAccountName -eq 'svc.legacy' }).Count | Should -Be 1
        @($findings | Where-Object { $_.RuleId -eq 'AUTH-003' -and $_.SamAccountName -eq 'frank.nopass' }).Count | Should -Be 1
        @($findings | Where-Object { $_.RuleId -eq 'LIFE-001' -and $_.SamAccountName -eq 'dana.expired' }).Count | Should -Be 1
        @($findings | Where-Object { $_.RuleId -eq 'PASS-001' -and $_.SamAccountName -eq 'svc.legacy' }).Count | Should -Be 1
    }

    It 'does not mark a newly created never-used account as stale' {
        $findings = (Get-TestResult).Findings
        @($findings | Where-Object SamAccountName -EQ 'grace.new').Count | Should -Be 0
        @($findings | Where-Object { $_.RuleId -eq 'LIFE-003' -and $_.SamAccountName -eq 'jane.never' }).Count | Should -Be 1
        @($findings | Where-Object SamAccountName -EQ 'ivan.active').Count | Should -Be 0
    }
}

Describe 'Input and output safety' {
    It 'rejects invalid Booleans rather than silently treating them as false' {
        $copy = Join-Path $TestDrive 'bad-boolean'
        New-Item -ItemType Directory -Path $copy | Out-Null
        Copy-Item -LiteralPath (Join-Path $fixture 'users.csv') -Destination $copy
        Copy-Item -LiteralPath (Join-Path $fixture 'groups.csv') -Destination $copy
        $usersPath = Join-Path $copy 'users.csv'
        $text = Get-Content -LiteralPath $usersPath -Raw
        $text = $text.Replace('True,2024-01-15T00:00:00Z', 'Maybe,2024-01-15T00:00:00Z')
        Set-Content -LiteralPath $usersPath -Value $text -Encoding utf8
        { Import-AdExceptionSnapshot -DataDirectory $copy } | Should -Throw '*Invalid Boolean*'
    }

    It 'HTML-encodes values that could otherwise inject tags' {
        $directory = Join-Path $TestDrive 'escape-report'
        $evil = [pscustomobject]@{
            RuleId = 'TEST-001'; Severity = 'High'; SamAccountName = '<img src=x onerror=alert(1)>'
            DistinguishedName = 'CN=Test,DC=example,DC=com'; Evidence = '<script>alert(1)</script>'
            Recommendation = 'Review'
        }
        $summary = [pscustomobject]@{
            Source = 'Csv'; Scope = 'test'; AsOfUtc = '2026-11-05T12:00:00Z'
            UsersAnalyzed = 1; GroupsLoaded = 1; TotalFindings = 1
            SeverityCounts = [pscustomobject]@{ Critical = 0; High = 1; Medium = 0; Low = 0 }
            UnresolvedMembershipReferences = 0
            UnresolvedMembershipDetails = @()
        }
        $paths = Write-AdRiskReports -Summary $summary -Findings @($evil) -OutputDirectory $directory -ReportPrefix 'escape'
        $html = Get-Content -LiteralPath $paths.Html -Raw
        $html | Should -Match '&lt;img'
        $html | Should -Match '&lt;script&gt;'
        $html | Should -Not -Match '<img '
        $html | Should -Not -Match '<script>'
        (Import-Csv -LiteralPath $paths.Csv).Count | Should -Be 1
        (Get-Content -LiteralPath $paths.Json -Raw | ConvertFrom-Json).Findings.Count | Should -Be 1
    }

    It 'safely prefixes dangerous Excel formulas in the CSV export' {
        $directory = Join-Path $TestDrive 'formula-export'
        $finding = [pscustomobject]@{
            RuleId = 'TEST-002'; Severity = 'Low'; SamAccountName = '=HYPERLINK("https://example.invalid")'
            DistinguishedName = 'CN=Test,DC=example,DC=com'; Evidence = '+cmd'
            Recommendation = 'Review'
        }
        $summary = [pscustomobject]@{
            Source = 'Csv'; Scope = 'test'; AsOfUtc = '2026-11-05T12:00:00Z'
            UsersAnalyzed = 1; GroupsLoaded = 1; TotalFindings = 1
            SeverityCounts = [pscustomobject]@{ Critical = 0; High = 0; Medium = 0; Low = 1 }
            UnresolvedMembershipReferences = 0
            UnresolvedMembershipDetails = @()
        }
        $paths = Write-AdRiskReports -Summary $summary -Findings @($finding) -OutputDirectory $directory -ReportPrefix 'formulas'
        $csvRow = Import-Csv -LiteralPath $paths.Csv | Select-Object -First 1
        $csvRow.SamAccountName.StartsWith("'=") | Should -BeTrue
        $csvRow.Evidence.StartsWith("'+") | Should -BeTrue
        (Get-Content -LiteralPath $paths.Json -Raw | ConvertFrom-Json).Findings[0].SamAccountName.StartsWith('=') | Should -BeTrue
    }

    It 'writes a valid zero-finding report without inventing a record' {
        $directory = Join-Path $TestDrive 'zero-findings'
        $summary = [pscustomobject]@{
            Source = 'Csv'; Scope = 'test'; AsOfUtc = '2026-11-05T12:00:00Z'
            UsersAnalyzed = 1; GroupsLoaded = 1; TotalFindings = 0
            SeverityCounts = [pscustomobject]@{ Critical = 0; High = 0; Medium = 0; Low = 0 }
            UnresolvedMembershipReferences = 0
            UnresolvedMembershipDetails = @()
        }
        $paths = Write-AdRiskReports -Summary $summary -Findings @() -OutputDirectory $directory -ReportPrefix 'empty'
        (Get-Content -LiteralPath $paths.Json -Raw | ConvertFrom-Json).Findings.Count | Should -Be 0
        (Get-Content -LiteralPath $paths.Csv -Raw) | Should -Match 'RuleId'
    }

    It 'creates three reports from the offline entrypoint without AD dependencies' {
        $directory = Join-Path $TestDrive 'entrypoint-reports'
        $result = & (Join-Path $root 'Invoke-AdExceptionAnalyzer.ps1') -Mode Csv -AsOfUtc '2026-11-05T12:00:00Z' -OutputDirectory $directory
        $result.Summary.TotalFindings | Should -Be 12
        Test-Path -LiteralPath $result.Reports.Csv | Should -BeTrue
        Test-Path -LiteralPath $result.Reports.Json | Should -BeTrue
        Test-Path -LiteralPath $result.Reports.Html | Should -BeTrue
    }
}
