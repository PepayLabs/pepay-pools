# HYPE/USDC DNMM Implementation Guide

**Path**: `hype-usdc-dnmm`

**Description**: Lifinity v2–style dynamic market maker stack for the HYPE/USDC pair on HyperEVM, including contracts, tests, and operational docs.

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
- Flag open questions or TODOs that block production readiness.

## Maintainers & Contacts
- Primary: TBD (assign owner)
- Backup: TBD (assign delegate)
- Pager/Alert Routing: See `docs/OPERATIONS.md`

## Change Log
- 2024-05-24: Folder initialized with contracts, docs, and Foundry harness.
- 2024-05-25: Synced fee/oracle config, added Inventory/Fee libraries, extended tests and tooling.
- 2024-07-12: Integrated Phase 8 confidence blend (EWMA sigma, feature flags), diagnostics, and extended fee parity metrics.
- 2025-09-22: Patched invariant runner shards to export Foundry profile/run env vars, removed deprecated `--profile` flags for Foundry 1.3.x, and confirmed parity gating is ready to block CI.
- 2025-09-22: Migrated QuoteRFQ signing to EIP-712 with verification helpers, updated docs, and hardened RFQ secret handling guidance.
- 2025-09-22: Extended invariant runner for multi-suite sharding, added parity metric gating/report scripts, enforced gas budgets, and instrumented Telemetry/Event docs (TokenFeeUnsupported, EMA/Pyth sequencing).
- 2025-09-23: Added remainder-aware shard planning, enhanced invariant reporting (parallel ETA, per-suite revert rates), enforced parity refresh + revert-rate gating, and expanded divergence tests with histogram exports.
- 2025-09-23: Normalized immutable naming with ABI-stable getters, cached swap/quote hot-path tokens for gas savings, refreshed gas reports, and documented parity freshness + planned oracle watcher workflow.
