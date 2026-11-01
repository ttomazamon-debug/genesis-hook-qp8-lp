# Evidence and limits

The current hook is `0xd6155ce86ff3a33f52493e08cf77d7bbdf21fffc`.
Older C3 addresses, 24548-byte runtimes and historical dashboard counts must not
be substituted for this deployment. This is a routing dossier, not a security audit.

## Historical pre-activation execution

Eight exact-input swaps on a disposable Base fork passed the measured wallet,
Quoter and settlement checks. Both directions were tested with empty hookData.
Measured swap gas was 466200–478423 gas, excluding
approval transactions and any assertion of total mainnet/L1 fee cost.
Six scenarios used then-current policy, two used nonzero packed core protocol
fees 2048500 (=500 | 500<<12). Positive protocol accrual was 1071984001689 wei
WETH in the WETH-input case and 2499 raw USDC in the USDC-input case.

Minimum and deadline rejection controls passed all eight scenarios. The initial
exact-output control used incorrect opcode 0x07; a separate two-direction check
using opcode 0x08 passed with the expected hook selector 0xbcd02cf4. This explains
the original aggregate INCOMPLETE flags without relabelling the raw report.

These original tests used synthetic fork funding and rewards-off state. They do
not prove active-rewards positive realization or every router/partial-fill path.
The subsequent activation, positive realization and separately scoped
rewards-on checks are recorded in [post-activation evidence](POST_ACTIVATION_EVIDENCE.md).

## Quotes and competition

Direct V4 Quoter tests at block 53108856 returned positive outputs in 12/12 cases.
The table compares against the specific V3 fee-500 source pool, at the same pinned
block, before gas. WETH-input sizes are USDC-equivalent nominal sizes. It is not a
comparison against every DEX or against the unpinned aggregator routes.

| Direction | Nominal USDC | Genesis gross output edge vs sampled V3, bps |
|---|---:|---:|
| WETH_TO_USDC | 1 | -10.1151 |
| WETH_TO_USDC | 5 | -13.1626 |
| WETH_TO_USDC | 10 | -16.9635 |
| WETH_TO_USDC | 25 | -28.3490 |
| USDC_TO_WETH | 1 | 7.6033 |
| USDC_TO_WETH | 5 | 4.5523 |
| USDC_TO_WETH | 10 | 0.7413 |
| USDC_TO_WETH | 25 | -10.6745 |

Four of the twelve full quote-grid cases (including the 0.1-USDC case not shown
above) had positive gross edges. No blanket superior-execution or net-profit
claim follows. Uniswap returned 16 routes and Kyber 8 at the requested sizes;
none selected Genesis. Non-selection does not establish lack of support.

## Traffic provenance

The bounded window was 52971982–53071982: 185 Swap events, no missing queried
ranges. Sixteen sampled transaction receipts contained the pool event. Fourteen
shared tx.to/pool sender 0x563203867b12cf2405f415042db11f6fa9fb937b.
This historical window alone did not establish its strategy or organic status.
A later eight-transaction sample found arbitrage cycles; see the separately dated
[follow-up](POST_ACTIVATION_EVIDENCE.md#traffic-and-competition). Two available traces included Kyber's
router 0x6131b5fae19ea4f9d964eac0408e4408b66337b5 as ancestor of PoolManager:

- 0xe4cdbb6489c52339e695a7a3e33cbad1c937a3dfc98359d5eb957bc0a8487867
- 0xe8205e692ca5d1ab84c5df6de7a9f3e88582e6f26993afbc4c9dd831dea9321e

Trace inspection was bounded to depth 10 and 200 nodes and is not asserted to be
complete for all transactions. Kyber involvement in a historical transaction does
not mean a later quote must select the pool or prove Uniswap Labs eligibility.

## Remaining items

- The application was submitted successfully on 26 October 2026. This is not an allowlisting decision.
- The final pre-submission state observation was block 53111764: rewards disabled,
  controller unbound, unpaused, oracle age 12 versus limit 60 and nonzero pool
  liquidity. All twelve refreshed quotes were positive; two gross outputs exceeded
  the sampled V3 comparator (USDC to WETH, nominal 0.1 and 1 USDC). No later
  activation is inferred from this historical matrix. Later activation is separately
  receipt-verified in [dated state](STATUS.md). Contact details remain omitted.
- Factory remains unverified on Basescan in available evidence; independent
  Sourcify exact_match is linked. Do not explain its earlier mismatch error as
  caused by a later shared forwarding quota limit.
- OracleReader metadata fingerprint remains unresolved. Sourcify match proves
  executable correspondence; it is not exact original-source metadata recovery.
- Rewards activation is now documented separately. Keep subsequent configuration
  changes and their evidence dated; do not retroactively relabel this original matrix.
- Eligibility is a discretionary Uniswap review, not an application outcome
  established by these tests. No guaranteed processing time or traffic increase.

## Official references checked 26 October 2026

- https://developers.uniswap.org/hook-allowlist
- https://support.uniswap.org/hc/en-us/articles/48291859140621-Routing-for-hooked-pools
- https://developers.uniswap.org/docs/api-reference/aggregator_quote
- https://docs.sourcify.dev/docs/exact-match-vs-match/
- https://docs.sourcify.dev/docs/external-verifiers/
