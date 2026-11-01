# Post-activation evidence and limits

Review date: **1 November 2026**. This updates the operational observations for
the same deployed QP8 LP source release. It is engineering evidence, not an
independent security audit, approval, or profitability claim.

## Activation and positive realized accounting

The Safe activation succeeded at block **53122259**. The controller is bound and
rewards are enabled in the later [dated state](STATUS.md). The observed realized
split is trader/LP/protocol/router/keeper **40/35/20/0/5**.

The first separately receipt-verified controller EconomicsRealized event is
[transaction 0x527b75…140792](https://basescan.org/tx/0x527b754342ff090b71728846bee68bd5d8bf00c37e9851095b5e95df25140792),
block **53123091**. Its raw six-decimal USDC accounting is:

| Bucket | Raw USDC units |
|---|---:|
| Gross realization | 8 |
| Trader share | 3 |
| LP share | 2 |
| Protocol share | 1 |
| Router share | 0 |
| Keeper share | 0 |
| Rounding dust | 2 |
| Capped trader remainder | 0 |

The allocations plus dust equal the gross amount. Integer rounding explains why
these small values do not exactly display the percentage split. Gross 8 means
**0.000008 USDC**, not 8 USDC. This proves a positive realized event occurred;
it does not prove an economically significant reward stream.

Ordinary native LP fees, the separate operator fee, and realized-economics
allocations are different streams. The nominal LP 35% applies to realized
economics, not 35% of all swap volume. Position indexing can leave funded
reserves greater than an immediately claimable per-NFT amount due to rounding.
A ledger balance, a vault balance and a per-position pending claim are different
quantities. Do not add them as separate income.

The first event is described by the [public receipt excerpt](../evidence/first-realization-2026-10-26.json).
It is not a claim that every future swap realizes economics or that LP returns
exceed holding the entry tokens after gas, migration costs and price changes.

## Rewards-on execution checks

Later disposable-fork checks exercised the deployed production WETH18/USDC6
pool through the existing Universal Router with empty hookData, rewards ON and
`operatorFeePips = 50`, in both directions. The 1 November quote controls use nominal
0.1/1/5/10/25/50 USDC sizes and are distinct from the earlier rewards-off routing
matrix in [historical evidence](EVIDENCE.md).

Fifteen additional project-run bounded integration tests passed against deployed Base
PoolManager/PositionManager/Permit2/Universal Router infrastructure, using a
fresh test-token pair and a source-identical test Genesis deployment. They
cover full/partial inputs, two consecutive v4 pool actions, token cleanup and
minimum/deadline/output-transfer rejection controls. The test pair uses 18/18
decimals and spacing 10; this must not be relabelled as all combinations of the
production 18/6, spacing 100 state.

Two separate full-fill production controls found identical output and input
spend for ordinary and prepaid standard UR action ordering. Prepayment measured
**985 additional invocation-gas units in each direction**. These are local
invocation measurements, not complete paid Base transaction costs: calldata,
L1 publication, tips and approval costs are excluded. No prepayment integration
or new router has been installed. It is not advertised as a gas optimization.

These finite checks do not cover all paths, token behavior, callback sequences
or governance states. They do not establish unconditional availability or prove
adapter trace completeness universally. Detailed unpublished security review
material and private operational reports remain outside the public release,
as required by [publication policy](PUBLICATION_POLICY.md).

## Traffic and competition

A later bounded sample of eight distinct transactions to
`0x563203867b12cf2405f415042db11f6fa9fb937b` shows arbitrage cycles, comprising:

- Four Genesis / Uniswap v3 WETH/USDC 100-pips pool cycles:
  `0xb4cb800910b228ed3d0834cf79d697127bbb00e5`.
- Three Genesis / Pancake v3 WETH/USDC 100-pips pool cycles:
  `0x72ab388e2e2f6facef59e3c3fa2c4e29011c2d38`.
- One cycle through Genesis and two other v4 pools.

This executor is distinct from the canonical UR used in the tests. The sample
shows strategy behavior, not the executor owner's identity, independent users,
organic activity, or proof of Uniswap Labs routing inclusion. Receipt evidence
is distinct from parent-state scenario replays; unavailable full canonical
traces were not counted as completed reconstructions. The sample is targeted,
not random and not an attribution of all historical swaps to one actor.

On block **53365964**, two matched grids compared the same raw input and direction
from the same starting state against the actual 100-pips counterpart pools.
Each grid contains 12 pairs: two directions at 0.1/1/5/10/25/50 nominal USDC.
Genesis gross-output wins were **0/12 against each comparator**. This is a dated
sample, not a claim about every state or routing market share.

At nominal 10 USDC, before gas:

| Direction | Genesis edge vs Uniswap v3 | Genesis edge vs Pancake v3 |
|---|---:|---:|
| WETH to USDC | -9.0789 bps | -10.4410 bps |
| USDC to WETH | -15.4758 bps | -14.1853 bps |

Genesis selected LP fee 500 pips in this grid, counterpart pools 100 pips, and the
separate operator fee remained 50 pips. The approximate fee difference alone is
4 bps LP fee plus 0.5 bps operator; depth and pool-price differences also matter.
The earlier fee 500 V3 benchmark remains a historical comparison, not a complete
account of these actual counterpart routes. No fee change or new deployment is
recommended solely from this sample.

Genesis and Uniswap legs used actual UR executions; the Pancake leg used its
native swap/callback directly. That latter control compares raw outputs only,
not wrapper gas. Synthetic test-wallet funding is used only on disposable forks.
Each pair uses exactly the same raw input; WETH-side nominal USDC values use the
respective comparator's starting price and must not be mistaken for an exactly
equal WETH input across different benchmark grids.

A fixed executor instruction was also evaluated in five controlled parent-block
scenarios. Small local swaps changing Genesis state changed whether the cycle
was accepted. Such perturbations alter flow/backing as well as price; they do
not establish a universal isolated price threshold or explain the entire
historical volume decline. Arbitrage opportunities and best retail execution
are different measurements. More swaps do not necessarily imply higher net LP
returns.

Public data: [quote CSV](../evidence/quotes-2026-11-01.csv),
[bounded review summary](../evidence/post-activation-review-summary.json).
No production keys, agents, service files, dashboards or private logs are
included in these excerpts.
