# Reproducing the review inputs

This release contains public Solidity source and standard compiler inputs only.
It is a review export, not a deployment or activation runner. It contains no
keystore, environment file, API key, signing command or production-service config.

Use Solidity `0.8.33+commit.64118f21`, viaIR, optimizer 200 runs and Cancun exactly
as encoded in each standard JSON input. Linked library addresses are included in
`settings.libraries`; do not replace them with older C3 addresses.

Example with an already available matching compiler:

```bash
solc --version
solc --standard-json < compiler-inputs/GenesisHookV5.json > hook-compiler-output.json
```

The output contains JSON diagnostics; check `errors[].severity` rather than only
the process exit code. Compare creation bytecode to the artifact and constructor
suffix to the actual deployment transaction. Runtime immutables must be populated
with constructor values before a full on-chain byte-for-byte comparison. Solidity
libraries can also contain a deployment self-address. No stripping of executable
code or arbitrary byte ranges is an exact-verification procedure.

Nine `artifacts` files correspond to the eight-contract deployment plus
the subsequently created LP ledger. Their creation/runtime templates and raw
metadata were recompiled exactly in this review. The eight original deployment
inputs were checked against actual mined transactions; the ledger was checked
against its factory-created runtime and roles and later verified on Basescan.

The legacy ClaimVault input was independently recompiled exactly and checked
against its original deployment with constructor arguments extracted from that
transaction. Its immutable `genesisHook` is an old hook address, not the new hook.

The legacy OracleReader input recompiles its documented candidate exactly, and
the resulting executable creation/runtime bytes match deployment, but metadata
differs from the original chain fingerprint. Sourcify therefore reports `match`;
do not call this an exact original-source reconstruction.

Source bytes from multiple inputs are deduplicated only if they are identical.
Original Solidity SPDX notices are preserved. `release-sha256.json` inventories
release files. `evidence/` contains normalized observations with provenance
hashes for the uploaded raw reports; it does not replace an independent audit.
