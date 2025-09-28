# HYPE/USDC DNMM Integration Tests Implementation Guide

**Path**: `hype-usdc-dnmm/test/integration`

**Description**: Deterministic scenario suites validating oracle selection, parity, fallbacks, RFQ, and operational behavior for the HYPE/USDC DNMM.

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
- 2025-09-22: Added fork parity matrix (FP1–FP5), Pyth hygiene/delta flap scenarios, preview↔settlement parity (base, quote, RFQ), canary shadow observer coverage, and timestamp guard tests.
- 2024-07-12: Established Phase-8 confidence blend, fee dynamics, and fallback regression scenarios.
