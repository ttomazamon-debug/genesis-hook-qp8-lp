# GenesisHook QP8 LP

Reproducible source release for the deployed WETH/USDC Uniswap v4 hook on Base.
This repository contains the reviewed on-chain implementation and public build
evidence. Operational agents, signer configuration and private Git history are
not part of this release.

| Item | Value |
|---|---|
| Release | `qp8-lp-b958a867` |
| Network | Base Mainnet (`8453`) |
| Hook | [`0xd6155ce86ff3a33f52493e08cf77d7bbdf21fffc`](https://basescan.org/address/0xd6155ce86ff3a33f52493e08cf77d7bbdf21fffc#code) |
| Pool ID | `0xa409963d0e77a8f60d8d83caa7d3cd5b831d6e318ec3880b34ec3fff5a109cfe` |
| Deployment block | `52945855` |
| Pool key | WETH / native USDC; dynamic-fee flag `8388608`; tick spacing `100` |
| Hook runtime | `24214` bytes; low-14 permission mask `0x3ffc` |
| Compiler | `0.8.33+commit.64118f21`, viaIR, optimizer 200, Cancun |

## Scope and limitations

The hook supports **exact-input only**. Standard Universal Router 2.0 execution
with empty `hookData` was exercised on disposable Base forks in both directions.
Exact-output requests are deliberately rejected. Two fixed linked libraries,
AmpLib and GenesisDistLib, are part of the deployed implementation.

Dynamic fees use flow and price-dislocation inputs. An optional economics path
can settle trader rebates through PoolManager and allocate other shares through
the controller. LP rewards use position-indexed claims without an on-chain
minimum claim amount. Production names including `GenesisLpClaimsPrototype` and
`ReviewLedgerFactory` are preserved because changing names or source would break
the identity of the reviewed release; their names do not imply an audit.

Economics was activated through Safe on **26 October 2026**, block **53122259**.
Subsequent observations confirm the bound controller, rewards enabled and a
**40 / 35 / 20 / 0 / 5** trader / LP / protocol / router / keeper split of realized
economics. These percentages do not replace the native pool LP fee or the
separate **50-pips (0.005%)** operator fee.

The tracked native LP position is **NFT 3182122**, range **[-199900, -198500)**.
The earlier NFT 3162691 was fully exited; the recentered range retains its
1400-tick width. The hook, pool ID and frozen deployed sources are unchanged.
See [dated deployment state](docs/STATUS.md),
[post-activation evidence](docs/POST_ACTIVATION_EVIDENCE.md) and the public
[state snapshot](evidence/state-2026-11-01.json). These are historical
observations, not a live status endpoint or a security audit.

A Uniswap Labs routing review application was successfully submitted on
26 October 2026. **Submission is not approval, an audit or an endorsement.**
No independent published security audit is claimed. Historical test counts from
older releases must not be attributed to this source release.

## Review and reproduce

```sh
python3 scripts/verify_release.py
solc --version
solc --standard-json < compiler-inputs/GenesisHookV5.json > hook-output.json
python3 scripts/check_compiler_output.py GenesisHookV5 hook-output.json
```

Use the exact compiler version above. Each standard JSON input contains its own
complete source closure, original source-unit names and linked addresses; it
does not require private dependencies or RPC credentials. See [build notes](docs/BUILD.md).
This source export deliberately has no deployment workflow or signing command.
CI checks release integrity, not smart-contract correctness or profitability.

Nine components have Etherscan/Base verification records. The factory has
Sourcify **exact_match**; OracleReader has **match**, with unresolved original
metadata. See the [verification matrix](docs/VERIFICATION.md) and
[deployment registry](deployments/base-8453.json).

## Documentation

- [Dated deployment state](docs/STATUS.md)
- [Post-activation accounting, routing and test evidence](docs/POST_ACTIVATION_EVIDENCE.md)
- [Documentation changes](CHANGELOG.md)
- [Architecture and trust boundaries](docs/ARCHITECTURE.md)
- [Routing evidence and its limits](docs/EVIDENCE.md)
- [Security reporting](SECURITY.md)
- [Public/private publication policy](docs/PUBLICATION_POLICY.md)
- [Historical release boundaries](docs/HISTORY.md)
- [Licensing and third-party notices](LICENSE.md)

Token balances, TVL, observed addresses and router selection are not evidence of
organic users or guaranteed trading advantage. Gross quote outputs must not be
presented as gas-adjusted returns or LP profit.
