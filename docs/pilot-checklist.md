# ISGIN read-only pilot checklist

## Before access

- [ ] Confirm an internal sponsor, written authorization, and domain/security team sign-off.
- [ ] Define the target domain, user OU, dates, and approved hours. Avoid tenant/domain-wide rollout initially.
- [ ] Review which AD attributes will be visible to the service/operator account; use least privilege and existing credentials.
- [ ] Set an approved, restricted output folder and explicit retention/delete policy.
- [ ] Review the ten rule definitions, risk severities, and privileged group list with IAM owners.
- [ ] Confirm the AD environment permits query volume for **all groups in the domain**, even when users are scoped to an OU.

## Dry run

- [ ] Install PowerShell 7.2+ and (if live) RSAT ActiveDirectory on the Windows runner.
- [ ] Run synthetic mode first; expect 11 users, 6 groups and 12 findings with pinned date.
- [ ] Run Pester 5 tests; confirm test suite passes before expanding scope.
- [ ] Run live mode against a small OU using read-only directory access.
- [ ] Inspect unresolved group references; investigate gaps before relying on privileged membership findings.
- [ ] Validate sampled findings against ADUC / approved sign-in or access logs, respecting access controls.

## Results and decision gate

- [ ] Secure and share only with named IAM/security reviewers.
- [ ] Assign each finding `investigate`, `approved exception`, `false positive`, or `action recommended` **outside this MVP**.
- [ ] Track changes through an existing approved change-management workflow; this tool intentionally cannot remediate.
- [ ] Delete intermediate/export files at the end of the retention window.
- [ ] Decide whether to extend to service-account classification, allowlists, recurring diffs and approved audit integrations.
