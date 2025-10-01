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
| `oracle.hypercore.divergenceAcceptBps` | Divergence level where soft haircut begins. | `30` bps |
| `oracle.hypercore.divergenceSoftBps` | Divergence level where haircut saturates before hard reject. | `50` bps |
| `oracle.hypercore.divergenceHardBps` | Divergence level triggering hard reject / AOMQ. | `75` bps |
| `oracle.hypercore.haircutMinBps` | Base fee add-on when soft divergence triggers. | `3` bps |
| `oracle.hypercore.haircutSlopeBps` | Additional bps added per 1 bps above accept band. | `1` |
| `oracle.hypercore.confWeightSpreadBps` | Weight applied to HyperCore spread when blending confidence (1.0 = 10000). | `10000` |
| `oracle.hypercore.confWeightSigmaBps` | Weight applied to EWMA sigma when blending confidence. | `10000` |
| `oracle.hypercore.confWeightPythBps` | Weight applied to Pyth confidence when blending confidence. | `10000` |
| `oracle.hypercore.sigmaEwmaLambdaBps` | EWMA smoothing factor λ (1.0 = 10000) for sigma updates. | `9000` |
| `fee.*` | Lifinity α/β/cap/decay coefficients. | See file |
| `fee.gammaSizeLinBps` | Linear size-fee coefficient applied per S0 multiple. | `0` |
| `fee.gammaSizeQuadBps` | Quadratic size-fee coefficient applied per S0 multiple. | `0` |
| `fee.sizeFeeCapBps` | Maximum BPS contributed by the size surcharge. | `0` |
| `inventory.floorBps` | Minimum side inventory retained. | `300` bps |
| `inventory.recenterThresholdPct` | Price move threshold for `x*` updates. | `750` (7.5%) |
| `inventory.invTiltBpsPer1pct` | Tilt slope applied per 1% inventory deviation (bps). | `0` |
| `inventory.invTiltMaxBps` | Max tilt adjustment applied to spreads (bps). | `0` |
| `inventory.tiltConfWeightBps` | Weight applied to oracle confidence when scaling tilt (1.0 = 10000). | `0` |
| `inventory.tiltSpreadWeightBps` | Weight applied to HyperCore spread when scaling tilt (1.0 = 10000). | `0` |
| `maker.S0Notional` | On-chain S0 anchor (expressed in quote units) used for sizing ladders. | `5000` |
| `maker.ttlMs` | RFQ TTL in milliseconds. | `200` |
| `maker.alphaBboBps` | Multiplier (bps) applied to HC spread when computing the BBO-aware floor. | `0` |
| `maker.betaFloorBps` | Absolute floor fallback (bps) enforced when book spread is narrow. | `0` |
| `aomq.minQuoteNotional` | Minimum emergency quote notional emitted under AOMQ. | `0` |
| `aomq.emergencySpreadBps` | Spread (bps) applied to AOMQ micro quotes. | `0` |
| `aomq.floorEpsilonBps` | Additional epsilon above the configured floor when AOMQ is active. | `0` |
| `rebates.allowlist` | List of `{executor, discountBps}` entries granted maker rebates. The contract enforces `discountBps ≤ 3` and clamps at the fee cap/floor. | `[]` |
| `governance.timelockDelaySec` | Global timelock (seconds) for sensitive param commits. Must be `0` (disabled) or ≥ 3600 and ≤ 7 days when enabled. | `0` |
| `.preview.enablePreviewFresh` | Enables live oracle reads in `previewFeesFresh`. Must coincide with `maxAgeSec > 0`. | `false` |
| `featureFlags.*` | Deployment-time feature toggles (zero-default). | All `false` |

### Feature Flags
`FeatureFlags` are configured at deployment (see the `featureFlags` block in `parameters_default.json`) and may be toggled via `updateParams(ParamKind.Feature, ...)`. All flags default to `false`; governance enables them once safeguards and playbooks are in place.

| Flag | Description | Default |
|------|-------------|---------|
| `blendOn` | Enables the confidence blend (spread ⊕ σ ⊕ Pyth); falls back to pure spread when `false`. | `false` |
| `parityCiOn` | Enables CI checks that fail tests when parity metrics drift. | `false` |
| `debugEmit` | Emits `ConfidenceDebug` telemetry events for observability. | `false` |
| `enableSoftDivergence` | Activates the soft divergence haircut band (F03). | `false` |
| `enableSizeFee` | Activates size-aware fee curve (F04). | `false` |
| `enableBboFloor` | Enables BBO-aware floor uplift (F05). | `false` |
| `enableInvTilt` | Turns on instantaneous inventory tilt adjustments (F06). | `false` |
| `enableAOMQ` | Enables adaptive micro quotes in degraded states (F07). | `false` |
| `enableRebates` | Allows maker rebates / RFQ discounts (F09). | `false` |
| `enableAutoRecenter` | Allows autonomous recenter commits under governance-approved policy. | `false` |

### Governance Timelock & Param Lifecycle
- **Queue** sensitive updates via `queueParams(kind, data)` once `governance.timelockDelaySec > 0`. Immediate application still works for non-sensitive kinds (`Preview`, `Governance`) or when the delay is `0`.
- **Execute** after `block.timestamp ≥ eta`; the contract revalidates bounds inside `_applyParamUpdate` before writing and emits both `ParamsExecuted` and `ParamsUpdated`.
- **Cancel** via `cancelParams(kind)` if the change needs to be abandoned (clears the payload + ETA).
- **Sensitive kinds** requiring timelock: `Oracle`, `Fee`, `Inventory`, `Maker`, `Feature`, `Aomq`.
- **Gating helpers**: `TimelockDelayUpdated` fires when governance changes the delay; `ParamsQueued(kind, eta, proposer, keccak256(data))` allows off-chain monitors to reconcile queue/execution.
- **Pauser rotation**: use `setPauser(newPauser)` to point `guardians.pauser` at the autopause handler once deployed. Governance retains override via `pause/unpause`.
- **Rebates**: stage allowlist changes with `queueParams(Feature)` (if enabling flag) and `setAggregatorDiscount(executor, bps)`; every update emits `AggregatorDiscountUpdated` for audit.

### `tokens.hyper.json`
Holds production token metadata for HYPE and USDC. Replace placeholder addresses with HyperEVM deployments.

### `oracle.ids.json`
Tracks HyperCore asset/market IDs and Pyth price IDs.
- `hypercore.precompile` should point to `0x0000000000000000000000000000000000000807`, the published HyperCore oracle precompile.
- `pyth.*` entries map to the feed IDs for HYPE/USD and USDC/USD.
- Asset / market identifiers are ABI-encoded as 32-byte words. The adapter slices the first four bytes (big-endian) to obtain the `uint32` index required by the HyperCore precompiles—keep those prefixes in sync with HyperCore's `L1Read.sol` constants.
- HyperCore price endpoints do **not** provide timestamps; the adapter marks their age as `uint256.max` and relies on EMA/Pyth to satisfy freshness checks. Ensure Pyth feeds remain configured and healthy before promoting new configs.

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
