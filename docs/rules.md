# Risk rules (MVP v0.1)

All detections evaluate as of a specific UTC reference timestamp. Severity is **a review priority chosen for this demo**, not a universal or regulatory risk score. Confirm policy, account type, business need, and other telemetry before remediation.

| Rule | Condition | Why investigate / caution |
|---|---|---|
| `PRIV-001` | `Enabled=False` and any resolved direct/nested group is classified as privileged | May reflect stale access group hygiene; disabled account cannot ordinarily authenticate, so severity needs local tuning |
| `PRIV-002` | `Enabled=True`, privileged membership, and last logon older than `InactiveDays`, or no logon and created before `NeverLoggedOnDays` | Privilege may be unnecessary; last logon is approximate |
| `AUTH-001` | `Enabled=True` and `DoesNotRequirePreAuth=True` | Kerberos preauth exception can increase exposure; investigate service design |
| `AUTH-002` | `Enabled=True` and `TrustedForDelegation=True` | Unconstrained delegation deserves review; confirm whether explicitly approved |
| `AUTH-003` | `Enabled=True` and `PasswordNotRequired=True` | Attribute is an account-control flag; **does not prove a blank password** |
| `LIFE-001` | `Enabled=True` and `AccountExpirationDate` strictly earlier than scan reference time | Account remained enabled past its stated expiration |
| `LIFE-002` | `Enabled=True`, non-null `LastLogonDate` strictly before reference time minus `InactiveDays` | Replicated LastLogonDate is approximate; confirm using logs |
| `LIFE-003` | `Enabled=True`, `LastLogonDate` absent, and `WhenCreated` strictly before reference time minus `NeverLoggedOnDays` | New accounts receive a grace period; missing logon data can also be a collector/scope artifact |
| `PASS-001` | `Enabled=True` and `PasswordNeverExpires=True` | Could be an approved service account; check gMSA suitability and exceptions |
| `GROUP-001` | `Enabled=False` and one or more direct `MemberOf` DNs | Residual access group membership requires retention/offboarding policy review |

## Config defaults

- `InactiveDays`: **90**
- `NeverLoggedOnDays`: **30**
- `PrivilegedGroupNames`: built-in high-impact group names, adjustable per domain
- `PrivilegedGroupSidSuffixes`: known AD privileged domain RIDs and built-in security authority SIDs

## Known detection gaps

1. LastLogonDate is an AD calculated/replicated approximation, not real-time access history. Does not include every application login.
2. AD `MemberOf` generally excludes a principal's **primary group**. Group nesting outside the queried domain or unresolved foreign security principals can be missed.
3. Rules do not calculate effective privileges, evaluate custom delegated OU ACLs, or discover group names beyond configured built-ins.
4. SPN presence is only displayed to contextualize the non-expiring-password signal; it is not authoritative service-account classification.
5. All results require identity owner, policy exception, and business context. This is a risk review tool rather than a self-remediation tool.

## Fixture expectations (2026-11-05 12:00 UTC)

| Account | Expected rule IDs |
|---|---|
| `alice.admin` | `PRIV-002`, `LIFE-002` |
| `bob.disabled` | `PRIV-001`, `GROUP-001` |
| `svc.legacy` | `AUTH-002`, `PASS-001` |
| `charlie.user` | `LIFE-002` |
| `dana.expired` | `LIFE-001` |
| `eve.preauth` | `AUTH-001` |
| `frank.nopass` | `AUTH-003` |
| `grace.new` | none |
| `henry.disabled` | `GROUP-001` |
| `ivan.active` | none |
| `jane.never` | `LIFE-003` |

Totals: **12 findings** (1 Critical, 5 High, 6 Medium).
