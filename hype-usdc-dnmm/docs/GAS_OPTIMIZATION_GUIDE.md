---
title: "Gas Optimization Guide"
version: "8e6f14e"
last_updated: "2025-10-04"
---

# Gas Optimization Guide

## Table of Contents
- [Current Baselines](#current-baselines)
- [Storage & Bitmasking](#storage--bitmasking)
- [SLOAD/SSTORE Coalescing](#sloadsstore-coalescing)
- [Early-Out Patterns](#early-out-patterns)
- [Oracle Mode Gating](#oracle-mode-gating)
- [Debug Event Controls](#debug-event-controls)
- [Future Work](#future-work)

## Current Baselines
Operation | Gas (2025-10-03) | Target | Notes
--- | --- | --- | ---
`quote_hc` | 129,300† | ≤130,000 | Includes aggregator allowlist SLOAD (+~2k) and LVR math (pure ops).
`swap_base_hc` | 303,400† | ≤305,000 | Pipeline adds LVR surcharge + rebate clamp before floors.
`rfq_verify_swap` | 462,100† | ≤470,000 | Covers allowlist lookup, signature verify, swap execution.
Historical baseline (2025-09-23): `quote_hc` 115,248, `swap_base_hc` 210,893 (pre AOMQ enablement). Track regressions in `reports/gas/gas_report.json`.

† Pending recompute in `gas-snapshots.txt` after Core-4 rollout. Expect variability ±0.5% depending on ladder rung.

## Storage & Bitmasking
- `FeeConfig`, `FeatureFlags`, and preview config packed into single storage words to reduce repeated SLOADs (`contracts/DnmPool.sol:333-388`).
- Soft divergence flags stored in `PreviewSnapshot.flags` bitmask (SOFT/AOMQ_ASK/AOMQ_BID) to allow cheap reads and feed LVR bias (`contracts/DnmPool.sol:1877-1916`).
- Aggregator allowlist stored as `mapping(address => bool)`; lookups are single SLOAD (≈2k gas) and only triggered when rebates enabled (`contracts/DnmPool.sol:640-672`).

## SLOAD/SSTORE Coalescing
- `_loadFeeState` caches fee state into memory struct; reused in `_refreshPreviewSnapshot` and swap paths (`contracts/DnmPool.sol:898-906`).
- Inventory config passed by memory reference to avoid double loads inside `_applyFeePipeline` and `_evaluateAomq`.
- Completed optimization: Fee config pack described in `reports/gas/microopt_suggestions.md` first bullet.

## Early-Out Patterns
- `_evaluateAomq` returns early when flags disabled or quoted size zero, saving ~2.3k gas per quote (`contracts/DnmPool.sol:1276-1416`).
- `_computeLvrFeeBps` exits when `kappaLvrBps` or sigma zero; compute-only math keeps surcharge overhead under 2.3k gas (`contracts/DnmPool.sol:1799-1836`).
- Inventory partial fill solver exits when full amount fits floor slack, avoiding polynomial solve (`contracts/lib/Inventory.sol:49-73`).

## Oracle Mode Gating
- `OracleMode.Strict` toggles Pyth reads only when required, avoiding extra calldata and ~15k gas per strict quote (`contracts/DnmPool.sol:1983-2146`).
- `needsPythConfidence`/`needsPythDivergence` flags skip Pyth fetch unless thresholds require data (`contracts/DnmPool.sol:1983-2068`).

## Debug Event Controls
- `featureFlags.debugEmit` disables verbose events by default; enable only during incident response to prevent gas increase on swaps (`contracts/DnmPool.sol:617`).
- Preview ladder telemetry (`PreviewLadderServed`) remains opt-in; emits only in debug mode to avoid event gas on production swaps (`contracts/DnmPool.sol:300-313`, `contracts/DnmPool.sol:2037-2051`).

## Future Work
- Investigate caching floor reserves for quote+swap in same block (open item in `reports/gas/microopt_suggestions.md`).
- Explore precomputing size ladders for commonly routed buckets to reuse across preview calls.
- Consider migrating RFQ signature recovery to assembly-only path to shave ~8k gas (needs audit review).
