# Security policy

This release is a source-verification and engineering-evidence publication.
It is not a security audit or a guarantee that the deployed system is bug-free.

## Report privately

Use GitHub's **Report a vulnerability** entry on the repository Security page
when private vulnerability reporting is enabled. A SECURITY.md file alone does
not enable that feature. If that entry is absent, open an issue requesting a
private reporting channel **without including vulnerability details**.

Do not publish exploit instructions, secrets, private keys or live credentials
in issues, pull requests, CI logs or public discussions. No bounty or response
deadline is promised by this policy.

## Supported deployment identity

This publication documents the Base deployment at
`0xd6155ce86ff3a33f52493e08cf77d7bbdf21fffc` and the contracts listed in
`deployments/base-8453.json`. It does not designate historical deployments as
currently maintained or claim that every possible configuration is tested.

## Trust and operations

The Safe controls operator policies; not all changes are timelocked. Governor
and selected controller operations have separate delay rules. LP adapter
administration is held separately. Public addresses and authority relationships
are intentionally documented and must not be hidden as operational secrets.

Production keys, passwords, RPC/API tokens, environment files, signing hosts,
systemd files and keeper automation belong outside this repository. No deployer
or keeper key is required by the public build or CI.
