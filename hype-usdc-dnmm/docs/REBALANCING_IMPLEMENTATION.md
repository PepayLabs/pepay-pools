---
title: "Rebalancing Implementation"
version: "8e6f14e"
last_updated: "2025-10-03"
---

# Rebalancing Implementation

## Table of Contents
- [Overview](#overview)
- [Auto Recenter (F01)](#auto-recenter-f01)
- [Manual Recenter Controls](#manual-recenter-controls)
- [Inventory Solver Notes](#inventory-solver-notes)
- [Gas Profile](#gas-profile)
- [Edge Cases & Fail-Closed Paths](#edge-cases--fail-closed-paths)
- [Code & Test References](#code--test-references)

## Overview
Inventory targets keep base reserves aligned with the governance-defined `targetBaseXstar`. Recenter logic runs in two modes: automatic (triggered during swaps) and manual (explicit governance calls). Both converge on `_performRebalance` shared logic and emit the same telemetry hooks.

## Auto Recenter (F01)
- **Trigger point:** `_checkAndRebalanceAuto` runs inside swap settlement when `enableAutoRecenter` flag is true (`contracts/DnmPool.sol:1549`).
- **Hysteresis:** The pool accumulates healthy frames (`autoRecenterHealthyFrames`) before allowing a rebalance; divergence must exceed `inventory.recenterThresholdPct` (default `750` → 7.5%) to trigger.
- **Cooldown:** `_cooldownElapsed` enforces `recenterCooldownSec` between rebalance executions; violations revert with `Errors.RecenterCooldown()` (`contracts/DnmPool.sol:802`). Default cooldown is zero, maintaining a zero-default posture.
- **Outcome:** Successful auto rebalances broadcast `TargetBaseXstarUpdated` with the observed mid and timestamp (`contracts/DnmPool.sol:1616`). Tests: `test/unit/DnmPool_Rebalance.t.sol:20`, `test/integration/Scenario_RecenterThreshold.t.sol:18`.

## Manual Recenter Controls
- **Governance entrypoints:** `setTargetBaseXstar` and `manualRebalance` allow operators to push new targets when auto logic is disabled or out-of-band inventory moves occur (`contracts/DnmPool.sol:766`, `contracts/DnmPool.sol:800`).
- **Events:** Manual flows emit `ManualRebalanceExecuted` and `TargetBaseXstarUpdated` for downstream alerting (`contracts/DnmPool.sol:289`, `contracts/DnmPool.sol:821`).
- **Timelock:** Governance calls must respect `Errors.TimelockRequired()` if the configured delay is non-zero (`contracts/lib/Errors.sol:24`, `contracts/DnmPool.sol:567`).

## Inventory Solver Notes
- **Target computation:** `_computeInventoryTiltBps` derives deviation vs the target reserve share using `Inventory.deviationBps` (WAD arithmetic) before clamping (`contracts/DnmPool.sol:1483`, `contracts/lib/Inventory.sol:25`).
- **Partial fills:** Inventory library ensures partial fills honour floors while returning leftover input tokens (`contracts/lib/Inventory.sol:42-105`).
- **Solver telemetry:** Preview snapshots capture post-rebalance mid and flags for parity checks (`contracts/DnmPool.sol:1880`).

## Gas Profile
- **Targets:** Keep auto recenter overhead <25k gas atop swap budget; manual rebalance under 120k gas.
- **Baselines (2025-09-23 report):**
  - `swap_base_hc`: 210,893 gas / 225,000 budget (`reports/gas/gas_report.json`).
  - `swap_quote_hc`: 210,923 gas / 225,000 budget.
  - Manual rebalance path (`manualRebalance`) measured during smoke runs: 88,421 gas (see `gas-snapshots.txt` entry `recenter_manual`, when present). Current public snapshot (2025-10-03) omits manual call; re-run targeted gas measurement after edits.
- **Optimization backlog:** Investigate caching floor reserves between quote+swap in the same block (`reports/gas/microopt_suggestions.md`).

## Edge Cases & Fail-Closed Paths
- Missing fresh oracle data → `Errors.MidUnset()` or `Errors.OracleStale()` prevents rebalance.
- Divergence haircuts disable recenter until healthy frames restored, ensuring we do not chase noisy prices (`contracts/DnmPool.sol:2081`).
- Timelock not satisfied → `Errors.TimelockRequired()`.
- Cooldown breach → `Errors.RecenterCooldown()`.
- Governance-provided target of zero is rejected by `Errors.InvalidConfig()`.

## Code & Test References
- Auto recenter pipeline: `contracts/DnmPool.sol:1549-1635`
- Manual entrypoints: `contracts/DnmPool.sol:766-833`
- Inventory math: `contracts/lib/Inventory.sol:16-168`
- Error definitions: `contracts/lib/Errors.sol:5-40`
- Tests: `test/unit/DnmPool_Rebalance.t.sol:20-120`, `test/integration/Scenario_RecenterThreshold.t.sol:18-140`, `test/integration/Scenario_CanaryShadow.t.sol:22`
