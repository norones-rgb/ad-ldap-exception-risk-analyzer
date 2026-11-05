# Design & architecture

```text
                    Invoke-AdExceptionAnalyzer.ps1
                                 |
                        Read-AnalyzerConfig
                                 |
               +-----------------+-----------------+
               |                                   |
          CSV importer                  AD read-only collector
        (users / groups)               (Get-ADUser, Get-ADGroup)
               |                                   |
               +-----------------+-----------------+
                                 |
                  Normalize / validate records
                                 |
                 Build group DN -> group lookup
                                 |
                     Nested group traversal
                     (BFS, cycle detection)
                                 |
                       Evaluate ten rules
                                 |
               Findings + completeness warnings
                                 |
                       CSV / JSON / HTML
```

## Contracts and trust boundaries

Inputs are local CSV files or read-only domain queries; configuration is a JSON file. The module normalizes dates to UTC, Boolean values to true/false, memberships to arrays of distinguished names, and groups to canonical fields. A duplicated group or user DN halts the run. It deliberately doesn't infer missing AD values to be secure.

Collection errors are terminating. Unresolved group links are counted and attached to summary evidence (not silently skipped). The group graph uses a visited set to terminate cycles. Group lookup is DN-based rather than ambiguous short name-based. Privilege recognition matches configurable SamAccountName entries or known SID suffixes, and traverses nested groups.

Outputs are only local report files. HTML is self-contained, has no remote assets or JavaScript, and HTML-encodes untrusted directory values; CSV text beginning with spreadsheet formula operators is prefixed with an apostrophe. The generated report names contain UTC timestamps to avoid accidental overwrites. This release does not yet implement transactional multi-file exports; protect the output directory and monitor write errors.

## Scope boundaries

- Querying a user OU does **not** restrict the domain-wide group query; nested group resolution requires groups outside that OU.
- AD mode targets one domain/session; the module does not promise complete forest-wide evaluation or external trust resolution.
- Enumerating all groups can be expensive at enterprise scale. Execute during an approved window with a tightly scoped pilot user OU and coordinate domain-controller load before expanding.
- The script analyzes raw risk signals, not effective rights, actual account use, or exceptions approved in an access governance system.
- `MemberOf` omits primary-group membership. This MVP does not inspect `primaryGroupID`, so a primary-group path can be missed.

## Safety and privacy

No write-capable AD commands or network exfiltration features exist in the module. CSV, JSON, and HTML reports may contain directory identities and privileged group information and require appropriate local access controls, retention, and disposal. Only synthetic data should enter public CI or public repository commits.
