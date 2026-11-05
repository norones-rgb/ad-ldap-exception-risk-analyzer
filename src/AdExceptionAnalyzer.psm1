#Requires -Version 7.2
Set-StrictMode -Version Latest

function Get-RecordValue {
    param([Parameter(Mandatory)][object]$Record, [Parameter(Mandatory)][string]$Name)
    $property = $Record.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-Flag {
    param([object]$Value, [string]$Field, [bool]$Required = $false)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        if ($Required) { throw "Required Boolean field '$Field' is blank." }
        return $false
    }
    if ($Value -is [bool]) { return $Value }
    $parsed = $false
    if ([bool]::TryParse(([string]$Value).Trim(), [ref]$parsed)) { return $parsed }
    throw "Invalid Boolean value '$Value' for '$Field'. Expected True or False."
}

function ConvertTo-UtcDate {
    param([object]$Value, [string]$Field, [bool]$Required = $false)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        if ($Required) { throw "Required date '$Field' is blank." }
        return $null
    }
    if ($Value -is [datetimeoffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetime]) { return ([datetimeoffset]$Value).ToUniversalTime() }
    $parsed = [datetimeoffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ([datetimeoffset]::TryParse(([string]$Value).Trim(), $culture, $styles, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    throw "Invalid date '$Value' for '$Field'. Use ISO 8601, e.g. 2026-11-05T12:00:00Z."
}

function ConvertTo-MembershipArray {
    param([object]$Value)
    if ($null -eq $Value) { return @() }
    $memberships = [System.Collections.Generic.List[string]]::new()
    if ($Value -is [string]) {
        $items = $Value.Split(';')
    }
    else { $items = @($Value) }
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $dn = ([string]$item).Trim()
        if (-not [string]::IsNullOrWhiteSpace($dn)) { $memberships.Add($dn) }
    }
    return ,$memberships.ToArray()
}

function ConvertTo-UserRecord {
    param([Parameter(Mandatory)][object]$Record)
    $sam = ([string](Get-RecordValue $Record 'SamAccountName')).Trim()
    $dn = ([string](Get-RecordValue $Record 'DistinguishedName')).Trim()
    if ([string]::IsNullOrWhiteSpace($sam) -or [string]::IsNullOrWhiteSpace($dn)) {
        throw 'Each user must have a SamAccountName and DistinguishedName.'
    }
    return [pscustomobject]@{
        SamAccountName          = $sam
        DistinguishedName      = $dn
        Enabled                = $(ConvertTo-Flag (Get-RecordValue $Record 'Enabled') "$sam.Enabled" $true)
        WhenCreated            = $(ConvertTo-UtcDate (Get-RecordValue $Record 'WhenCreated') "$sam.WhenCreated" $true)
        LastLogonDate          = $(ConvertTo-UtcDate (Get-RecordValue $Record 'LastLogonDate') "$sam.LastLogonDate")
        PasswordLastSet        = $(ConvertTo-UtcDate (Get-RecordValue $Record 'PasswordLastSet') "$sam.PasswordLastSet")
        AccountExpirationDate  = $(ConvertTo-UtcDate (Get-RecordValue $Record 'AccountExpirationDate') "$sam.AccountExpirationDate")
        PasswordNeverExpires   = $(ConvertTo-Flag (Get-RecordValue $Record 'PasswordNeverExpires') "$sam.PasswordNeverExpires")
        PasswordNotRequired    = $(ConvertTo-Flag (Get-RecordValue $Record 'PasswordNotRequired') "$sam.PasswordNotRequired")
        DoesNotRequirePreAuth  = $(ConvertTo-Flag (Get-RecordValue $Record 'DoesNotRequirePreAuth') "$sam.DoesNotRequirePreAuth")
        TrustedForDelegation   = $(ConvertTo-Flag (Get-RecordValue $Record 'TrustedForDelegation') "$sam.TrustedForDelegation")
        ServicePrincipalName   = @((Get-RecordValue $Record 'ServicePrincipalName')) -join ';'
        MemberOf               = $(ConvertTo-MembershipArray (Get-RecordValue $Record 'MemberOf'))
    }
}

function ConvertTo-GroupRecord {
    param([Parameter(Mandatory)][object]$Record)
    $sam = ([string](Get-RecordValue $Record 'SamAccountName')).Trim()
    $dn = ([string](Get-RecordValue $Record 'DistinguishedName')).Trim()
    if ([string]::IsNullOrWhiteSpace($sam) -or [string]::IsNullOrWhiteSpace($dn)) {
        throw 'Each group must have a SamAccountName and DistinguishedName.'
    }
    $sid = Get-RecordValue $Record 'Sid'
    if ($null -ne $sid -and $null -ne $sid.PSObject.Properties['Value']) { $sid = $sid.Value }
    return [pscustomobject]@{
        SamAccountName     = $sam
        DistinguishedName = $dn
        Sid               = ([string]$sid).Trim()
        MemberOf          = $(ConvertTo-MembershipArray (Get-RecordValue $Record 'MemberOf'))
    }
}

function Read-AnalyzerConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Config file not found: $Path" }
    $config = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    foreach ($name in @('InactiveDays', 'NeverLoggedOnDays')) {
        $value = Get-RecordValue $config $name
        $parsed = 0
        if (-not [int]::TryParse([string]$value, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 3650) {
            throw "Configuration '$name' must be an integer from 1 to 3650."
        }
    }
    foreach ($name in @('PrivilegedGroupNames', 'PrivilegedGroupSidSuffixes')) {
        $value = Get-RecordValue $config $name
        if ($value -isnot [array] -or @($value).Count -eq 0) { throw "Configuration '$name' must be a nonempty array." }
        foreach ($entry in @($value)) {
            if ($entry -isnot [string] -or [string]::IsNullOrWhiteSpace($entry)) {
                throw "Configuration '$name' must contain nonblank strings only."
            }
        }
    }
    return $config
}

function Import-AdExceptionSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDirectory)
    $usersPath = Join-Path $DataDirectory 'users.csv'
    $groupsPath = Join-Path $DataDirectory 'groups.csv'
    foreach ($path in @($usersPath, $groupsPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required CSV file not found: $path" }
    }
    $userRows = @(Import-Csv -LiteralPath $usersPath -Encoding utf8 -ErrorAction Stop)
    $groupRows = @(Import-Csv -LiteralPath $groupsPath -Encoding utf8 -ErrorAction Stop)
    if ($userRows.Count -eq 0) { throw "No users in $usersPath; refusing to produce an empty scan." }
    if ($groupRows.Count -eq 0) { throw "No groups in $groupsPath; cannot evaluate privileged group memberships." }
    $requiredUserFields = @('SamAccountName', 'DistinguishedName', 'Enabled', 'WhenCreated', 'LastLogonDate', 'PasswordNeverExpires', 'PasswordNotRequired', 'DoesNotRequirePreAuth', 'TrustedForDelegation', 'AccountExpirationDate', 'MemberOf')
    $requiredGroupFields = @('SamAccountName', 'DistinguishedName', 'Sid', 'MemberOf')
    foreach ($name in $requiredUserFields) {
        if ($null -eq $userRows[0].PSObject.Properties[$name]) { throw "Missing required users.csv column: $name" }
    }
    foreach ($name in $requiredGroupFields) {
        if ($null -eq $groupRows[0].PSObject.Properties[$name]) { throw "Missing required groups.csv column: $name" }
    }
    $users = @($userRows | ForEach-Object { ConvertTo-UserRecord $_ })
    $groups = @($groupRows | ForEach-Object { ConvertTo-GroupRecord $_ })
    Assert-UniqueDns -Records $users -Kind 'user'
    Assert-UniqueDns -Records $groups -Kind 'group'
    return [pscustomobject]@{ Users = $users; Groups = $groups; Source = 'Csv'; Scope = $DataDirectory }
}

function Assert-UniqueDns {
    param([Parameter(Mandatory)][object[]]$Records, [Parameter(Mandatory)][string]$Kind)
    $seenDn = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenSam = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Records) {
        if (-not $seenDn.Add($item.DistinguishedName)) { throw "Duplicate $Kind DN: $($item.DistinguishedName)" }
        if (-not $seenSam.Add($item.SamAccountName)) { throw "Duplicate $Kind SamAccountName: $($item.SamAccountName)" }
    }
}

function Get-AdDirectorySnapshot {
    [CmdletBinding()]
    param([string]$SearchBase, [string]$Server)
    if (-not $IsWindows) { throw 'AD mode requires Windows, RSAT ActiveDirectory module, and domain connectivity.' }
    Import-Module ActiveDirectory -ErrorAction Stop
    $queryParams = @{ Filter = '*'; ResultPageSize = 500; ErrorAction = 'Stop' }
    if (-not [string]::IsNullOrWhiteSpace($Server)) { $queryParams['Server'] = $Server }
    $userArgs = $queryParams.Clone()
    if (-not [string]::IsNullOrWhiteSpace($SearchBase)) { $userArgs['SearchBase'] = $SearchBase }
    $userArgs['Properties'] = @(
        'WhenCreated', 'LastLogonDate', 'PasswordLastSet', 'AccountExpirationDate',
        'PasswordNeverExpires', 'PasswordNotRequired', 'DoesNotRequirePreAuth',
        'TrustedForDelegation', 'ServicePrincipalName', 'MemberOf'
    )
    # Read-only cmdlets, deliberately NO Set-AD*, Disable-AD*, Remove-AD*, or writes.
    $userRows = @(Get-ADUser @userArgs)
    if ($userRows.Count -eq 0) { throw 'AD query returned no users. Check SearchBase and permissions.' }
    # Fetch groups across the current domain to resolve nesting outside the user OU.
    $groupArgs = $queryParams.Clone()
    $groupArgs['Properties'] = @('MemberOf', 'objectSid')
    $groupRows = @(Get-ADGroup @groupArgs)
    if ($groupRows.Count -eq 0) { throw 'AD query returned no groups; refusing to evaluate privileged memberships.' }
    $users = @($userRows | ForEach-Object { ConvertTo-UserRecord $_ })
    $groups = @($groupRows | ForEach-Object { ConvertTo-GroupRecord $_ })
    Assert-UniqueDns -Records $users -Kind 'user'
    Assert-UniqueDns -Records $groups -Kind 'group'
    $scope = if ([string]::IsNullOrWhiteSpace($SearchBase)) { 'Current AD domain (all users)' } else { $SearchBase }
    return [pscustomobject]@{ Users = $users; Groups = $groups; Source = 'AD'; Scope = $scope }
}

function Test-PrivilegedGroup {
    param([Parameter(Mandatory)][object]$Group, [Parameter(Mandatory)][object]$Config)
    if (@($Config.PrivilegedGroupNames) -contains $Group.SamAccountName) { return $true }
    foreach ($suffix in @($Config.PrivilegedGroupSidSuffixes)) {
        if (-not [string]::IsNullOrEmpty($Group.Sid) -and
            $Group.Sid.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-UserGroupClosure {
    param(
        [Parameter(Mandatory)][object]$User,
        [Parameter(Mandatory)][hashtable]$GroupByDn,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$UnresolvedReferences
    )
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($dn in @($User.MemberOf)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$dn)) { $queue.Enqueue($dn) }
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    while ($queue.Count -gt 0) {
        $dn = $queue.Dequeue()
        if (-not $seen.Add($dn)) { continue }
        if (-not $GroupByDn.ContainsKey($dn)) {
            [void]$UnresolvedReferences.Add("$($User.SamAccountName) -> $dn")
            continue
        }
        $group = $GroupByDn[$dn]
        Write-Output $group
        foreach ($parent in @($group.MemberOf)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$parent)) { $queue.Enqueue($parent) }
        }
    }
}

function New-RiskFinding {
    param(
        [Parameter(Mandatory)][string]$RuleId,
        [Parameter(Mandatory)][ValidateSet('Critical', 'High', 'Medium', 'Low')][string]$Severity,
        [Parameter(Mandatory)][object]$User,
        [Parameter(Mandatory)][string]$Evidence,
        [Parameter(Mandatory)][string]$Recommendation
    )
    return [pscustomobject][ordered]@{
        RuleId            = $RuleId
        Severity          = $Severity
        SamAccountName    = $User.SamAccountName
        DistinguishedName = $User.DistinguishedName
        Evidence          = $Evidence
        Recommendation    = $Recommendation
    }
}

function Get-AdRiskFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][datetimeoffset]$ReferenceDateUtc,
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$UnresolvedReferences
    )
    $asOf = $ReferenceDateUtc.ToUniversalTime()
    $inactiveCutoff = $asOf.AddDays(-[int]$Config.InactiveDays)
    $neverCutoff = $asOf.AddDays(-[int]$Config.NeverLoggedOnDays)
    $groupByDn = @{}
    foreach ($group in @($Snapshot.Groups)) { $groupByDn[$group.DistinguishedName] = $group }
    $findings = [System.Collections.Generic.List[object]]::new()

    foreach ($user in @($Snapshot.Users)) {
        $groups = @(Get-UserGroupClosure -User $user -GroupByDn $groupByDn -UnresolvedReferences $UnresolvedReferences)
        $privileged = @($groups | Where-Object { Test-PrivilegedGroup -Group $_ -Config $Config } |
            Sort-Object -Property SamAccountName -Unique)
        $privilegeLabels = (@($privileged | ForEach-Object { $_.SamAccountName }) -join ', ')
        $directMemberships = @($user.MemberOf | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $hasMembership = $directMemberships.Count -gt 0
        $staleLogon = ($null -ne $user.LastLogonDate -and $user.LastLogonDate -lt $inactiveCutoff)
        $neverLoggedOn = ($null -eq $user.LastLogonDate -and $user.WhenCreated -lt $neverCutoff)

        if (-not $user.Enabled -and $privileged.Count -gt 0) {
            $findings.Add((New-RiskFinding 'PRIV-001' 'Critical' $user "Disabled account remains in privileged group chain: $privilegeLabels" 'Review and remove unnecessary privileged group memberships; confirm approved exceptions.'))
        }
        if ($user.Enabled -and $privileged.Count -gt 0 -and ($staleLogon -or $neverLoggedOn)) {
            $lastSeen = if ($null -ne $user.LastLogonDate) { $user.LastLogonDate.ToString('yyyy-MM-dd') } else { 'never recorded' }
            $findings.Add((New-RiskFinding 'PRIV-002' 'High' $user "Privileged group chain: $privilegeLabels; last logon: $lastSeen" 'Validate account ownership and recent activity; review privileged access.'))
        }
        if ($user.Enabled -and $user.DoesNotRequirePreAuth) {
            $findings.Add((New-RiskFinding 'AUTH-001' 'High' $user 'Kerberos preauthentication is disabled.' 'Investigate and re-enable Kerberos preauthentication where compatible.'))
        }
        if ($user.Enabled -and $user.TrustedForDelegation) {
            $findings.Add((New-RiskFinding 'AUTH-002' 'High' $user 'Account is trusted for unconstrained delegation.' 'Validate delegation requirements and migrate to a safer delegation model.'))
        }
        if ($user.Enabled -and $user.PasswordNotRequired) {
            $findings.Add((New-RiskFinding 'AUTH-003' 'High' $user 'PASSWD_NOTREQD / PasswordNotRequired flag is set.' 'Verify the account configuration and remove the flag if not explicitly required.'))
        }
        if ($user.Enabled -and $null -ne $user.AccountExpirationDate -and $user.AccountExpirationDate -lt $asOf) {
            $findings.Add((New-RiskFinding 'LIFE-001' 'High' $user "Account expiration: $($user.AccountExpirationDate.ToString('yyyy-MM-dd'))" 'Validate the account status and disable or renew according to policy.'))
        }
        if ($user.Enabled -and $staleLogon) {
            $findings.Add((New-RiskFinding 'LIFE-002' 'Medium' $user "Last replicated logon: $($user.LastLogonDate.ToString('yyyy-MM-dd')); cutoff: $($inactiveCutoff.ToString('yyyy-MM-dd'))" 'Verify activity using authoritative logs and owner attestation before action.'))
        }
        if ($user.Enabled -and $neverLoggedOn) {
            $findings.Add((New-RiskFinding 'LIFE-003' 'Medium' $user "No last logon recorded; created $($user.WhenCreated.ToString('yyyy-MM-dd'))" 'Confirm provisioning and whether the unused account remains needed.'))
        }
        if ($user.Enabled -and $user.PasswordNeverExpires) {
            $kind = if (-not [string]::IsNullOrWhiteSpace($user.ServicePrincipalName)) { 'SPN present (possible service identity)' } else { 'no SPN recorded' }
            $findings.Add((New-RiskFinding 'PASS-001' 'Medium' $user "PasswordNeverExpires is True; $kind." 'Confirm documented exception or migrate to managed credentials such as gMSA where appropriate.'))
        }
        if (-not $user.Enabled -and $hasMembership) {
            $findings.Add((New-RiskFinding 'GROUP-001' 'Medium' $user "Disabled account retains $($directMemberships.Count) direct group membership(s)." 'Review residual group memberships under offboarding retention policy.'))
        }
    }
    $rank = @{ Critical = 0; High = 1; Medium = 2; Low = 3 }
    return @($findings | Sort-Object -Property @{ Expression = { $rank[$_.Severity] } }, 'SamAccountName', 'RuleId')
}

function ConvertTo-SafeHtml {
    param([AllowNull()][object]$Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}


function ConvertTo-ExcelSafeCsvField {
    param([AllowNull()][object]$Value)
    $text = [string]$Value
    # Excel and spreadsheet viewers can interpret user-controlled text as formulas.
    # The apostrophe is intentionally CSV-only; JSON preserves original evidence.
    if ($text -match '^[\s\x00-\x1f]*[=+\-@]') { return "'$text" }
    return $text
}

function Write-AdRiskReports {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Summary,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')][string]$ReportPrefix
    )
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        throw "OutputDirectory is not a directory: $OutputDirectory"
    }
    $stamp = [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $base = Join-Path $OutputDirectory "$ReportPrefix-$stamp"
    $paths = [ordered]@{ Csv = "$base.csv"; Json = "$base.json"; Html = "$base.html" }
    foreach ($file in $paths.Values) {
        if (Test-Path -LiteralPath $file) { throw "Output file exists; refusing to overwrite: $file" }
    }
    if ($Findings.Count -gt 0) {
        $Findings | ForEach-Object {
            $finding = $_
            $safeFields = [ordered]@{}
            foreach ($field in @('RuleId', 'Severity', 'SamAccountName', 'DistinguishedName', 'Evidence', 'Recommendation')) {
                $safeFields[$field] = ConvertTo-ExcelSafeCsvField $finding.$field
            }
            [pscustomobject]$safeFields
        } | Export-Csv -LiteralPath $paths.Csv -NoTypeInformation -Encoding utf8 -ErrorAction Stop
    }
    else {
        Set-Content -LiteralPath $paths.Csv -Value '"RuleId","Severity","SamAccountName","DistinguishedName","Evidence","Recommendation"' -Encoding utf8 -ErrorAction Stop
    }
    [pscustomobject]@{ Summary = $Summary; Findings = $Findings } |
        ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $paths.Json -Encoding utf8 -ErrorAction Stop

    $rows = [System.Collections.Generic.List[string]]::new()
    foreach ($finding in $Findings) {
        $cells = foreach ($field in @('RuleId', 'Severity', 'SamAccountName', 'DistinguishedName', 'Evidence', 'Recommendation')) {
            '<td>' + (ConvertTo-SafeHtml $finding.$field) + '</td>'
        }
        $rows.Add('<tr>' + ($cells -join '') + '</tr>')
    }
    if ($rows.Count -eq 0) { $rows.Add('<tr><td colspan="6">No configured risk signals detected.</td></tr>') }
    $safeScope = ConvertTo-SafeHtml $Summary.Scope
    $safeAsOf = ConvertTo-SafeHtml $Summary.AsOfUtc
    $safeSource = ConvertTo-SafeHtml $Summary.Source
    $safeWarnings = ConvertTo-SafeHtml $Summary.UnresolvedMembershipReferences
    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<title>AD Exception &amp; Risk Analyzer</title>
<style>
:root{font-family:system-ui,Segoe UI,Arial,sans-serif;color:#202a35;background:#f5f7fa}
body{max-width:1300px;margin:35px auto;padding:0 20px}h1{margin-bottom:6px}
.meta{color:#515e6d;line-height:1.6;overflow-wrap:anywhere}
.stats{display:flex;flex-wrap:wrap;gap:12px;margin:24px 0}
.stat{background:#fff;padding:16px 20px;border:1px solid #dce2e8;border-radius:8px;min-width:110px}
.stat b{display:block;font-size:26px}.stat small{color:#566477}
.table-wrap{overflow-x:auto;border:1px solid #dce2e8;border-radius:8px;background:#fff}
table{width:100%;border-collapse:collapse;font-size:13px}th{text-align:left;background:#e8edf2}
th,td{padding:12px;border-bottom:1px solid #e6ebf0;vertical-align:top;overflow-wrap:anywhere}td{max-width:350px}
.notice{font-size:13px;color:#4f5e6d;margin:20px 0}
</style>
</head>
<body>
<h1>AD Exception &amp; Risk Analyzer</h1>
<p class="meta">Source: $safeSource | As of (UTC): $safeAsOf | Scope: $safeScope</p>
<div class="stats">
<div class="stat"><b>$($Summary.UsersAnalyzed)</b><small>Users analyzed</small></div>
<div class="stat"><b>$($Summary.GroupsLoaded)</b><small>Groups loaded</small></div>
<div class="stat"><b>$($Summary.TotalFindings)</b><small>Findings</small></div>
<div class="stat"><b>$($Summary.SeverityCounts.Critical)</b><small>Critical</small></div>
<div class="stat"><b>$($Summary.SeverityCounts.High)</b><small>High</small></div>
<div class="stat"><b>$($Summary.SeverityCounts.Medium)</b><small>Medium</small></div>
</div>
<p class="notice">Unresolved group references: $safeWarnings. If greater than zero, nested membership coverage may be incomplete. Findings are review signals, not verified policy violations.</p>
<div class="table-wrap"><table>
<thead><tr><th>Rule</th><th>Severity</th><th>Account</th><th>Distinguished name</th><th>Evidence</th><th>Recommended review</th></tr></thead>
<tbody>$($rows -join "`n")</tbody>
</table></div>
<p class="notice">Read-only collection. LastLogonDate is replicated and approximate; validate before remediation. This report may contain identity data and must be handled as confidential.</p>
</body>
</html>
"@
    Set-Content -LiteralPath $paths.Html -Value $html -Encoding utf8 -ErrorAction Stop
    return [pscustomobject]$paths
}

function Invoke-AdExceptionAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Csv', 'AD')][string]$Mode,
        [Parameter(Mandatory)][string]$DataDirectory,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')][string]$ReportPrefix,
        [string]$AsOfUtc,
        [string]$SearchBase,
        [string]$Server
    )
    $config = Read-AnalyzerConfig -Path $ConfigPath
    $at = if ([string]::IsNullOrWhiteSpace($AsOfUtc)) { [datetimeoffset]::UtcNow }
        else { ConvertTo-UtcDate $AsOfUtc 'AsOfUtc' $true }
    $snapshot = if ($Mode -eq 'Csv') { Import-AdExceptionSnapshot -DataDirectory $DataDirectory }
        else { Get-AdDirectorySnapshot -SearchBase $SearchBase -Server $Server }
    $unknown = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $findings = @(Get-AdRiskFindings -Snapshot $snapshot -Config $config -ReferenceDateUtc $at -UnresolvedReferences $unknown)
    $counts = [ordered]@{ Critical = 0; High = 0; Medium = 0; Low = 0 }
    foreach ($finding in $findings) { $counts[$finding.Severity]++ }
    $summary = [pscustomobject][ordered]@{
        Source                         = $snapshot.Source
        Scope                          = $snapshot.Scope
        AsOfUtc                        = $at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        UsersAnalyzed                  = @($snapshot.Users).Count
        GroupsLoaded                   = @($snapshot.Groups).Count
        TotalFindings                  = $findings.Count
        SeverityCounts                 = [pscustomobject]$counts
        UnresolvedMembershipReferences = $unknown.Count
        UnresolvedMembershipDetails    = @($unknown | Sort-Object)
    }
    $reports = Write-AdRiskReports -Summary $summary -Findings $findings -OutputDirectory $OutputDirectory -ReportPrefix $ReportPrefix
    return [pscustomobject]@{ Summary = $summary; Reports = $reports }
}

Export-ModuleMember -Function Invoke-AdExceptionAnalysis, Import-AdExceptionSnapshot, Get-AdRiskFindings, Read-AnalyzerConfig, Write-AdRiskReports
