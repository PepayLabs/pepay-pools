---
title: "Rebalancing Implementation"
version: "8e6f14e"
last_updated: "2025-10-04"
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
- **Trigger point:** `_checkAndRebalanceAuto` runs inside swap settlement when `enableAutoRecenter` flag is true (`contracts/DnmPool.sol:1567`).
- **Hysteresis:** The pool accumulates healthy frames (`autoRecenterHealthyFrames`) before allowing a rebalance; divergence must exceed `inventory.recenterThresholdPct` (default `750` → 7.5%) to trigger.
- **Cooldown:** `_cooldownElapsed` enforces `recenterCooldownSec` between rebalance executions; violations revert with `Errors.RecenterCooldown()` (`contracts/DnmPool.sol:802`). Default cooldown is zero, maintaining a zero-default posture.
- **Outcome:** Successful auto rebalances broadcast `TargetBaseXstarUpdated` with the observed mid and timestamp (`contracts/DnmPool.sol:1641`). Tests: `test/unit/DnmPool_Rebalance.t.sol:20`, `test/integration/Scenario_RecenterThreshold.t.sol:18`.

## Manual Recenter Controls
- **Governance entrypoints:** `setTargetBaseXstar` and `manualRebalance` allow operators to push new targets when auto logic is disabled or out-of-band inventory moves occur (`contracts/DnmPool.sol:766`, `contracts/DnmPool.sol:825`).
- **Events:** Manual flows emit `ManualRebalanceExecuted` and `TargetBaseXstarUpdated` for downstream alerting (`contracts/DnmPool.sol:294`, `contracts/DnmPool.sol:825`).
- **Timelock:** Governance calls must respect `Errors.TimelockRequired()` if the configured delay is non-zero (`contracts/lib/Errors.sol:24`, `contracts/DnmPool.sol:567`).

## Inventory Solver Notes
- **Target computation:** `_computeInventoryTiltBps` derives deviation vs the target reserve share using `Inventory.deviationBps` (WAD arithmetic) before clamping (`contracts/DnmPool.sol:1496`, `contracts/lib/Inventory.sol:25`).
- **Partial fills:** Inventory library ensures partial fills honour floors while returning leftover input tokens (`contracts/lib/Inventory.sol:42-105`).
- **Solver telemetry:** Preview snapshots capture post-rebalance mid, flags, and LVR inputs for parity checks (`contracts/DnmPool.sol:1877-1916`).

## Gas Profile
- **Targets:** Keep auto recenter overhead <25k gas atop swap budget; manual rebalance under 120k gas.
- **Baselines (2025-10-04 projection):**
  - `swap_base_hc`: 303,400 gas / 305,000 budget (includes LVR surcharge + rebates).
  - `swap_quote_hc`: 300,900 gas / 305,000 budget.
  - Manual rebalance path (`manualRebalance`) unchanged (~88,421 gas); re-run targeted gas measurement post Core-4 deploy.
- **Optimization backlog:** Investigate caching floor reserves between quote+swap in the same block (`reports/gas/microopt_suggestions.md`).

## Edge Cases & Fail-Closed Paths
- Missing fresh oracle data → `Errors.MidUnset()` or `Errors.OracleStale()` prevents rebalance.
- Divergence haircuts disable recenter until healthy frames restored, ensuring we do not chase noisy prices (`contracts/DnmPool.sol:2090`).
- Timelock not satisfied → `Errors.TimelockRequired()`.
- Cooldown breach → `Errors.RecenterCooldown()`.
- Governance-provided target of zero is rejected by `Errors.InvalidConfig()`.
- LVR surcharge and rebate flags operate purely in the fee pipeline; they do not bypass hysteresis or cooldown checks.

## Code & Test References
- Auto recenter pipeline: `contracts/DnmPool.sol:1567-1659`
- Manual entrypoints: `contracts/DnmPool.sol:766-833`
- Inventory math: `contracts/lib/Inventory.sol:16-168`
- Error definitions: `contracts/lib/Errors.sol:5-40`
- Tests: `test/unit/DnmPool_Rebalance.t.sol:20-120`, `test/integration/Scenario_RecenterThreshold.t.sol:18-140`, `test/integration/Scenario_CanaryShadow.t.sol:22`
