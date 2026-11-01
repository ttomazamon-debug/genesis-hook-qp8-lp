# Architecture and trust boundaries

## Deployed execution

- `GenesisHookV5` implements swap/liquidity callbacks and dynamic fee policy.
- `AmpLib` and `GenesisDistLib` are fixed external linked libraries. Both must
  be included when reviewing the deployed execution. CREATE2 deployment through
  a deterministic factory is not an upgradeable execution proxy.
- `GenesisControllerGovernor` manages delayed controller binding/replacement.
- `GenesisRewardsController` and the new `GenesisVaultV2` implement optional
  economics accounting and custody. Binding does not itself enable rewards.
- `PosmTraceAdapter`, `ReviewLedgerFactory`, and `GenesisLpClaimsPrototype`
  implement position-indexed LP attribution and claims. Some source/compiler
  names retain historical prototype terminology; their exact bytes are retained.
- `GenesisV52Oracle` supplies the external value read. Its Sourcify metadata
  match level is disclosed separately from exact verification.

The historical `GenesisClaimVault` remains immutably bound to an older hook.
In this release it supplies an external-balance read/telemetry dependency and
must not be described as the newly authorized rewards payout vault.

## Attribution and routing

Empty `hookData` does not require a trusted alternate-beneficiary router.
When internal user equals callback sender, the realization path uses zero for
separately attributed user, settles trader share through PoolManager and returns
the output-currency delta. This is not a claim of transferring a rebate to the
router as its own income. Explicit alternate-beneficiary attribution and router
reward registration are separate controls.

Exact-output swaps are deliberately unsupported. Standard router cases used
Universal Router 2.0, not an assertion about every future router version or
arbitrary multihop composition.

## Authority

Safe `0xf84d2025ce5fbe87ff78951383befE5693169e23` is the operator/governance
authority. Operator controls include pool/source policy, selected fee and bonus
settings, keeper/staleness policy, trusted attribution and rewards activation.
Not every setter has a timelock. Controller/governor delays and one-time
bindings are separate mechanisms, not a blanket governance delay.

Adapter administrator `0x267bf3edd2b1beae13a5f3803fd24c866cd098e1` is a
separate authority. The code's read/trace and custody dependencies can affect
execution availability; not every dependency failure is caught or fail-open.
Do not infer permissionlessness or unconditional exit guarantees from the name
of a component.

## LP rewards

LP entitlements use position-indexed accounting. Users claim accumulated
amounts; no contract-level minimum claim amount is imposed. This differs from
legacy epoch donations, so a zero legacy donation counter is not proof that the
new claim architecture is absent or broken. Rounding reserves and capped
remainders must not be marketed as automatically realized income.

## Post-activation observations

Economics was enabled at block 53122259 with the controller bound to this hook.
The observed split is 40/35/20/0/5; see [dated state](STATUS.md). Ordinary native
LP fees, the operator fee and position-indexed realized-economics rewards are
separate accounting streams. An enabled flag does not imply every swap will
realize or distribute economics, or that any return is profitable after costs.

The LP ledger authorizes its bound adapter to record traces. It does not
independently prove that the supplied list contains every initialized crossed
tick. Native-path tests provide bounded evidence, not an independent guarantee
of trace completeness in every possible state. Oracle, custody and settlement
dependencies can affect availability. Successful rollback/rejection tests do
not establish unconditional execution or a comprehensive security audit.
