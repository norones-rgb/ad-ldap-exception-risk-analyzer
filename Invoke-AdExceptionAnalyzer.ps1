#Requires -Version 7.2
<#
.SYNOPSIS
    Read-only Active Directory/LDAP exception and risk analyzer.
.DESCRIPTION
    Scans an offline CSV fixture or an Active Directory domain using read-only
    AD cmdlets and generates CSV, JSON, and offline HTML reports.
.EXAMPLE
    ./Invoke-AdExceptionAnalyzer.ps1 -Mode Csv -AsOfUtc '2026-11-05T12:00:00Z'
.EXAMPLE
    ./Invoke-AdExceptionAnalyzer.ps1 -Mode AD -SearchBase 'OU=Pilot,DC=example,DC=com' -OutputDirectory ./output
.NOTES
    The Live/AD mode requires the Microsoft ActiveDirectory PowerShell module on
    a domain-connected Windows host with appropriate READ permissions.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Csv', 'AD')]
    [string]$Mode = 'Csv',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DataDirectory = (Join-Path $PSScriptRoot 'sample-data'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config/default.json'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'output'),

    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')]
    [string]$ReportPrefix = 'ad-exception-risk',

    [Parameter()]
    [string]$AsOfUtc,

    [Parameter()]
    [string]$SearchBase,

    [Parameter()]
    [string]$Server
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/AdExceptionAnalyzer.psm1') -Force -ErrorAction Stop

$options = @{
    Mode            = $Mode
    DataDirectory   = $DataDirectory
    ConfigPath      = $ConfigPath
    OutputDirectory = $OutputDirectory
    ReportPrefix    = $ReportPrefix
}
if ($PSBoundParameters.ContainsKey('AsOfUtc')) { $options['AsOfUtc'] = $AsOfUtc }
if ($PSBoundParameters.ContainsKey('SearchBase')) { $options['SearchBase'] = $SearchBase }
if ($PSBoundParameters.ContainsKey('Server')) { $options['Server'] = $Server }

Invoke-AdExceptionAnalysis @options
