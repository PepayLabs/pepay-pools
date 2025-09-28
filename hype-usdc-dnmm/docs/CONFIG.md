# Configuration Artifacts

## Overview
All runtime parameters for the HYPE/USDC DNMM live under `config/` and are designed to be environment-agnostic. Populate these files before deployment or simulation runs.

### `parameters_default.json`
Derived from Lifinity's SOL/USDC configuration (see `lifinity-contract/CONFIGURATION_VALUES.md` and `lifinity_pools_oracle_config.json`).

| Field | Description | Default |
|-------|-------------|---------|
| `oracle.hypercore.confCapBpsSpot` | Confidence cap used for spot/normal quotes. | `100` bps |
| `oracle.hypercore.confCapBpsStrict` | Confidence cap for strict operations (e.g. RFQ). | `100` bps |
| `oracle.hypercore.maxAgeSec` | Max allowed age of HyperCore data (slots→seconds). | `48` sec |
| `oracle.hypercore.stallWindowSec` | EMA fallback stall window. | `10` sec |
| `oracle.hypercore.allowEmaFallback` | Enables EMA fallback when spot fails. | `true` |
| `oracle.hypercore.divergenceBps` | Max deviation vs. Pyth before rejection. | `50` bps |
| `oracle.hypercore.confWeightSpreadBps` | Weight applied to HyperCore spread when blending confidence (1.0 = 10000). | `10000` |
| `oracle.hypercore.confWeightSigmaBps` | Weight applied to EWMA sigma when blending confidence. | `10000` |
| `oracle.hypercore.confWeightPythBps` | Weight applied to Pyth confidence when blending confidence. | `10000` |
| `oracle.hypercore.sigmaEwmaLambdaBps` | EWMA smoothing factor λ (1.0 = 10000) for sigma updates. | `9000` |
| `fee.*` | Lifinity α/β/cap/decay coefficients. | See file |
| `inventory.floorBps` | Minimum side inventory retained. | `300` bps |
| `inventory.recenterThresholdPct` | Price move threshold for `x*` updates. | `750` (7.5%) |
| `maker.*` | On-chain S0 + TTL for RFQ quotes. | S0=`5000`, ttl=`200ms` |

### Feature Flags
`FeatureFlags` are configured at deployment and may be toggled via `updateParams(ParamKind.Feature, ...)`.

| Flag | Description | Default |
|------|-------------|---------|
| `blendOn` | Enables the confidence blend (spread ⊕ σ ⊕ Pyth). | `true` |
| `parityCiOn` | Enables CI blocking on parity mismatches/metrics. | `true` |
| `debugEmit` | Emits `ConfidenceDebug`/telemetry events for observability. | `true` (tests only; disable in prod if noisy) |

### `tokens.hyper.json`
Holds production token metadata for HYPE and USDC. Replace placeholder addresses with HyperEVM deployments.

### `oracle.ids.json`
Tracks HyperCore asset/market IDs and Pyth price IDs.
- `hypercore.precompile` should point to `0x0000000000000000000000000000000000000807`, the published HyperCore oracle precompile.
- `pyth.*` entries map to the feed IDs for HYPE/USD and USDC/USD.

### Fee Policy Bounds (Audit ORFQ-002)
- Governance must keep `capBps < 10_000` (100%). Any higher value reverts via `FeeCapTooHigh`.
- `baseBps` must satisfy `baseBps ≤ capBps`; violations revert with `FeeBaseAboveCap`.
- When editing JSON configs, run `forge test -m CapBounds` (see `test/unit/FeePolicy_CapBounds.t.sol`) before proposing on-chain updates.

### RFQ Maker Keys & Signatures (Audit RFQ-001)
- `QuoteRFQ` now accepts either EOAs or EIP-1271 smart wallets.
- EOAs must supply 65-byte `r,s,v` signatures, failing with `QuoteSignerMismatch` on mismatch.
- Contract makers must return `0x1626ba7e` from `isValidSignature`. Reverts bubble as `MakerMustBeEOA` (no interface) or `Invalid1271MagicValue` (bad magic).
- Rotation Playbook: deploy the 1271 contract, test on staging with `forge test -m 1271`, then call `setMakerKey(newContract)` from the RFQ owner.

### QuoteFilled Telemetry (Audit RFQ-002)
- Event payload now includes actual consumed input/output amounts and any leftover returned to the taker.
- Indexers should read:
  - `requestedAmountIn` (3rd arg) – original taker intent.
  - `amountOut` (4th arg) and `actualAmountOut` (8th arg) – executed size (identical for backward compatibility).
  - `actualAmountIn` (7th arg) and `leftoverReturned` (9th arg) – to distinguish partial fills.
- Update downstream analytics and alarms to consume the new fields before upgrading prod RPC nodes.

## Management
1. Copy defaults to environment-specific variants (e.g. `parameters_staging.json`).
2. Feed values into deployment scripts via `vm.envJson` or by loading in Foundry scripts.
3. Commit updated files when governance ratifies new parameter sets; reference change in `RUNBOOK.md`.
