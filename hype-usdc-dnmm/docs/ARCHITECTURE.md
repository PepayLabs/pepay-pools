---
title: "DNMM System Architecture"
version: "8e6f14e"
last_updated: "2025-10-04"
---

# DNMM System Architecture

## Table of Contents
- [Overview](#overview)
- [Oracle-Anchored Pricing](#oracle-anchored-pricing)
- [Fee & Inventory Pipeline](#fee--inventory-pipeline)
- [Swap Execution Workflow](#swap-execution-workflow)
- [Preview Snapshot & Determinism](#preview-snapshot--determinism)
- [Recenter & Inventory Governance](#recenter--inventory-governance)
- [Observer & Autopause Layer](#observer--autopause-layer)
- [Data Flow Diagram](#data-flow-diagram)
- [Code & Test Index](#code--test-index)

## Overview
The HYPE/USDC DNMM stack combines HyperCore order-book data with fallback oracles and governance-managed fee policies to deliver deterministic quotes and swaps. `DnmPool` owns token reserves, price gating, fee logic, preview snapshots, and inventory recentering, while surrounding adapters feed normalized oracle data and RFQ flows.

## Oracle-Anchored Pricing
- **Primary source:** HyperCore precompile via `OracleAdapterHC` (`contracts/oracle/OracleAdapterHC.sol:1`). Freshness and divergence guards originate from `oracle.hypercore.*` defaults in `config/parameters_default.json`.
- **Fallback chain:** `_getFreshSpotPrice` walks spot → EMA → Pyth (`contracts/DnmPool.sol:2097`). Divergence soft/hard thresholds enforce haircut/reject behavior (`contracts/DnmPool.sol:2146`, `contracts/lib/Errors.sol:5`).
- **Strict vs relaxed:** RFQ and swap paths toggle `OracleMode` (`contracts/interfaces/IDnmPool.sol:94`) to demand stricter `maxAgeSec` and confidence caps; unset mids revert with `Errors.MidUnset()`.

## Fee & Inventory Pipeline
- **Pipeline entry:** `_applyFeePipeline` composes base, confidence, size, inventory, BBO floors, LVR surcharge, and aggregator rebates (`contracts/DnmPool.sol:1689-1787`).
- **Confidence term:** `_computeConfidenceFeeBps` blends spread/sigma/pyth weights (HyperCore caps) aligning with `fee.alphaConfNumerator` / `fee.betaInvDevNumerator` defaults (`config/parameters_default.json`).
- **Size-aware fee:** Linear/quadratic adjustments plus caps (`contracts/lib/FeePolicy.sol:120`, `contracts/DnmPool.sol:1360`).
- **LVR surcharge:** Volatility × √TTL term activated via `enableLvrFee` flag and `fee.kappaLvrBps`; clamped to cap and emits `LvrFeeApplied` for observability (`contracts/DnmPool.sol:1753-1799`).
- **Aggregator allowlist:** Governance-managed `setAggregatorRouter` toggles rebate eligibility while preserving floors (`contracts/DnmPool.sol:653-672`).
- **Inventory tilt:** `_computeInventoryTiltBps` pulls deviation vs `targetBaseXstar`, weighted by spread/conf multipliers and clamped to `invTiltMaxBps` (`contracts/DnmPool.sol:1483`).
- **BBO-aware floor:** `_computeBboFloor` enforces maker-configured minimum fee tied to observed spread (`contracts/DnmPool.sol:1467`).

## Swap Execution Workflow
- **Quote:** `quoteSwapExactIn` triggers oracle reads, confidence aggregation, and pipeline evaluation without mutating reserves (`contracts/DnmPool.sol:421`).
- **Swap:** `swapExactIn` reuses the quote outcome, applies allow-listed rebates (F09), LVR surcharge, and floor preservation clamps (`contracts/DnmPool.sol:884`, `contracts/DnmPool.sol:1713-1778`).
- **Telemetry:** When debug mode is enabled, `PreviewLadderServed` surfaces ladder parity + TTL for routers, and `LvrFeeApplied` reports volatility surcharge hits to Prometheus ingesters (`contracts/DnmPool.sol:300-313`, `contracts/DnmPool.sol:1997-2051`).
- **RFQ integration:** `QuoteRFQ.verifyAndSwap` verifies EIP-712 signed quotes, checks TTL, and dispatches to pool swap functions (`contracts/quotes/QuoteRFQ.sol:162`).

- **Snapshot capture:** `_persistPreviewSnapshot` now records AOMQ state, volatility inputs, and caller metadata so preview ladders stay router-aligned (`contracts/DnmPool.sol:1877-1916`).
- **Preview APIs:** `previewFees` / `previewLadder` replay the pipeline against the stored snapshot, expose clamp flags, and honor LVR/allowlist states to keep parity with swaps (`contracts/DnmPool.sol:1296-1416`).
- **Raw inspection:** `previewSnapshotRaw()` returns the latest persisted snapshot for operators and observability tooling (`contracts/DnmPool.sol:1163-1167`).
- **Staleness guards:** `preview.maxAgeSec` defaults to 1 second with `revertOnStalePreview=true`, forcing routers to refresh snapshots; stale reads revert with `PreviewSnapshotStale(age, maxAge)`.

## Recenter & Inventory Governance
- **Manual recenter:** `setTargetBaseXstar` emits `TargetBaseXstarUpdated` and enforces timelock gating (`contracts/DnmPool.sol:766`).
- **Automatic recenter:** `_checkAndRebalanceAuto` triggers when hysteresis conditions pass (`contracts/DnmPool.sol:1549`), respecting `recenterCooldownSec` and healthy frame counters.
- **Governance controls:** Timelock-enforced parameter queues surface in `queueParams/executeParams`, while direct setters such as `setAggregatorRouter` (rebate allowlist) and feature toggles enable controlled rollout of LVR fees, preview freshness, and AOMQ knobs (`contracts/DnmPool.sol:567-707`).

## Observer & Autopause Layer
- **Oracle watcher:** `OracleWatcher` evaluates divergence, staleness, and error spikes from adapters; emits intents when thresholds breach (`contracts/observer/OracleWatcher.sol:200`).
- **Pause handler:** `DnmPauseHandler` consumes watcher intents, calls `pause()`/`unpause()` on the pool, and logs mitigations for SRE runbooks (`contracts/observer/DnmPauseHandler.sol:22`).
- **Shadow telemetry:** `shadow-bot` mirrors preview output, exports `dnmm_*` Prometheus series (including `dnmm_lvr_fee_bps`), and surfaces clamp/flag states for dashboards (`shadow-bot/metrics.ts:234-340`).
- **Testing:** `test/integration/OracleWatcher_PauseHandler.t.sol:19` validates watcher ↔ handler glue; `Scenario_CanaryShadow.t.sol:22` exercises alert-driven recentering in tandem with the bot.

## Data Flow Diagram
```mermaid
flowchart LR
  OracleHC[HyperCore Adapter] -->|mid, spread, sigma| DnmPool
  OraclePyth[Pyth Adapter] -->|mid, conf| DnmPool
  DnmPool -->|quote outcome| Preview[Preview Snapshot]
  Preview -->|previewFees / previewLadder| Router
  Router -->|swap tx (minOut, TTL)| DnmPool
  DnmPool -->|events| Observability[Prometheus + Shadow Bot]
  DnmPool -->|auto/manual recenter| Governance
  Governance -->|allowlist, params| Router
```

## Code & Test Index
- Core pool: `contracts/DnmPool.sol:333-2070`
- Oracle adapters: `contracts/oracle/OracleAdapterHC.sol:1-220`, `contracts/oracle/OracleAdapterPyth.sol:1-210`
- Fee policy library: `contracts/lib/FeePolicy.sol:1-210`
- Preview, ladder, and AOMQ scenarios: `test/integration/Scenario_Preview_AOMQ.t.sol:16`, `test/integration/Scenario_AOMQ.t.sol:21`, `test/integration/FirmLadder_TIFHonored.t.sol:18`, `test/integration/LvrFee_FloorInvariant.t.sol:18`
- LVR unit coverage: `test/unit/LvrFee_Monotonic.t.sol:1`, `test/unit/LvrFee_RespectsCaps.t.sol:1`
- Recenter coverage: `test/unit/DnmPool_Rebalance.t.sol:20`, `test/integration/Scenario_RecenterThreshold.t.sol:18`
- Observer layer: `contracts/observer/OracleWatcher.sol:1-260`, `contracts/observer/DnmPauseHandler.sol:1-120`, `test/integration/OracleWatcher_PauseHandler.t.sol:19`
