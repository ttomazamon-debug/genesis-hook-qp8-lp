# Dated deployment state

Documentation revision: **1 November 2026**. Source release remains
`qp8-lp-b958a867`; the deployed source/compiler identity has not changed.

The latest read-only check is Base block **53367892**, at
**2026-11-01T09:25:31+00:00**. This page is a dated snapshot, not a live status service.

| Property | Observed value |
|---|---|
| Hook | `0xd6155ce86ff3a33f52493e08cf77d7bbdf21fffc` |
| Pool ID | `0xa409963d0e77a8f60d8d83caa7d3cd5b831d6e318ec3880b34ec3fff5a109cfe` |
| Economics / rewards | Enabled |
| Hook paused | No |
| Bound controller | `0x3c82568d97c60fc0f771d9d13f33d6d07a381600` |
| Realized-economics split | Trader 40%, LP 35%, protocol 20%, router 0%, keeper 5% |
| Separate operator fee | 50 pips = 0.005% = 0.5 bps |
| LP claims ledger | `0xffe2fe138a4a4ed68c9620eaaa783c681374c096` |
| Tracked native NFT | 3182122 |
| Position range | [-199900, -198500), width 1400 ticks |
| Tracked / active liquidity | `268318444327370` |
| Core / ledger tick | `-199034`, matching |
| Core / ledger liquidity and adapter nonce | Matching |
| Internal oracle age | 18 blocks; configured limit 60 |
| Eight deployment runtime hashes | Match the existing deployment reference |

## Activation and realized event

The [Safe activation transaction](https://basescan.org/tx/0xc3c846e6a4789b77dacba7b597f71008ad4579783010607c8b67cccc86701cc7)
succeeded at block **53122259** on **26 October 2026**. Its canonical receipt,
Safe ExecutionSuccess and hook RewardsEnabledChanged(true) event were checked.
The earlier rewards-off/controller-unbound observation at block 53111764 is
historical and is retained in the registry; it is not the latest state.

The first separately documented positive EconomicsRealized receipt is block
**53123091**, [transaction](https://basescan.org/tx/0x527b754342ff090b71728846bee68bd5d8bf00c37e9851095b5e95df25140792).
A successful event is evidence of occurrence, not an independent audit or proof
that all reachable states are safe or that trading is profitable.

## Position recentering

NFT 3162691 was fully exited at block **53286650**:
[exit receipt](https://basescan.org/tx/0x8a66428085b11f791b4894880559885641380805bb45af0cc62149fb11e715e8).
NFT 3182122 was minted at block **53300954**:
[mint receipt](https://basescan.org/tx/0xd5319a8cb5c88bbca49eee12136dd1c66758c8a27af8159e1411c1f9afeccbc8).
The range moved from [-199200, -197800) to [-199900, -198500): both bounds
shifted by -700 ticks; width stayed 1400. The old NFT currently has zero liquidity.
This changed the LP position, not the hook/pool identity or frozen source release.
The public snapshot tracks this position; it is not a guarantee that no other
position may ever exist.

## Routing application

The repository records an application submission on **26 October 2026**. No
approval, endorsement or completion of an independent audit is asserted. An
unanswered application is not evidence of acceptance, rejection, or a specific
processing deadline. Technical execution support and actual route selection
are separate questions.

Machine-readable references: [state snapshot](../evidence/state-2026-11-01.json),
[first realization](../evidence/first-realization-2026-10-26.json),
[deployment registry](../deployments/base-8453.json).
