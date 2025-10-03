---
title: "Divergence Policy"
version: "8e6f14e"
last_updated: "2025-10-03"
---

# Divergence Policy

## Table of Contents
- [Thresholds](#thresholds)
- [Haircut Computation](#haircut-computation)
- [Hysteresis & Healthy Frames](#hysteresis--healthy-frames)
- [Preview & RFQ Interaction](#preview--rfq-interaction)
- [Events & Telemetry](#events--telemetry)
- [Tests](#tests)

## Thresholds
- **Accept (`divergenceAcceptBps` = 30 bps):** Swaps proceed with no haircut; soft divergence state remains inactive.
- **Soft (`divergenceSoftBps` = 50 bps):** Enables F03 haircuts when flag `enableSoftDivergence` true (`contracts/DnmPool.sol:1939`).
- **Hard (`divergenceHardBps` = 75 bps):** Triggers `Errors.DivergenceHard` and fails closed (`contracts/DnmPool.sol:2210`).
- Default thresholds sourced from `config/parameters_default.json`.

## Haircut Computation
- Haircut = `haircutMinBps + haircutSlopeBps * max(0, deltaBps - acceptBps)`.
- Config defaults: `haircutMinBps = 3`, `haircutSlopeBps = 1` (bps per extra bps beyond accept).
- Implemented in `_processSoftDivergence` and `_previewSoftDivergence` (`contracts/DnmPool.sol:2324-2385`).
- Applied fee increase flows through `_applyFeePipeline` as add-on bps.

## Hysteresis & Healthy Frames
- `SoftDivergenceState` tracks `healthyStreak`; requires consecutive frames under accept threshold before clearing (`contracts/DnmPool.sol:2332-2369`).
- Recenter logic checks `softDivergenceActive` and defers auto recenter until state is healthy (`contracts/DnmPool.sol:1549`).
- Preview snapshots mark soft state in `snap.flags` for downstream parity checks (`contracts/DnmPool.sol:1882`).

## Preview & RFQ Interaction
- Preview path reuses `_previewSoftDivergence` to ensure ladder fees match swap path (`contracts/DnmPool.sol:2176-2196`).
- RFQ strict mode rejects quotes when delta exceeds accept threshold; TTLs should account for divergence-induced fallbacks.
- `PreviewSnapshotStale` may increase when soft divergence persists; monitor `dnmm_preview_stale_reverts_total`.

## Events & Telemetry
Event | Meaning | Metrics
--- | --- | ---
`OracleDivergenceChecked` (`contracts/DnmPool.sol:307`) | Logged on every Pyth compare to record delta and bound. | `dnmm_delta_bps`, `dnmm_conf_bps`
`DivergenceHaircut` (`contracts/DnmPool.sol:308`) | Soft haircut applied with magnitude. | `dnmm_fee_bps`
`DivergenceRejected` (`contracts/DnmPool.sol:309`) | Hard divergence triggered; swap reverted. | `dnmm_quotes_total{result="error"}`

## Tests
- Unit: `test/unit/SoftDivergenceTest.t.sol:18` verifies haircut slope and reset.
- Integration: `test/integration/Scenario_DivergenceTripwire.t.sol:22`, `test/integration/Scenario_DivergenceHistogram.t.sol:19` cover soft/hard gating and histogram output.
