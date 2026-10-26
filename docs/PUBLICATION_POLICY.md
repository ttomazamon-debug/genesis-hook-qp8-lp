# Public/private boundary

## Public source repository

Include exact reviewed Solidity source, public interfaces/ABIs, source licenses,
standard compiler inputs, artifact templates, public contract addresses, trust
relationships and dated verification/routing observations. Source paths inside
compiler inputs are required for reproducibility. Do not edit deployed source
comments in place: even a comment can change metadata and verification identity.

Changes intended for a future deployment belong to a separately named release.
The source tree here is a frozen build reference, not the operations working
directory. Never publish a new release by making an old private repository
public or by merging its history into this clean source repository.

## Private operations

Keeper agents, execution strategies, scheduling, dashboards, systemd services,
monitoring schemas and recovery runbooks may remain in an independent private
operations repository. Keeping this automation private is a scope decision,
not a substitute for securing public smart contracts.

Never commit secrets even to the private repository: private keys, mnemonics,
passwords, keystores, RPC/API credentials, environment files, database contents,
raw service logs, signed transaction caches, local backups or unpublished
vulnerability reports. Store secrets outside Git and use narrowly scoped
credential stores where needed.

## Release procedure

1. Export from verified compiler inputs using an explicit allowlist.
2. Check source identity, release manifest, licensing notices and secret patterns.
3. Recompile with the pinned Solidity version; preserve linking and immutables.
4. Publish to a clean repository and review the actual committed file list.
5. Enable secret scanning/push protection and private vulnerability reporting
   where available; configure branch rules. Verify settings rather than merely
   documenting an intention to enable them.

CI must have read-only contents permissions, no production secrets, no self-hosted
production runner, and pinned third-party actions. Deployment/signing workflows
are outside the public repository. `pull_request_target` is not required here.

Ignore rules are defense in depth: they do not remove files already tracked or
secrets already committed. Revoke/rotate exposed credentials before considering
history cleanup. Archived repositories retain their history and visibility.
