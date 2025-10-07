# Shadow Bot Fork Scripts Implementation Guide

**Path**: `hype-usdc-dnmm/shadow-bot/script/fork`

**Description**: Fork automation scripts for DNMM shadow bot rehearsals (compile, deploy, configure, execute single+multi runs).

## Purpose
- Provide an end-to-end runner that mirrors the fork workflow documented in `docs/RUNBOOK.md`.
- Guarantee address books, `.dnmmenv`, and metrics exports stay consistent with deployment outputs.
- Enforce health gates (preview freshness, two-sided uptime) before publishing artifacts.

## Quick Start
- Export HyperEVM and deploy env vars (`FORK_RPC_URL`, `DNMM_*`) as detailed in `docs/RUNBOOK.md`.
- Execute `./shadow-bot/script/fork/dnmm-a2z.sh` from the repo root after installing dependencies.
- Inspect generated artifacts under `shadow-bot/metrics/` and `deployments/` before sharing results.

## Coding Standards
- Bash scripts must enable `set -euo pipefail`, implement traps, and log with timestamps.
- Use `jq` for JSON mutations; avoid ad-hoc `sed` when editing structured files.
- Parameterize ports, chain IDs, and run identifiers via environment variables with sane defaults.

## Testing Expectations
- Smoke-test against a fresh Anvil fork weekly to catch interface drift.
- Validate metrics gates locally and capture failures in the run log for post-mortems.
- Update fixtures in `docs/RUNBOOK.md` when script output formats change.

## Operational Notes
- Scripts should gracefully clean up background processes (Anvil) even on failure.
- Keep HyperCore precompile addresses sourced from governance docs; bump if infrastructure changes.
- Archive successful run artifacts to the shared bucket referenced in `docs/OBSERVABILITY.md`.

## Maintainers & Contacts
- Primary: TBD (assign owner)
- Backup: TBD (assign delegate)
- Pager/Alert Routing: See `docs/RUNBOOK.md`

## Change Log
- 2025-10-07: Added fork orchestration guide and `dnmm-a2z.sh` end-to-end runner.
