---
title: "Oracle & Data Path"
version: "8e6f14e"
last_updated: "2025-10-04"
---

# Oracle & Data Path

## Table of Contents
- [Overview](#overview)
- [HyperCore Adapter](#hypercore-adapter)
- [Pyth Adapter](#pyth-adapter)
- [Fallback & EMA Logic](#fallback--ema-logic)
- [Strict vs Relaxed Modes](#strict-vs-relaxed-modes)
- [Error Reference](#error-reference)
- [Code & Test References](#code--test-references)

## Overview
DNMM quotes anchor to HyperCore order-book data. Pyth feeds provide divergence checks and fallback pricing. Configuration lives under `oracle.*` in `config/parameters_default.json` and ships with zero-default feature flags.

## HyperCore Adapter
- Contract: `contracts/oracle/OracleAdapterHC.sol` initializes asset IDs, market keys, and scaling factors (`:1-120`).
- Functions: `readMidAndAge`, `readSpreadAndDepth`, `readEma` (expose age-adjusted prices and BBO data).
- Freshness: `oracle.hypercore.maxAgeSec = 48` sec default, enforced in `_readOracle` via `_ensureFresh` (`contracts/DnmPool.sol:1983`).
- Divergence guard: Soft/accept/hard caps (`divergenceAcceptBps = 30`, `divergenceSoftBps = 50`, `divergenceHardBps = 75`).

## Pyth Adapter
- Contract: `contracts/oracle/OracleAdapterPyth.sol` processes price/confidence pairs and rewrites to uniform scale (`:1-180`).
- Max age defaults to 40,000 sec; set tighter bounds in production. Confidence cap `oracle.pyth.confCapBps = 100` clamps variance.
- Used for both fallback pricing and blended confidence term.

## Fallback & EMA Logic
- `_getFreshSpotPrice` tries HyperCore spot; if stale or divergent it attempts EMA (`stallWindowSec = 10` sec) then Pyth (`contracts/DnmPool.sol:2097`).
- EMA fallback optional: `oracle.hypercore.allowEmaFallback` default `true`.
- When all sources fail, the pool reverts with `Errors.MidUnset()` preventing swaps/rebalances.

## Strict vs Relaxed Modes
- `OracleMode.Strict`: Used for RFQ verification & manual recenter to enforce tighter `confCapBpsStrict` and zero tolerance for fallback flags (`contracts/interfaces/IDnmPool.sol:94`).
- `OracleMode.Relaxed`: Default for regular quotes/swaps, allowing EMA/Pyth fallbacks.
- Strict mode additionally requires `stallWindowSec` freshness and reverts with `Errors.OracleStale()` if violated.
- Preview freshness defaults (`preview.maxAgeSec = 1`, `revertOnStalePreview = true`) mean routers must refresh snapshots at least once per second; stale ladders will throw `PreviewSnapshotStale`.

## Error Reference
Error | Description | Emitted From
--- | --- | ---
-`OracleStale()` | Data older than `maxAgeSec` | `contracts/DnmPool.sol:2004`
-`OracleSpread()` | BBO spread invalid or zero | `contracts/DnmPool.sol:2029`
-`OracleDiverged(uint256 deltaBps, uint256 maxBps)` | Delta against Pyth exceeded configured limit | `contracts/DnmPool.sol:2079`
-`DivergenceHard(uint256 deltaBps, uint256 hardBps)` | Hard cap exceeded (F03) | `contracts/DnmPool.sol:2090`
-`MidUnset()` | No valid mid after fallbacks | `contracts/DnmPool.sol:2140`
-`PreviewSnapshotUnset()` | Preview requested before any snapshot persisted | `contracts/DnmPool.sol:1147`
-`PreviewSnapshotStale(uint256 ageSec, uint256 maxAgeSec)` | Snapshot older than configured max when `revertOnStalePreview` true | `contracts/DnmPool.sol:1151`

## Code & Test References
- HyperCore adapter: `contracts/oracle/OracleAdapterHC.sol:1-220`
- Pyth adapter: `contracts/oracle/OracleAdapterPyth.sol:1-210`
- Pool oracle integration: `contracts/DnmPool.sol:1983-2160`
- Tests: `test/integration/Scenario_PythHygiene.t.sol:19`, `test/integration/Scenario_StaleOracle_and_Fallbacks.t.sol:20`, `test/integration/Scenario_DivergenceTripwire.t.sol:22`
