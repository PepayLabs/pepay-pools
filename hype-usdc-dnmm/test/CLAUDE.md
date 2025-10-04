# HYPE/USDC DNMM Tests Implementation Guide

**Path**: `hype-usdc-dnmm/test`

**Description**: Foundry unit, integration, invariant, and performance suites validating the HYPE/USDC dynamic market maker.

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
- 2025-10-04: Added LVR coverage (`LvrFee_Monotonic`, `LvrFee_RespectsCaps`, `LvrFee_FloorInvariant`) and ladder TTL parity suite (`FirmLadder_TIFHonored`); updated config schema assertions for `enableLvrFee`, preview freshness, and queue tests.
- 2025-10-02: Recalibrated `PreviewFees_Parity` (30 bps divergence, near-floor reserve trim) and the stale oracle fallback suite to assert `ForcedPeek`/`ForcedRead` semantics; refreshed gas snapshots and perf harness to lock `quote_hc` at 127k.
- 2025-10-02: Updated AOMQ/preview integrations (`Scenario_AOMQ`, `Scenario_Preview_AOMQ`, `ForkParity`) to assert activation events + clamp flags, adopted `Errors.MidUnset` for zero-mid fail-closed paths, and tuned near-floor fixtures for the lower min-notional / higher epsilon config.
- 2025-10-02: Added `Rebates_FloorPreserve` (F09), `DnmPool_GovernanceTimelock` (F11), `ReadOracle_MidUnset_Coverage`, `Preview_ViewPurity`, and `OracleWatcher_PauseHandler` suites exercising rebates, timelock queue/execute/cancel, fail-closed oracle paths, view purity, and autopause wiring.
- 2025-10-01: Added `Scenario_AOMQ` integration coverage (soft divergence activation, oracle-hard fault guard, floor-adjacent micro quotes, BBO spread enforcement) validating the new F07 pipeline end-to-end.
- 2025-10-01: Added `PreviewFees_Parity` unit suite and `Scenario_Preview_AOMQ` integration flow to guarantee snapshot previews remain bit-exact with quotes (including AOMQ clamps) and to assert staleness handling.
- 2025-10-01: Extended `ConfigSchemaTest` to assert feature-flag defaults (AOMQ/Rebates/AutoRecenter), governance timelock scaffolding, preview config defaults, and executor discount accessors to gate upcoming F07–F12 work.
- 2025-10-01: Added `BboFloorTest` covering spread-tracking floor, fallback absolute floor, and cap interaction.
- 2025-10-01: Added `InventoryTiltTest` ensuring restorative trades receive discounts/surcharges per F06 weighting and matching the analytical tilt formula.
- 2025-10-01: Added `ConfigSchemaTest` validating inventory tilt, maker BBO floor, and AOMQ config defaults plus governance bounds on new parameters.
- 2025-10-01: Extended `DnmPool_Rebalance` coverage for auto recenter flag gating, cooldown suppression, hysteresis streak recovery, and stale-oracle regressions.
- 2025-10-01: Added `SizeFeeCurveTest` validating linear/quadratic surcharge monotonicity, cap enforcement, and preview↔swap parity.
- 2025-10-01: Added `SoftDivergenceTest` covering haircut math, hard-band rejections, and hysteresis recovery alongside new `getSoftDivergenceState()` helper.
- 2025-10-01: Added `FeatureFlagsTest` to enforce zero-default toggles and governance-controlled enablement; updated quote suite bootstrapping for explicit debug/blend opt-ins.
- 2025-09-28: Added divergence policy regression (unit) and floor monotonicity/property fuzz suites to cover partial-fill invariants.
- 2025-09-28: Introduced HyperCore precompile harness (`MockHyperCorePx/Bbo`) and canonical-address etching helpers to exercise raw 32-byte interfaces plus fail-closed regression tests.
- 2025-09-22: Added fork parity regression suite (incl. full precompile matrix), preview↔settlement parity (base, quote, RFQ), Pyth hygiene/divergence flap suites, canary observer shadow tests, timestamp guard, DoS gas campaign, and 5k-load metrics exports.
- 2024-07-12: Added FeeDynamics_B5/B6 correlation & cap-edge suites plus ConfidenceDebug decoding helpers.
