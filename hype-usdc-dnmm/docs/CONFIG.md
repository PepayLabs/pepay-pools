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

### `tokens.hyper.json`
Holds production token metadata for HYPE and USDC. Replace placeholder addresses with HyperEVM deployments.

### `oracle.ids.json`
Tracks HyperCore asset/market IDs and Pyth price IDs.
- `hypercore.precompile` must be filled once the official read precompile is published.
- `pyth.*` entries map to the feed IDs for HYPE/USD and USDC/USD.

## Management
1. Copy defaults to environment-specific variants (e.g. `parameters_staging.json`).
2. Feed values into deployment scripts via `vm.envJson` or by loading in Foundry scripts.
3. Commit updated files when governance ratifies new parameter sets; reference change in `RUNBOOK.md`.
