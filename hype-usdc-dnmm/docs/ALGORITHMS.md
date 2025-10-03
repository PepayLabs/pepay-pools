---
title: "Algorithm Reference"
version: "8e6f14e"
last_updated: "2025-10-03"
---

# Algorithm Reference

## Table of Contents
- [Size-Aware Fee](#size-aware-fee)
- [Inventory Tilt](#inventory-tilt)
- [BBO-Aware Fee Floor](#bbo-aware-fee-floor)
- [Always-On Micro Quotes (AOMQ)](#always-on-micro-quotes-aomq)
- [Preview Snapshot](#preview-snapshot)

## Size-Aware Fee
Pseudocode:
```
u = sizeWad / S0Wad
fee_size_bps = gamma_lin_bps * u + gamma_quad_bps * u^2
fee_size_bps = min(fee_size_bps, size_fee_cap_bps)
```
- Inputs: `gammaSizeLinBps`, `gammaSizeQuadBps`, `sizeFeeCapBps`, `maker.S0Notional`.
- Complexity: O(1).
- Gas: < 3k gas inside `_applyFeePipeline` when enabled (no storage reads beyond config pack).
- Implementation: `contracts/lib/FeePolicy.sol:117-156`, `contracts/DnmPool.sol:1736`.
- Tests: `test/unit/SizeFeeCurveTest.t.sol`.

## Inventory Tilt
Pseudocode:
```
x_star = f(current reserves, mid)
tilt_raw_bps = k * (B - x_star) / x_star
tilt_weighted_bps = tilt_raw_bps * w_spread * w_conf
tilt_bps = clamp(tilt_weighted_bps, -tiltMaxBps, +tiltMaxBps)
```
- Inputs: `inventory.invTiltBpsPer1pct`, weights, `invTiltMaxBps`.
- Complexity: O(1) per quote.
- Gas: ≈5k gas w/ all flags on (mainly math operations).
- Implementation: `contracts/DnmPool.sol:1483-1524`, `contracts/lib/Inventory.sol:25-40`.
- Tests: `test/unit/InventoryTiltTest.t.sol`.

## BBO-Aware Fee Floor
Pseudocode:
```
bbo_spread_bps = 10_000 * (ask - bid) / mid
min_floor_bps = max(beta_floor_bps, alpha_bbo_bps * bbo_spread_bps / 10_000)
final_fee_bps = max(final_fee_bps, min_floor_bps)
```
- Inputs: `maker.alphaBboBps`, `maker.betaFloorBps`, live spread from HyperCore.
- Complexity: O(1).
- Gas: Negligible; executed only when `enableBboFloor` true.
- Implementation: `contracts/DnmPool.sol:1467-1479`.
- Tests: `test/unit/BboFloorTest.t.sol`.

## Always-On Micro Quotes (AOMQ)
Pseudocode:
```
if degraded_state and enableAOMQ:
  clamp size to minQuoteNotional and/or widen spread to emergencySpreadBps
  ensure floor-preserving partial fills
else:
  normal size/fees
```
- Degraded triggers: soft divergence, fallback usage, floor proximity (`contracts/DnmPool.sol:1280-1338`).
- Complexity: O(1) conditional per swap.
- Gas: Adds ~7k gas when triggered due to extra Inventory lookups.
- Implementation: `_evaluateAomq` and `_applyFeePipeline` (`contracts/DnmPool.sol:1261-1370`).
- Tests: `test/integration/Scenario_AOMQ.t.sol`, `test/integration/Scenario_Preview_AOMQ.t.sol`.

## Preview Snapshot
Pseudocode:
```
On quote/swap: persist snapshot { mid, conf_bps, spread_bps, mode, ts, flags }
previewFees(sizes[]) reads snapshot and recomputes fees (view-only)
previewFresh optionally re-reads adapters without mutating state
```
- Snapshot fields: `midWad`, `divergenceBps`, `flags`, `blockNumber`, `timestamp` (`contracts/DnmPool.sol:1864-1896`).
- Staleness guards: `PreviewSnapshotStale`, `PreviewSnapshotCooldown` errors when conditions violated (`contracts/DnmPool.sol:1045-1140`).
- Complexity: Snapshot persistence O(1); preview ladder O(n) over size array length.
- Gas: Snapshot persist ≈15k gas (event + struct write). `previewFees` read-only.
- Tests: `test/unit/PreviewFees_Parity.t.sol`, `test/integration/Scenario_Preview_AOMQ.t.sol`.
