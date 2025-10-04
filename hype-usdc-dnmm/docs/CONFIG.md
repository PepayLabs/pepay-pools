---
title: "Configuration Reference"
version: "8e6f14e"
last_updated: "2025-10-04"
---

# Configuration Reference

## Table of Contents
- [Overview](#overview)
- [Schema](#schema)
- [Zero-Default Posture](#zero-default-posture)
- [Field Reference](#field-reference)
- [Upgrade Safety](#upgrade-safety)
- [Validation Steps](#validation-steps)

## Overview
Runtime parameters live in `config/parameters_default.json`. Defaults bias towards conservative behavior: optional feature flags remain off, AOMQ thresholds start at zero, and preview snapshots now expire after **1 second** to guarantee router parity.

## Schema
```json
{
  "oracle": {
    "hypercore": {
      "confCapBpsSpot": "uint16",
      "confCapBpsStrict": "uint16",
      "maxAgeSec": "uint32",
      "stallWindowSec": "uint32",
      "allowEmaFallback": "bool",
      "divergenceBps": "uint16",
      "divergenceAcceptBps": "uint16",
      "divergenceSoftBps": "uint16",
      "divergenceHardBps": "uint16",
      "haircutMinBps": "uint16",
      "haircutSlopeBps": "uint16",
      "confWeightSpreadBps": "uint32",
      "confWeightSigmaBps": "uint32",
      "confWeightPythBps": "uint32",
      "sigmaEwmaLambdaBps": "uint16"
    },
    "pyth": {
      "maxAgeSec": "uint32",
      "confCapBps": "uint16"
    }
  },
  "fee": {
    "baseBps": "uint16",
    "alphaConfNumerator": "uint16",
    "alphaConfDenominator": "uint16",
    "betaInvDevNumerator": "uint16",
    "betaInvDevDenominator": "uint16",
    "capBps": "uint16",
    "decayPctPerBlock": "uint16",
    "gammaSizeLinBps": "uint16",
    "gammaSizeQuadBps": "uint16",
    "sizeFeeCapBps": "uint16",
    "kappaLvrBps": "uint16"
  },
  "inventory": {
    "floorBps": "uint16",
    "recenterThresholdPct": "uint16",
    "initialTargetBaseXstar": "uint128|\"auto\"",
    "invTiltBpsPer1pct": "uint16",
    "invTiltMaxBps": "uint16",
    "tiltConfWeightBps": "uint16",
    "tiltSpreadWeightBps": "uint16"
  },
  "maker": {
    "S0Notional": "uint64",
    "ttlMs": "uint32",
    "alphaBboBps": "uint16",
    "betaFloorBps": "uint16"
  },
  "preview": {
    "maxAgeSec": "uint32",
    "snapshotCooldownSec": "uint32",
    "revertOnStalePreview": "bool",
    "enablePreviewFresh": "bool"
  },
  "featureFlags": {
    "blendOn": "bool",
    "parityCiOn": "bool",
    "debugEmit": "bool",
    "enableSoftDivergence": "bool",
    "enableSizeFee": "bool",
    "enableBboFloor": "bool",
    "enableInvTilt": "bool",
    "enableAOMQ": "bool",
    "enableRebates": "bool",
    "enableAutoRecenter": "bool",
    "enableLvrFee": "bool"
  },
  "aomq": {
    "minQuoteNotional": "uint128",
    "emergencySpreadBps": "uint16",
    "floorEpsilonBps": "uint16"
  },
  "rebates": {
    "allowlist": "address[]"
  },
  "governance": {
    "timelockDelaySec": "uint32"
  }
}
```

## Zero-Default Posture
Flag | Default | Result
--- | --- | ---
`featureFlags.enableAutoRecenter` | `false` | Auto recenter suppressed; manual-only recentering.
`featureFlags.enableAOMQ` | `false` | AOMQ spread/size clamps inactive.
`featureFlags.enableSizeFee` | `false` | Fees remain flat at `baseBps`.
`featureFlags.enableBboFloor` | `false` | Maker floor disabled until explicitly enabled.
`featureFlags.enableInvTilt` | `false` | Inventory tilt inactive.
`featureFlags.enableRebates` | `false` | Aggregator discounts ignored.
`featureFlags.enableSoftDivergence` | `false` | Soft haircuts disabled; divergence beyond accept reverts.
`featureFlags.blendOn` | `false` | Confidence term not blended.
`featureFlags.parityCiOn` | `false` | Preview parity CI checks inactive offchain.
`featureFlags.debugEmit` | `false` | Debug events withheld in production.
`featureFlags.enableLvrFee` | `false` | LVR fee component inactive.
`preview.enablePreviewFresh` | `false` | Preview `fresh` endpoint disabled.
`preview.revertOnStalePreview` | `true` | Snapshots older than `preview.maxAgeSec` revert.
`aomq.minQuoteNotional` | `0` | No enforced micro-quote minimum until configured.
`aomq.emergencySpreadBps` | `0` | No emergency spread widening applied by default.
`governance.timelockDelaySec` | `0` | No timelock; set before mainnet launch.

## Field Reference
Category | Field | Default | Unit | Notes
--- | --- | --- | --- | ---
Oracle | `oracle.hypercore.maxAgeSec` | `48` | seconds | Maximum age of HyperCore spot sample.
Oracle | `oracle.hypercore.divergenceAcceptBps` | `30` | bps | Accept threshold before soft state.
Oracle | `oracle.hypercore.divergenceSoftBps` | `50` | bps | Soft haircut trigger.
Oracle | `oracle.hypercore.divergenceHardBps` | `75` | bps | Hard reject threshold.
Oracle | `oracle.hypercore.haircutMinBps` | `3` | bps | Base haircut applied once soft active.
Oracle | `oracle.hypercore.haircutSlopeBps` | `1` | bps | Additional haircut per bps beyond accept.
Oracle | `oracle.pyth.maxAgeSec` | `10` | seconds | Strict bound for RFQ verification and preview freshness.
Fee | `fee.baseBps` | `15` | bps | Applied when no modifiers active.
Fee | `fee.capBps` | `150` | bps | Global fee ceiling.
Fee | `fee.gammaSizeLinBps` | `0` | bps | Linear size coefficient.
Fee | `fee.kappaLvrBps` | `0` | bps | Multiplier for LVR fee term (`σ√Δt`).
Inventory | `inventory.floorBps` | `300` | bps | 3% floor on both reserves.
Inventory | `inventory.recenterThresholdPct` | `750` | percent (1/100 bps) | 7.5% deviation required to auto recenter.
Inventory | `inventory.initialTargetBaseXstar` | `"auto"` | - | Pool infers target from reserves on deploy.
Maker | `maker.S0Notional` | `5000` | quote units | Baseline size bucket.
Maker | `maker.ttlMs` | `300` | milliseconds | Default TTL for RFQ quotes.
Maker | `maker.alphaBboBps` | `0` | bps | BBO-linked floor multiplier.
Preview | `preview.maxAgeSec` | `1` | seconds | Snapshots older than this revert in `preview*` calls.
Preview | `preview.snapshotCooldownSec` | `0` | seconds | Zero allows immediate refresh loop.
AOMQ | `aomq.minQuoteNotional` | `0` | quote units | Set >0 to clamp micro quotes.
Governance | `governance.timelockDelaySec` | `0` | seconds | Configure >0 for mainnet safety.
Rebates | `rebates.allowlist` | `[]` | addresses | Populate before enabling rebates; governance applies updates via `setAggregatorRouter`.

## Upgrade Safety
- **Bounds enforcement:** `_validateConfigUpdate` reverts if divergence soft < accept or timelock missing when required (`contracts/DnmPool.sol:669`).
- **Timelock:** `Errors.TimelockRequired()` protects parameter updates when `governance.timelockDelaySec > 0` (`contracts/lib/Errors.sol:24`).
- **Queueing:** Governance uses `queueParamUpdate` with `ParamKind` enumerations; preview/governance updates share ID guard rails (`contracts/DnmPool.sol:725-761`).
- **Schema drift:** Re-run `jq -S` diff against deployed configuration before execution.

## Validation Steps
1. `jq -S . config/parameters_default.json` to normalize JSON before review.
2. Run `yarn shadow-bot lint` ensure configuration exports align with bot expectations (`shadow-bot/config.ts`).
3. Execute `forge test --match-contract Scenario_CalmFlow` after parameter changes to confirm behavior.
4. Update this document and `RUNBOOK.md` whenever defaults change; note diff in `CHANGELOG.md` under “Docs”.
5. When enabling rebates, diff `rebates.allowlist` against treasury records and emit a dry-run `setAggregatorRouter` on staging before production.
