# Known Issues & Follow-Up Tasks

This list tracks open problems and work items that require attention before declaring the shadow bot “fully done.” Keep it updated as issues are resolved.

## 1. Testing
- Legacy Vitest suites (`src/__tests__/`) have not been migrated to the new `node --test` harness. Until they are ported into `test/`, coverage is limited to the smoke checks we create manually.
- Sandbox npm cache occasionally ships truncated packages; when adding new dependencies, verify the compiled JS assets exist in `node_modules`.

## 2. Multi-Run Runner
- Benchmark adapters currently log deterministic output but still need deeper property/invariant tests (e.g., CPMM invariant preservation, StableSwap amplification edge cases).
- Scoreboard aggregation assumes `S0Notional` is expressed in quote units; confirm this matches future settings files.

## 3. Documentation
- Grafana dashboard JSON exports should be captured under `dashboards/` for historical reference (currently left to oncall playbooks).
- Add a runbook section describing the canary promotion process once the benchmark scoreboard becomes part of deployment gating.

## 4. Operational Items
- `.dnmmenv` ships with placeholder RPC/token addresses. Replace with production values before live use and ensure secrets are handled outside the repo.
- Alert configurations mentioned in `docs/DASHBOARDS.md` are not yet codified in the alerting repo; action items remain pending.

_Last updated: 2025-10-04._
