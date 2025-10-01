# HYPE/USDC DNMM Config Implementation Guide

**Path**: `hype-usdc-dnmm/config`

**Description**: Environment-specific configuration, deployment parameters, and calibration artifacts for the DNMM stack.

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
- 2025-10-01: Normalised `maker.ttlMs` to 300 (matching contract defaults) and reiterated zero-default flags for AOMQ/Rebates/Governance scaffolding.
- 2025-10-01: Renamed the JSON toggle block to `featureFlags`, added inventory tilt/BBO floor/AOMQ defaults, rebates allowlist, and governance timelock scaffolding to `parameters_default.json`, and synced documentation.
- 2025-10-01: Introduced explicit `features` block plus soft-divergence parameters (`divergenceAccept/Soft/Hard`, `haircutMin/slope`) and size-fee coefficients (`gammaSizeLin`, `gammaSizeQuad`, `sizeFeeCap`) in JSON configs for F03–F12 roll-out; documentation synced with DNMM L3 spec gating.
