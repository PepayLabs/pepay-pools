---
title: "Fees and Inventory Controls"
version: "8e6f14e"
last_updated: "2025-10-03"
---

# Fees and Inventory Controls

## Table of Contents
- [Overview](#overview)
- [Fee Pipeline Components](#fee-pipeline-components)
  - [Base Fee](#base-fee)
  - [Confidence Fee](#confidence-fee)
  - [Inventory Penalty / Rebate](#inventory-penalty--rebate)
  - [Size-Aware Fee](#size-aware-fee)
  - [Caps & Floors](#caps--floors)
- [Inventory Tilt Math](#inventory-tilt-math)
- [Worked Examples](#worked-examples)
- [Code & Test References](#code--test-references)

## Overview
All swap quotes pass through `_applyFeePipeline`, composing multiple adjustments before clamping to configured caps. Feature flags default to off (`config/parameters_default.json`) to preserve zero-default semantics.

## Fee Pipeline Components
### Base Fee
- Default: `fee.baseBps = 15` bps (`config/parameters_default.json`).
- Applied to both sides when no other modifiers are active (`contracts/lib/FeePolicy.sol:45`).

### Confidence Fee
- Derived from spread, sigma, and Pyth confidence via `_computeConfidenceFeeBps` (`contracts/DnmPool.sol:1707`).
- Each component uses weights `fee.alphaConfNumerator` / `fee.betaInvDevNumerator` and caps `oracle.hypercore.confCapBpsSpot/Strict`.
- Feature flag `featureFlags.blendOn` gates the composited result; default `false` yields zero incremental fee.

### Inventory Penalty / Rebate
- `_computeInventoryTiltBps` compares current reserves with `targetBaseXstar` using `Inventory.deviationBps` (`contracts/DnmPool.sol:1483`, `contracts/lib/Inventory.sol:25`).
- Spread (`inventory.tiltSpreadWeightBps`) and confidence (`inventory.tiltConfWeightBps`) weights scale the tilt; both defaults are `0` bps.
- Clamped between `±inventory.invTiltMaxBps` (default `0`).

### Size-Aware Fee
- Enabled by `featureFlags.enableSizeFee` (default `false`).
- Normalized size `u = sizeWad / S0Wad` with `S0` from `maker.S0Notional` (`5000` quote units). Linear (`gammaSizeLinBps`) and quadratic (`gammaSizeQuadBps`) multipliers accumulate (`contracts/lib/FeePolicy.sol:117`).
- Capped at `fee.sizeFeeCapBps` (default `0`).

### Caps & Floors
- Global cap `fee.capBps` bounds the pipeline (default `150` bps).
- BBO-aware floor enforces maker minimum via `_computeBboFloor` (see [Caps & Floors](#caps--floors)).
- Aggregator rebates (`enableRebates`) subtract pre-approved discounts while ensuring `FeeCapExceeded` never triggers (`contracts/DnmPool.sol:1606`).

## Inventory Tilt Math
Given reserves `(B, Q)`, mid price `m`, and target `x*`:

```text
baseWad = B * 1e18 / baseScale
quoteWad = Q * 1e18 / quoteScale
targetWad = x* * 1e18 / baseScale
deviationBps = |baseWad - targetWad| / (quoteWad + baseWad*m) * 10_000
rawTiltBps = k * (B - x*) / x*
weightedTilt = rawTiltBps * spreadWeight * confWeight / 10_000^2
finalTilt = clamp(weightedTilt, -invTiltMaxBps, +invTiltMaxBps)
```
- `k = inventory.invTiltBpsPer1pct` (default `0`).
- `spreadWeight = inventory.tiltSpreadWeightBps` (default `0`).
- `confWeight = inventory.tiltConfWeightBps` (default `0`).
- Clamp implemented inside `_computeInventoryTiltBps` (`contracts/DnmPool.sol:1516`).

## Worked Examples
1. **Base-only configuration (defaults):** Feature flags disabled ⇒ pipeline returns 15 bps flat.
2. **Size-aware with `gammaSizeLinBps = 12`, `gammaSizeQuadBps = 6`, `sizeFeeCapBps = 30`:**
   - For `size = S0`: `u = 1`, fee = `12 + 6 = 18 bps`.
   - For `size = 3S0`: `u = 3`, fee = `12*3 + 6*9 = 90 bps`, capped at `30`.
   - Code path: `_applyFeePipeline` → `_computeSizeFeeBps` (`contracts/DnmPool.sol:1736`).
3. **Inventory tilt with spread/conf weights:** Setting `invTiltBpsPer1pct = 50`, `tiltSpreadWeightBps = 5000`, `tiltConfWeightBps = 8000`, `invTiltMaxBps = 120` yields tilt up to ±120 bps once deviation hits 1%.
4. **BBO floor:** With `maker.betaFloorBps = 20` and observed spread `40` bps, `min_floor = max(20, alpha_bbo * spread)`; if `alpha_bbo = 3000` (0.3), `min_floor = 20` unless spread widens.

## Code & Test References
- Fee pipeline: `contracts/DnmPool.sol:1368-1780`
- Inventory library: `contracts/lib/Inventory.sol:16-168`
- Feature flags: `contracts/DnmPool.sol:613-676`
- Parameter defaults: `config/parameters_default.json`
- Unit tests: `test/unit/SizeFeeCurveTest.t.sol:17`, `test/unit/InventoryTiltTest.t.sol:16`, `test/unit/BboFloorTest.t.sol:15`
- Integration: `test/integration/FeeDynamics.t.sol:18`, `test/integration/Scenario_Preview_AOMQ.t.sol:21`
