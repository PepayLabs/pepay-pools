# HYPE/USDC DNMM Docs Implementation Guide

**Path**: `hype-usdc-dnmm/docs`

**Description**: Architecture notes, runbooks, and operational references for the HYPE/USDC DNMM deployment on HyperEVM.

## Purpose
- Capture the intent of this module/folder and its relationship to the broader HYPE/HyperEVM initiative.
- Surface the critical user journeys, dependencies, and operational expectations for maintainers.

## Quick Start
- Review the open design docs under `docs/` for architecture and protocol rationale.
- Use the provided scripts/tests to validate the module locally before merging.
- Keep configuration values in sync with production deployment checklists.

## Coding Standards
- Solidity: target ^0.8.24; enable `unchecked` only with justification.
- TypeScript/Foundry scripts: prefer explicit types and non-async side effects.
- Document any non-obvious constants or math in comments or docstrings.

## Testing Expectations
- Include unit tests covering happy-path and failure-path behaviors.
- Provide property/invariant tests when math or state machines are involved.
- Attach reproducible scenarios (fixtures or scripts) for bugs before fixing.

## Operational Notes
- Track external dependencies (oracles, precompiles, external feeds) and their addresses.
- Define telemetry hooks and alerting thresholds for critical metrics/events.
- Track open questions that block production readiness.

## Maintainers & Contacts
- Primary: TBD (assign owner)
- Backup: TBD (assign delegate)
- Pager/Alert Routing: See `docs/OPERATIONS.md`

## Change Log
- 2025-10-04: Documented Core-4 upgrades—LVR fee term, ladder TTL telemetry, 1s preview freshness, governance playbooks, and observability metrics—and refreshed every doc under `docs/` to align with `elite-core-4-to-do` requirements.
- 2025-10-03: Regenerated architecture, rebalancing, fees, inventory floor, oracle, RFQ, observability, operations, divergence, config, and testing docs; added `ALGORITHMS.md`, `METRICS_GLOSSARY.md`, `GOVERNANCE_AND_TIMELOCK.md`, `GAS_OPTIMIZATION_GUIDE.md`, and `DOCS_INDEX.md` with updated feature matrices and front matter.
- 2025-10-02: Noted spot-mode fallback reliance on Pyth peeks in `RFQ.md` and extended `OBSERVABILITY.md` oracle-health guidance with `pyth_peek_failures_total` alerting to match new tests.
- 2025-10-02: Clarified preview snapshot defaults (`maxAgeSec = 0`, opt-in staleness reverts) across `ARCHITECTURE.md`, `RFQ.md`, `REBALANCING_IMPLEMENTATION.md`, and `OBSERVABILITY.md`; documented `Errors.MidUnset` fail-closed semantics in `DIVERGENCE_POLICY.md`.
- 2025-10-02: Added `ROUTER_INTEGRATION.md` for volume tiers/off-path process and updated `FEES_AND_INVENTORY.md`, `CONFIG.md`, `OBSERVABILITY.md`, `RUNBOOK.md`, and `CHANGELOG.md` for rebates, timelock, autopause, and preview freshness.
- 2025-10-01: Refreshed `REBALANCING_IMPLEMENTATION.md` for auto-recenter flag gating + hysteresis, and `TESTING.md` for the new `DnmPool_Rebalance` suite + CI guidance.
- 2025-10-01: Documented size-aware fee curve (gamma lin/quad coefficients, S0 normalisation, cap) in `ARCHITECTURE.md`.
- 2025-10-01: Documented soft divergence haircut bands (accept/soft/hard), new events, and hysteresis behaviour across `ARCHITECTURE.md` and `DIVERGENCE_POLICY.md`.
- 2025-10-01: Documented BBO-aware floor uplift (F05) in `ARCHITECTURE.md`, including the alpha/beta parameters and enforcement ordering.
- 2025-10-01: Documented inventory tilt upgrade (F06) and its weighting/cap formula in `ARCHITECTURE.md`, and added regression notes for `InventoryTiltTest`.
- 2025-10-01: Updated `CONFIG.md` to capture zero-default `featureFlags`, inventory tilt/BBO floor/AOMQ knobs, rebates allowlist, and governance timelock scaffolding in `parameters_default.json`.
- 2025-09-28: Added divergence guard reference (`docs/DIVERGENCE_POLICY.md`) and floor-invariant explainer (`docs/INVENTORY_FLOOR.md`).
- 2024-07-12: Documented confidence blending weights, EWMA sigma, and the `ConfidenceDebug` telemetry stream.
