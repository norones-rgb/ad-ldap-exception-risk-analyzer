# Security policy and handling

This is a **read-only identity assessment demo**. It does not authenticate using stored secrets, change accounts, change group memberships, call external APIs, or transmit scanned directory data outside the specified execution environment. It writes CSV/JSON/HTML locally.

The live AD collector uses the operator's existing Windows identity and read permissions. Use approved directory access and start with a user OU pilot. Directory identities, group memberships, and privilege findings are potentially sensitive; store reports in a restricted location and never commit them to public GitHub repositories.

## Responsible disclosure

If you discover an issue in the demo, open a security advisory/private report through the hosting platform rather than publishing production identity data in an issue. Do not include real directory exports or credentials in bug reports.

## Not a compliance certification

The analyzer cannot guarantee directory inventory completeness, cross-domain group accuracy, or real-world compromise status. Use findings for authorized validation and review.
