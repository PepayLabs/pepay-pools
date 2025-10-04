---
title: "Router Integration"
version: "8e6f14e"
last_updated: "2025-10-04"
---

# Router Integration

## Table of Contents
- [Overview](#overview)
- [MinOut Calculation](#minout-calculation)
- [Preview Ladder Telemetry](#preview-ladder-telemetry)
- [TTL & Slippage Recommendations](#ttl--slippage-recommendations)
- [Rebates (F09)](#rebates-f09)
- [Floor Preservation Contract](#floor-preservation-contract)
- [AOMQ & Degraded Frames](#aomq--degraded-frames)
- [Code & Test References](#code--test-references)

## Overview
This guide targets routers/aggregators integrating DNMM quotes off-chain. Use pool preview APIs to derive deterministic outputs and honour inventory floors while respecting TTL and divergence gates.

## MinOut Calculation
1. Call `previewLadder([S0, 2S0, 5S0, 10S0])` to retrieve fee bps per rung plus clamp flags (`contracts/DnmPool.sol:1103-1235`).
2. On refresh, `PreviewLadderServed` emits (when `featureFlags.debugEmit` is enabled) with zipped `[ask0, bid0, ask1, bid1...]` fees and the active `maker.ttlMs`. Use this telemetry to audit router parity.
3. Derive `amountOutPreview` using the returned fee for the requested rung.
4. Compute `minOut = amountOutPreview - slippageBuffer[rung]` (see buffers below) and embed in RFQ or direct router transaction.
5. Snapshots older than one second (`preview.maxAgeSec = 1`) revert; refresh proactively on every price poll or when `dnmm_snapshot_age_sec` > 0.8s to avoid last-second failures.

## Preview Ladder Telemetry
- **Event:** `PreviewLadderServed(bytes32 snapId, uint8[] rungs, uint16[] feeBps, uint32 tifMs)` (debug mode only).
- **Rungs:** Always `[1, 2, 5, 10]` representing `{S0, 2S0, 5S0, 10S0}` multiples.
- **Fees:** Zipped array `[ask0, bid0, ask1, bid1, ...]` in bps; align with `previewLadder` output.
- **TTL:** `tifMs` mirrors `maker.ttlMs`; routers should cap on-chain TTL ≤ this value.
- **Correlate:** Use `snapId` (`keccak` of snapshot metadata) to tie preview telemetries to downstream swaps or RFQs.

## TTL & Slippage Recommendations
Rung | Size Multiple | TTL Guidance | Slippage Buffer | Notes
--- | --- | --- | --- | ---
`S0` | `1 × maker.S0Notional` | 300 ms | 5 bps | Baseline; use as health probe.
`2S0` | `≈ 2 × S0` | 300 ms | 15 bps | Allows for transient spread moves.
`5S0` | `≈ 5 × S0` | 300 ms | 15 bps | Stays within standard maker risk appetite.
`10S0` | `≈ 10 × S0` | 300 ms (hard max) | 30 bps | Coordinate with desk; expect clamps under AOMQ.
- Always propagate TTL from `QuoteRFQ` signatures; expire quotes client-side 50 ms before on-chain deadline.

## Rebates (F09)
- When `featureFlags.enableRebates` is `true` and the executor is allow-listed, the pool subtracts a fixed 3 bps rebate (`contracts/DnmPool.sol:1753-1766`).
- Governance manages the allowlist with `setAggregatorRouter(executor, allowed)`; updates emit `AggregatorDiscountUpdated` with either `3` or `0` bps.
- Routers must submit transactions from the allow-listed executor to receive the rebate.
- Discounts never bypass floors; final fee is `max(feePipeline - rebate, minFloor)`.
- Treasury should audit allow-listed executors weekly; stale entries should be removed via `setAggregatorRouter(executor,false)` to avoid leakage.

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
- Preview ladder event: `contracts/DnmPool.sol:1903-1954`, `test/integration/FirmLadder_TIFHonored.t.sol`
- RFQ settlement: `contracts/quotes/QuoteRFQ.sol:88-145`
- Rebates: `contracts/DnmPool.sol:1753-1766`, `test/unit/Rebates_FloorPreserve.t.sol`
- AOMQ scenarios: `test/integration/Scenario_AOMQ.t.sol:21`, `test/integration/Scenario_Preview_AOMQ.t.sol:21`
