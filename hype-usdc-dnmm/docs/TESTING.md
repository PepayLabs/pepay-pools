---
title: "Testing Guide"
version: "8e6f14e"
last_updated: "2025-10-04"
---

# Testing Guide

## Table of Contents
- [Overview](#overview)
- [Test Matrix](#test-matrix)
- [Running Tests](#running-tests)
- [Gas Snapshots](#gas-snapshots)
- [Preview Parity Harness](#preview-parity-harness)
- [CI Expectations](#ci-expectations)

## Overview
DNMM uses Foundry-based unit/integration/invariant suites plus shadow-bot simulations. Maintain parity between docs and actual tests under `test/`.

## Test Matrix
Layer | Focus | Entry Points | Notes
--- | --- | --- | ---
Unit | Libraries & config guards | `test/unit/*.t.sol` | Covers FeePolicy, Inventory, divergence logic, governance queue, LVR surcharge maths.
Integration | Pipeline behavior end-to-end | `test/integration/*.t.sol` | Scenario-based sweeps for ladder parity, AOMQ clamps, floor partial fills, oracle fallbacks.
Invariants | Safety properties | `script/run_invariants.sh` | Executes forked invariants; ensure gas report optional.
Shadow Bot | Observability + replay | `shadow-bot/__tests__/*.ts` | Validate metrics emitter, probes, and replay harness.

## Running Tests
Command | Purpose
--- | ---
`forge test` | Full suite.
`forge test --match-contract DnmPoolRebalanceTest` | Focus on auto/manual recenter.
`forge test --match-contract Scenario_Preview_AOMQ` | Preview parity + AOMQ regression.
`forge test --match-contract LvrFeeMonotonicTest` | Validate σ/TTL monotonicity of the LVR term.
`forge test --match-contract FirmLadderTIFHonoredTest` | Audit ladder parity, TTL propagation, and stale preview reverts.
`FOUNDRY_PROFILE=gas forge test --gas-report` | Regenerate gas report before updating docs.
`yarn --cwd shadow-bot test` | Run shadow-bot Jest suite.

## Gas Snapshots
- Latest `gas-snapshots.txt` records:
  - `quote_hc`: 127,134 gas (2025-10-03).
  - `swap_base_hc`: 301,177 gas.
  - `rfq_verify_swap`: 459,964 gas.
- Historical baseline: `reports/gas/gas_report.json` (2025-09-23) shows headroom vs targets; refer before publishing regressions.
- Track improvements and pending work in `reports/gas/microopt_suggestions.md`.

## Preview Parity Harness
- `Scenario_Preview_AOMQ.t.sol` asserts preview ladder equality vs executed swaps under varying flags.
- Steps:
  1. Persist snapshot via `refreshPreviewSnapshot`.
  2. Call `previewLadder` for `[S0, 2S0, 5S0, 10S0]`.
  3. Listen for `PreviewLadderServed` (when `debugEmit` on) to confirm rung schema + TTL telemetry.
  4. Execute swaps; compare fees/amounts; ensure AOMQ clamps reported identically.
- Failures usually indicate `preview.*` config mismatch or missing `FeePreviewInvariant` state update.

## CI Expectations
- `forge fmt` enforced on Solidity changes.
- Preview parity suite (`--match-contract Scenario_Preview_AOMQ`) must pass; CI toggles `parityCiOn=true` on merge.
- `dnmm_preview_stale_reverts_total` must not regress; CI fails if baseline increases when freshness guard active.
- `FOUNDRY_PROFILE=gas forge test --gas-report` compared against `gas-snapshots.txt`; PRs exceeding thresholds fail.
- Docs linting & link checks (`yarn docs:lint`) run on contracts/config changes.
