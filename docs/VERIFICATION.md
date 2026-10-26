# Public source verification evidence

Reviewed 26 October 2026. Nine successful Etherscan/Base verification records,
one Sourcify exact_match and one Sourcify match. These are not eleven exact
matches on Basescan. Source verification establishes correspondence to code,
not routing approval, a security audit, or absence of bugs.

| Contract | Address | Verified evidence | Link |
|---|---|---|---|
| AmpLib | `0x007dd8272788dd705e0bb4746df23806eb8f4f69` | Etherscan/Base verified; published sources match reviewed input | [Code](https://basescan.org/address/0x007dd8272788dd705e0bb4746df23806eb8f4f69#code) |
| GenesisDistLib | `0xbfe72deb3902f871a1a46384f5e66c184aceeff7` | Etherscan/Base verified; published sources match reviewed input | [Code](https://basescan.org/address/0xbfe72deb3902f871a1a46384f5e66c184aceeff7#code) |
| GenesisControllerGovernor | `0x4ea83b22845eb4a1961b4cb6bebc13f230e84772` | Etherscan/Base verified; published sources match reviewed input | [Code](https://basescan.org/address/0x4ea83b22845eb4a1961b4cb6bebc13f230e84772#code) |
| GenesisHookV5 | `0xd6155ce86ff3a33f52493e08cf77d7bbdf21fffc` | Etherscan/Base verified; published sources match reviewed input | [Code](https://basescan.org/address/0xd6155ce86ff3a33f52493e08cf77d7bbdf21fffc#code) |
| GenesisVaultV2 | `0x73945fc73817087fc58e6e6f80f04f18c5604158` | Etherscan/Base verified; published sources match reviewed input | [Code](https://basescan.org/address/0x73945fc73817087fc58e6e6f80f04f18c5604158#code) |
| GenesisRewardsController | `0x3c82568d97c60fc0f771d9d13f33d6d07a381600` | Etherscan/Base verified; published sources match reviewed input | [Code](https://basescan.org/address/0x3c82568d97c60fc0f771d9d13f33d6d07a381600#code) |
| ReviewLedgerFactory | `0xfdface7d4184802ba525c4ffcc502c249e680def` | Sourcify exact_match (creation and runtime); Basescan not verified in the reviewed evidence | [Code](https://repo.sourcify.dev/8453/0xfdface7d4184802ba525c4ffcc502c249e680def) |
| PosmTraceAdapter | `0xb7633630857e862ba81aa27decabcc7679aba7e4` | Etherscan/Base verified; published sources match reviewed input | [Code](https://basescan.org/address/0xb7633630857e862ba81aa27decabcc7679aba7e4#code) |
| GenesisLpClaimsPrototype | `0xffe2fe138a4a4ed68c9620eaaa783c681374c096` | Etherscan/Base verified; published sources match reviewed input | [Code](https://basescan.org/address/0xffe2fe138a4a4ed68c9620eaaa783c681374c096#code) |
| GenesisV52Oracle | `0x1d609949f0e79cfd7cb3dd11984be5b59634b684` | Sourcify match (creation and runtime); original metadata unresolved; not exact_match | [Code](https://repo.sourcify.dev/8453/0x1d609949f0e79cfd7cb3dd11984be5b59634b684) |
| GenesisClaimVault | `0x27a8f72140f9d62bd7bcfe4afb20e76b6fbd4f41` | Etherscan/Base verified; exact creation proof with original constructor and immutable hook | [Code](https://basescan.org/address/0x27a8f72140f9d62bd7bcfe4afb20e76b6fbd4f41#code) |

Factory's Basescan mismatch message is unresolved despite independently matching
creation input and complete runtime. Sourcify reproduced an exact creation and
runtime match. The later external Etherscan forwarding limit is a different
event; it must not be claimed as the cause of the earlier mismatch rejection.

OracleReader has a verified execution match, with a different metadata hash.
Archive reads located its original direct deployment transaction:
`0x9cc585b542da3d1f0b2b8d862cc387064025b0f89ab92c3b3ef96afd719a53f0`,
block 51126512. Its on-chain original metadata CID is
`QmSCvhdp2UENieWe3RnLphaze4V6dKsetQxTKqxUTwND6k`. Gateway reads returned
HTTP 429; no claim is made that the original metadata is recovered or absent.

ClaimVault's original direct deployment was
`0xe2b288f90d982fcd308123e748314266bbcfa212fd236751b9150216164a805f`,
block 49178792. Its constructor was old genesisHook
`0x86623e2c790116d74e68b1bebeaf142d15787ffc` and operator Safe
`0xf84d2025ce5fbe87ff78951383befE5693169e23`. Current operator state is not
used as a substitute for the original constructor arguments.
