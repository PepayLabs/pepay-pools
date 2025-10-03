---
title: "Router Integration"
version: "8e6f14e"
last_updated: "2025-10-03"
---

# Router Integration

## Table of Contents
- [Overview](#overview)
- [MinOut Calculation](#minout-calculation)
- [TTL & Slippage Recommendations](#ttl--slippage-recommendations)
- [Rebates (F09)](#rebates-f09)
- [Floor Preservation Contract](#floor-preservation-contract)
- [AOMQ & Degraded Frames](#aomq--degraded-frames)
- [Code & Test References](#code--test-references)

## Overview
This guide targets routers/aggregators integrating DNMM quotes off-chain. Use pool preview APIs to derive deterministic outputs and honour inventory floors while respecting TTL and divergence gates.

## MinOut Calculation
1. Call `previewLadder([S0, 2S0, 5S0, 10S0])` to retrieve fees per rung (`contracts/DnmPool.sol:1071-1288`).
2. Derive `amountOutPreview` for the target size.
3. Compute `minOut = amountOutPreview - slippageBuffer` where `slippageBuffer` maps to size bucket (see below).
4. Include `minOut` in signed quote payload (`QuoteRFQ` or router transaction) and surface to downstream takers.
5. Rebuild previews after any snapshot refresh or when `dnmm_snapshot_age_sec` exceeds configured threshold.

## TTL & Slippage Recommendations
Bucket | Size Range | TTL Guidance | Slippage Buffer | Notes
--- | --- | --- | --- | ---
Tier 0 | `≤ S0` (5k quote) | 300 ms max | ≥5 bps | Expect minimal clamps; default TTL matches `maker.ttlMs`.
Tier 1 | `S0 .. 5S0` | 300 ms | ≥15 bps | Wider buffer to absorb potential AOMQ spread floors.
Tier 2 | `> 5S0` | 150 ms | ≥30 bps | Coordinate with maker desk; consider splitting orders.
- Always propagate TTL from `QuoteRFQ` signatures; expire quotes client-side 50 ms before on-chain deadline.

## Rebates (F09)
- When `featureFlags.enableRebates` and `enableRebates` allowlist active, pool applies per-executor discounts via `aggregatorDiscount` (`contracts/DnmPool.sol:617`).
- Router must set `executor` address to receive discount; monitor `AggregatorDiscountUpdated` event.
- Discounts never bypass floors; final fee is `max(feePipeline - rebate, minFloor)`.

## Floor Preservation Contract
- Flooring logic returns leftover input on partial fills (`contracts/lib/Inventory.sol:42-105`).
- Routers should propagate `leftoverReturned` emitted in `QuoteFilled` to analytics.
- For split fills, recompute preview on residual size to avoid breaching floors.

## AOMQ & Degraded Frames
- AOMQ activates when divergence soft state, fallback usage, or floor proximity detected (`contracts/DnmPool.sol:1280-1345`).
- Indicators:
  - Preview ladder flags `askClamped` / `bidClamped` for affected rungs.
  - Shadow metrics `dnmm_aomq_clamps_total` spikes.
- Routing strategy:
  - Respect reduced size/ widened spread; do not retry original size until clamps clear.
  - If `enableAOMQ` disabled, degrade gracefully by switching to backup liquidity.
- Degraded frames still honor floors; routers must not attempt to bypass by force-splitting micron sizes.

## Code & Test References
- Pool preview APIs: `contracts/DnmPool.sol:1071-1288`
- RFQ settlement: `contracts/quotes/QuoteRFQ.sol:88-145`
- Rebates: `contracts/DnmPool.sol:1606`, `test/unit/Rebates_FloorPreserve.t.sol:19`
- AOMQ scenarios: `test/integration/Scenario_AOMQ.t.sol:21`, `test/integration/Scenario_Preview_AOMQ.t.sol:21`
