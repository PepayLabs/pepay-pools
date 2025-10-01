# HYPE/USDC DNMM Contracts Implementation Guide

**Path**: `hype-usdc-dnmm/contracts`

**Description**: Solidity sources for the HYPE/USDC dynamic market maker, oracle adapters, libraries, mocks, and interfaces.

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
- 2025-10-01: Extended configuration structs (inventory tilt weights, maker BBO floor coefficients, `AomqConfig`), introduced `ParamKind.Aomq` with bounds checks, and surfaced `aomqConfig` getter to unblock F05–F07 plumbing.
- 2025-10-01: Gated auto recentering behind `enableAutoRecenter`, introduced the `autoRecenterHealthyFrames` hysteresis counter (3 healthy frames) with cooldown integration, and reset streaks on governance/manual commits.
- 2025-10-01: Added size-aware fee surcharge gated by `enableSizeFee` (gamma linear/quadratic coefficients, cap, notional normalization) with preview/swap parity handling and tests.
- 2025-10-01: Added soft divergence haircut state machine (`divergenceAccept/Soft/Hard`, `haircutMin/slope`, events, hysteresis) gated behind `enableSoftDivergence`; updated fee plumbing and tests.
- 2025-10-01: Expanded `FeatureFlags` to include zero-default toggles for upcoming F03–F09/F12 upgrades, defaulting all flags to `false` and adding governance tests for explicit enablement.
- 2025-09-28: Added `Errors.OracleDiverged`, symmetric divergence gating with debug telemetry, floor-conserving inventory solvers (helper decomposition for partial fills), guarded `_confidenceToBps` against zero-confidence feeds, and aligned `MockOracleHC` response modes with fail-closed semantics for regression tests.
- 2025-09-28: Rewired `OracleAdapterHC` to HyperCore's raw 32-byte precompiles (0x0806/0x0807/0x0808/0x080e) with fail-closed semantics; added address-pin tests and canonical constants.
- 2025-09-22: Hardened oracle handling with precompile failure fallbacks, invalid orderbook guardrails, Pyth-only confidence blending + strict caps, timestamp regression checks, and explicit fee-on-transfer rejection in `DnmPool`.
- 2024-07-12: Added confidence-blend feature flags, EWMA sigma state, and `ConfidenceDebug` emission across quoting/swap paths.
