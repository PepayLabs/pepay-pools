# HYPE/USDC DNMM Scripts Implementation Guide

**Path**: `hype-usdc-dnmm/script`

**Description**: Foundry and helper scripts for deploying, configuring, and exercising the HYPE/USDC DNMM on HyperEVM.

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
- 2025-10-03: Added `DeployMocks.s.sol` for fork-mode bring-up (mock tokens/oracles/pool, JSON output for shadow-bot) and documented OUTPUT_JSON flow.
- 2025-10-02: Set preview defaults in `Deploy.s.sol` to zero-max-age / non-reverting snapshots so rollouts can opt into staleness guards explicitly.
- 2025-10-01: Extended deployment fee config to include size-fee defaults (gamma lin/quad, cap) alongside zero-default feature flags.
- 2025-10-01: Updated `Deploy.s.sol` to pass zero-default feature flags (all `false`) per DNMM L3 gating requirements.
- 2025-09-28: Parameterised `script/Deploy.s.sol` via `DNMM_*` environment variables and documented required inputs in `docs/OPERATIONS.md`.
