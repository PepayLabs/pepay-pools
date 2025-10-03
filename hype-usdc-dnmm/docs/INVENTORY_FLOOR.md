---
title: "Inventory Floor Guarantees"
version: "8e6f14e"
last_updated: "2025-10-03"
---

# Inventory Floor Guarantees

## Table of Contents
- [Overview](#overview)
- [Floor Types](#floor-types)
- [Partial Fill Logic](#partial-fill-logic)
- [AOMQ Integration](#aomq-integration)
- [Property Tests & Invariants](#property-tests--invariants)
- [Code & Test References](#code--test-references)

## Overview
Floors bound how much inventory the pool is willing to sell on either side. The solver clamps trades so reserves never drop below governance-configured thresholds, even when AOMQ or rebates are active.

## Floor Types
- **Quote-side floor (`floorQuote`):** Derived from `inventory.floorBps` applied to quote reserves (`contracts/lib/Inventory.sol:16`).
- **Base-side floor (`floorBase`):** Same `floorBps` parameter applied to base reserves during quote-in swaps (`contracts/lib/Inventory.sol:83`).
- **Dynamic adjustments:** Governance can set asymmetric floors by overriding `inventory.floorBps` alongside targeted `targetBaseXstar` updates (`contracts/DnmPool.sol:766`).

## Partial Fill Logic
- Solver functions `Inventory.quoteBaseIn` and `Inventory.quoteQuoteIn` return `(amountOut, appliedAmountIn, isPartial)` ensuring unused input is returned to sender (`contracts/lib/Inventory.sol:42-105`).
- If the requested trade would breach the floor, the solver finds the maximal fill that keeps reserves ≥ floor, reverts with `Errors.FloorBreach()` when no liquidity remains.
- Preview responses highlight partials via `QuoteResult.partial` flag (`contracts/interfaces/IDnmPool.sol:130`).

## AOMQ Integration
- When AOMQ is enabled (`featureFlags.enableAOMQ`), `_applyFeePipeline` can tighten spread or clamp size but still delegates to Inventory library for floor enforcement (`contracts/DnmPool.sol:1620`).
- AOMQ decisions encode ask/bid clamps in `AomqDecision` bitflags preserved in preview snapshots (`contracts/DnmPool.sol:1880`).
- Emergency spread widening (`aomq.emergencySpreadBps`) never bypasses floors; clamps occur before swap settlement and emit `AomqDecision` telemetry for shadow bot metrics (`test/integration/Scenario_AOMQ.t.sol:21`).

## Property Tests & Invariants
- **Partial fill parity:** `Scenario_FloorPartialFill.t.sol` asserts returned remainder matches requested minus applied fill.
- **Floor preservation:** `Scenario_Preview_AOMQ.t.sol` checks preview vs execution parity under floor constraints.
- **Invariant harness:** `script/run_invariants.sh` shards include floor-preserving swaps; review `Scenario_FloorPartialFill.t.sol:18` for failure reproduction steps.

## Code & Test References
- Inventory library: `contracts/lib/Inventory.sol:16-168`
- Errors: `contracts/lib/Errors.sol:11`
- Swap integration: `contracts/DnmPool.sol:884-1250`
- AOMQ flags: `contracts/DnmPool.sol:1620-1880`
- Tests: `test/integration/Scenario_FloorPartialFill.t.sol:18`, `test/integration/Scenario_AOMQ.t.sol:21`, `test/integration/Scenario_Preview_AOMQ.t.sol:21`
