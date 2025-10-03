# DNMM Shadow Bot Implementation Guide

**Path**: `hype-usdc-dnmm/shadow-bot`

**Description**: TypeScript observer that mirrors the HYPE/USDC DNMM preview pipeline, streams oracle/state data, and exports metrics + CSV traces for operators.

## Purpose
- Capture the runtime intent of the shadow bot and how it verifies DNMM behaviour against on-chain expectations.
- Document how telemetry (Prometheus, CSV, JSON) feeds SLOs and downstream dashboards.
- Provide maintainers with the key surfaces to adjust when protocol parameters or monitoring needs change.

## Quick Start
- Install dependencies and run `npm run start` with a configured `.env` to stream the live market.
- Use `npm run test` (Vitest) to validate config parsing, probe math, oracle decoding, metrics, and CSV formatting before shipping changes.
- Sync `ADDRESS_BOOK_JSON` and environment variables with production deployment records whenever addresses shift.

## Coding Standards
- Strict TypeScript, targeting Node 18+ with ESM modules; prefer pure functions and explicit types over `any`.
- Keep preview/probe logic side-effect free so tests can simulate with stubbed providers.
- Document non-obvious constants (e.g., HyperCore scaling, regime thresholds) inline.

## Testing Expectations
- Unit tests cover oracle decoding, regime classification, metrics export, and CSV rotation.
- Mock providers/contracts to avoid live RPC usage; snapshots belong under `__tests__/fixtures` if expanded.
- Add regression cases for new metrics or probe dimensions before merging.

## Operational Notes
- Track HyperCore precompile addresses/keys and Pyth feed ids; update `config.ts` defaults if production identifiers change.
- Maintain Prometheus alert mappings in `RUNBOOK.md` and Grafana dashboards referencing the exported series.
- Record open monitoring questions (e.g., additional regime bits, gas normalization) so on-call teams know current gaps.

## Maintainers & Contacts
- Primary: TBD (assign owner)
- Backup: TBD (assign delegate)
- Pager/Alert Routing: See `docs/OPERATIONS.md`

## Change Log
- 2025-10-03: Added mock (scenario engine) and fork (DeployMocks.s.sol) execution modes, `{mode}`-aware metrics/CSV outputs, refreshed Vitest coverage, and documentation for multi-mode operations.
- 2025-10-02: Re-architected bot into modular TypeScript stack (config/provider/oracle/poolClient/probes/metrics/CSV), added Prometheus histograms and rolling uptime, synthetic probe parity, and Vitest coverage.
