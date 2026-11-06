# AD/LDAP Exception & Risk Analyzer

> **IAM Automation Toolkit · Project 1/5** | Read-only PowerShell evaluation MVP · Synthetic-first design
>
> [**Portfolio directory**](https://github.com/norones-rgb/ad-ldap-exception-risk-analyzer/blob/main/IAM-AUTOMATION-PORTFOLIO.md) · [**Run the demo**](DEMO.md) · [**Sample HTML preview**](docs/fixture-preview.html) · [**Windows/Linux CI**](https://github.com/norones-rgb/ad-ldap-exception-risk-analyzer/actions/workflows/ci.yml)
>
> [![Pester CI](https://github.com/norones-rgb/ad-ldap-exception-risk-analyzer/actions/workflows/ci.yml/badge.svg)](https://github.com/norones-rgb/ad-ldap-exception-risk-analyzer/actions/workflows/ci.yml) · PowerShell 7.2+ · CSV / JSON / offline HTML output


A **read-only PowerShell IAM portfolio and consulting demo** that inventories Active Directory users and nested groups, highlights common identity risks, and exports review-ready **CSV, JSON, and offline HTML** evidence.

**MVP v0.1** | PowerShell 7.2+ | No third-party runtime dependencies in CSV mode | Windows + RSAT ActiveDirectory module for AD mode

> The project is branded as an ISGIN demonstration. All sample identities are fabricated. The repository intentionally contains no customer data, credentials, privileged access automation, or remediation commands.

## Quick start (no domain access required)

From the project root in PowerShell 7.2+:

```powershell
./Invoke-AdExceptionAnalyzer.ps1 -Mode Csv -AsOfUtc '2026-11-05T12:00:00Z'
```

This reads `sample-data/users.csv` and `sample-data/groups.csv`, evaluates the configured rules, and creates **three files** in `output/` with a unique UTC timestamp. Open the `.html` report in a browser. The pinned `AsOfUtc` makes the synthetic demo reproducible.

Expected sample: **11 users, 6 groups, 12 findings (1 critical, 5 high, 6 medium)**. See [rule documentation](docs/rules.md).

To use the current time instead:

```powershell
./Invoke-AdExceptionAnalyzer.ps1 -Mode Csv
```

Change thresholds or privileged groups in `config/default.json`. Do not modify the source module to tune policy.

## Live AD pilot (read-only)

On a **Windows domain-connected system** with PowerShell 7.2+, RSAT ActiveDirectory installed, and approved read access:

```powershell
./Invoke-AdExceptionAnalyzer.ps1 `
  -Mode AD `
  -SearchBase 'OU=IAM-Pilot,DC=example,DC=com' `
  -Server 'dc01.example.com' `
  -OutputDirectory 'C:\SecureIAMReports'
```

Use a small authorized OU for the first run. In AD mode, the `SearchBase` filters **users only**; group inventory is queried domain-wide so nested membership can be followed outside that OU. Without `SearchBase`, all users in the current domain are queried. The script calls `Get-ADUser` and `Get-ADGroup`; it never calls modifying AD commands.

**No need for Domain Admin permissions.** Appropriate directory read rights are sufficient for attributes available to that account. The collector fails on query errors rather than knowingly publishing partial enumeration.

## Detections

| Rule | Default severity | Signal |
|---|---|---|
| `PRIV-001` | Critical | Disabled account is still in a privileged group, directly or through nested groups |
| `PRIV-002` | High | Enabled account with stale/no logon retains privileged group access |
| `AUTH-001` | High | Kerberos preauthentication disabled |
| `AUTH-002` | High | Unconstrained delegation enabled |
| `AUTH-003` | High | PasswordNotRequired flag set |
| `LIFE-001` | High | Enabled account has expired |
| `LIFE-002` | Medium | Enabled account has a stale replicated last logon |
| `LIFE-003` | Medium | Enabled account is older than grace period and has no recorded logon |
| `PASS-001` | Medium | PasswordNeverExpires flag set (including potential service-account exceptions) |
| `GROUP-001` | Medium | Disabled account retains direct group memberships |

Rules are **review signals**, not proof of a violation. Findings do not execute remediation. See [rule semantics and limitations](docs/rules.md).

## Repository structure

```text
ad-ldap-exception-risk-analyzer/
├── Invoke-AdExceptionAnalyzer.ps1       # User-facing entrypoint
├── src/AdExceptionAnalyzer.psm1          # Input validation, collector, rules, exporters
├── config/default.json                  # Tunable thresholds and privileged groups
├── sample-data/users.csv                # Fabricated directory users
├── sample-data/groups.csv               # Fabricated groups and nested memberships
├── tests/AdExceptionAnalyzer.Tests.ps1  # Pester offline unit/integration tests
├── .github/workflows/ci.yml             # Windows + Linux synthetic CI
├── docs/
│   ├── architecture.md                  # Pipeline and contracts
│   ├── rules.md                         # Exact rule logic and cautions
│   └── pilot-checklist.md               # Read-only rollout checklist
├── output/.gitkeep                      # Generated exports ignored by git
├── .gitignore
└── README.md
```

## CSV input contracts

`users.csv`: `SamAccountName`, `DistinguishedName`, `Enabled`, `WhenCreated`, `LastLogonDate`, `PasswordLastSet`, `AccountExpirationDate`, `PasswordNeverExpires`, `PasswordNotRequired`, `DoesNotRequirePreAuth`, `TrustedForDelegation`, `ServicePrincipalName`, `MemberOf`.

`groups.csv`: `SamAccountName`, `DistinguishedName`, `Sid`, `MemberOf`.

Date fields are ISO 8601 timestamps (prefer `Z`/UTC); empty optional dates are allowed. All Boolean fields use `True` or `False`. `MemberOf` contains **semicolon-separated distinguished names**; quote the CSV field because DNs contain commas. User `Enabled` and `WhenCreated` are required. Duplicate distinguished names and malformed inputs halt the scan. The sample demonstrates group nesting: `alice.admin → IT-Operations → HelpdeskAdmins → Domain Admins`.

If referenced groups cannot be resolved, the report lists unresolved links and **warns that nested privilege coverage can be incomplete**. The script does not infer that a missing group is safe.

## Testing

Install **Pester 5** only for tests:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester -Path ./tests -Output Detailed
```

GitHub Actions runs the synthetic Pester suite on Windows and Linux. AD integration is deliberately **not** exercised in public CI. The source can be audited with PSScriptAnalyzer as an optional separate tool.

## Operational and security constraints

- Only **directory reads** in `-Mode AD`; local reports are written to the chosen output directory. No LDAP bind passwords or other credentials are stored.
- `LastLogonDate` derives from replicated AD logon data and can lag. It is not authoritative activity evidence. Validate through appropriate sign-in and application logs before action.
- This initial release uses the **ActiveDirectory PowerShell module**, not a generic LDAP client. It does not enumerate every forest, resolve cross-forest memberships, evaluate Entra ID, assess effective ACLs, or distinguish every approved service-account exception.
- Privileged group membership is based on group name or built-in well-known RID/SID suffix, including nested membership; review configuration for custom/renamed privileged groups.
- CSV cells beginning with spreadsheet formula operators are prefixed with an apostrophe to reduce CSV formula injection risk. JSON and HTML preserve/escape the underlying values appropriately.
- JSON/CSV/HTML can contain sensitive identity data. Keep them in a restricted folder; `output/` is ignored by Git. **Never commit actual directory exports**.
- An empty result does not certify security posture. An incomplete scope, AD ACL, or missing group reference can hide risk.

## GitHub: publish your demo, not real access data

```bash
git init
git add .
git commit -m "Initial read-only AD exception analyzer MVP"
git branch -M main
# Create your new repository on GitHub, then add its remote:
git remote add origin https://github.com/YOUR-USER/ad-ldap-exception-risk-analyzer.git
git push -u origin main
```

No open-source license has been granted in this demo bundle. Choose a license intentionally before inviting reuse or external contributions, especially if retaining commercial ISGIN extensions. Keep any proprietary adapters or customer-specific policy packs in a separate private repository.

## Next release ideas

Configurable allowlist with expiry, rules mapped to internal policies, gMSA and service-account classifications, signed findings manifests, historical comparisons, severity review/triage status, machine-readable exit codes, constrained AD collection by partition, and optional ServiceNow/Jira evidence export.

To preview the synthetic findings without installing PowerShell, open [`docs/fixture-preview.html`](docs/fixture-preview.html). It is an **independently prepared expectation preview**, not an exported result from a PowerShell execution.