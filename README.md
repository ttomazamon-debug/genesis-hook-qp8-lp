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

At the last full routing-state observation, block **53111764** on 26 October
2026, the hook was unpaused, rewards disabled and the hook's controller unbound.
These are dated observations, not a live status endpoint. Rewards-enabled
realization is not proven by that rewards-off routing matrix. Read deployed
state again before operational decisions.

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

- [Architecture and trust boundaries](docs/ARCHITECTURE.md)
- [Routing evidence and its limits](docs/EVIDENCE.md)
- [Security reporting](SECURITY.md)
- [Public/private publication policy](docs/PUBLICATION_POLICY.md)
- [Historical release boundaries](docs/HISTORY.md)
- [Licensing and third-party notices](LICENSE.md)

Token balances, TVL, observed addresses and router selection are not evidence of
organic users or guaranteed trading advantage. Gross quote outputs must not be
presented as gas-adjusted returns or LP profit.
