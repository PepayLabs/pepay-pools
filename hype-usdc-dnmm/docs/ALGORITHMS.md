---
title: "Algorithm Reference"
version: "8e6f14e"
last_updated: "2025-10-04"
---

# Algorithm Reference

## Table of Contents

- [Size-Aware Fee](#size-aware-fee)
- [LVR Fee Surcharge](#lvr-fee-surcharge)
- [Inventory Tilt](#inventory-tilt)
- [BBO-Aware Fee Floor](#bbo-aware-fee-floor)
- [Always-On Micro Quotes (AOMQ)](#always-on-micro-quotes-aomq)
- [Preview Snapshot](#preview-snapshot)

## Size-Aware Fee

Pseudocode:

```text
u = sizeWad / S0Wad
fee_size_bps = gamma_lin_bps * u + gamma_quad_bps * u^2
fee_size_bps = min(fee_size_bps, size_fee_cap_bps)
```
- Inputs: `gammaSizeLinBps`, `gammaSizeQuadBps`, `sizeFeeCapBps`, `maker.S0Notional`.
- Complexity: O(1).
- Gas: < 3k gas inside `_applyFeePipeline` when enabled (no storage reads beyond config pack).
- Implementation: `contracts/lib/FeePolicy.sol:120-170`, `contracts/DnmPool.sol:1721-1783`.
- Tests: `test/unit/SizeFeeCurveTest.t.sol`.

## LVR Fee Surcharge

Pseudocode:

```text
sigma_wad = sigma_bps * 1e14
dt_wad = maker.ttlMs * 1e18 / 1000
sqrt_dt_wad = sqrt(dt_wad) * 1e9     # convert back to WAD scale
term_wad = mulDivUp(sigma_wad, sqrt_dt_wad, 1e18) + toxicity_bias_wad
fee_lvr_bps = mulDivUp(kappa_lvr_bps, term_wad, 1e18)
fee_lvr_bps = min(fee_lvr_bps, cap_bps)
```
- Inputs: `fee.kappaLvrBps`, maker TTL, blended sigma, AOMQ emergency spread (`toxicity_bias_wad`).
- Final rounding occurs only in the last `mulDivUp` so σ√Δt remains monotonic when TTL or volatility increase.
- Complexity: O(1) per quote.
- Gas: ≈2.3k gas incremental when enabled (math-only, no storage IO).
- Implementation: `contracts/DnmPool.sol:1903-1957`, `contracts/lib/FeePolicy.sol:120-170`, `contracts/lib/FixedPointMath.sol:73-86`.
- Tests: `test/unit/LvrFee_Monotonic.t.sol`, `test/unit/LvrFee_RespectsCaps.t.sol`, `test/integration/LvrFee_FloorInvariant.t.sol`.

## Inventory Tilt

Pseudocode:

```text
x_star = f(current reserves, mid)
tilt_raw_bps = k * (B - x_star) / x_star
tilt_weighted_bps = tilt_raw_bps * w_spread * w_conf
tilt_bps = clamp(tilt_weighted_bps, -tiltMaxBps, +tiltMaxBps)
```
- Inputs: `inventory.invTiltBpsPer1pct`, weights, `invTiltMaxBps`.
- Complexity: O(1) per quote.
- Gas: ≈5k gas w/ all flags on (mainly math operations).
- Implementation: `contracts/DnmPool.sol:1488-1564`, `contracts/lib/Inventory.sol:25-40`.
- Tests: `test/unit/InventoryTiltTest.t.sol`.

## BBO-Aware Fee Floor

Pseudocode:

```text
bbo_spread_bps = 10_000 * (ask - bid) / mid
min_floor_bps = max(beta_floor_bps, alpha_bbo_bps * bbo_spread_bps / 10_000)
final_fee_bps = max(final_fee_bps, min_floor_bps)
```
- Inputs: `maker.alphaBboBps`, `maker.betaFloorBps`, live spread from HyperCore.
- Complexity: O(1).
- Gas: Negligible; executed only when `enableBboFloor` true.
- Implementation: `contracts/DnmPool.sol:1476-1498`.
- Tests: `test/unit/BboFloorTest.t.sol`.

## Always-On Micro Quotes (AOMQ)

Pseudocode:

```text
if degraded_state and enableAOMQ:
  clamp size to minQuoteNotional and/or widen spread to emergencySpreadBps
  ensure floor-preserving partial fills
else:
  normal size/fees
```
- Degraded triggers: soft divergence, fallback usage, floor proximity (`contracts/DnmPool.sol:1288-1372`).
- Complexity: O(1) conditional per swap.
- Gas: Adds ~7k gas when triggered due to extra Inventory lookups.
- Implementation: `_evaluateAomq` and `_applyFeePipeline` (`contracts/DnmPool.sol:1269-1814`).
- Tests: `test/integration/Scenario_AOMQ.t.sol`, `test/integration/Scenario_Preview_AOMQ.t.sol`.

## Preview Snapshot

Pseudocode:

```text
On quote/swap: persist snapshot { mid, conf_bps, spread_bps, mode, ts, flags }
previewFees(sizes[]) reads snapshot and recomputes fees (view-only)
previewFresh optionally re-reads adapters without mutating state
```
- Snapshot fields: `midWad`, `divergenceBps`, `flags`, `blockNumber`, `timestamp` (`contracts/DnmPool.sol:1960-1991`).
- Staleness guards: `PreviewSnapshotStale`, `PreviewSnapshotCooldown` errors when conditions violated (`contracts/DnmPool.sol:1045-1159`).
- Complexity: Snapshot persistence O(1); preview ladder O(n) over size array length.
- Gas: Snapshot persist ≈15k gas (event + struct write). `previewFees` read-only.
- Telemetry: When `featureFlags.debugEmit` true, `_emitPreviewLadderDebug` emits `PreviewLadderServed` with rung/TTL payload for router parity checks (`contracts/DnmPool.sol:1997-2050`).
- Tests: `test/unit/PreviewFees_Parity.t.sol`, `test/integration/Scenario_Preview_AOMQ.t.sol`, `test/integration/FirmLadder_TIFHonored.t.sol`.
