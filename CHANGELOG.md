# Documentation changes

## 2026-11-01

- Record canonical Safe economics activation and the subsequent positive
  controller realization, including split and integer rounding.
- Replace the latest rewards-off snapshot with a dated rewards-on observation;
  retain the original pre-activation observation as historical evidence.
- Record tracked NFT 3182122 and the same-width LP range recentering.
- Add bounded post-activation integration/quote observations and actual
  100-pips counterpart pool context; separate raw quotes from gas and LP profit.
- Preserve the frozen deployed sources, compiler inputs, ABIs and verification
  records. Operational automation and unpublished security material remain
  private. No deployment, signing workflow or production change is added.

This revision updates documentation for `qp8-lp-b958a867`; it does not designate
a new contract release, an independent audit, or Uniswap routing approval.
