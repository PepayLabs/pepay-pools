# Shadow Bot Scripts Implementation Guide

**Path**: `hype-usdc-dnmm/shadow-bot/script`

**Description**: Automation entrypoints for DNMM shadow bot operations, including fork rehearsals, deployment helpers, and integration handoffs.

## Purpose
- Centralize repeatable operational flows (compile, deploy, run) for the shadow bot suite.
- Reduce configuration drift by sourcing env vars and templates from the canonical docs.
- Provide runnable artifacts that align with SRE and integrator checklists.

## Quick Start
- Review `../docs/RUNBOOK.md` before invoking any automation script.
- Ensure required toolchains (Foundry, Node.js, jq) are installed locally.
- Run scripts from the repo root (`hype-usdc-dnmm/`) unless otherwise noted.

## Coding Standards
- Bash: use `set -euo pipefail`, trap cleanup, and explicit logging.
- TypeScript/Node helpers: target the existing `tsconfig.json`, prefer async/await with error handling.
- Document required environment variables at the top of each script.

## Testing Expectations
- Dry-run scripts against local forks before sharing with oncall.
- Add regression tests or CI hooks when scripts mutate stateful environments.
- Capture sample outputs (`stdout`, artifacts) for doc cross-linking.

## Operational Notes
- Coordinate updates with `docs/RUNBOOK.md` and `docs/CONFIG_GUIDE.md` to keep instructions in sync.
- Script side-effects (deployments, generated CSVs) should land under `metrics/` or `deployments/` with clear naming.
- Keep HyperCore constants (`hcPx`, `hcBbo`) aligned with governance docs when templating outputs.

## Maintainers & Contacts
- Primary: TBD (assign owner)
- Backup: TBD (assign delegate)
- Pager/Alert Routing: See `docs/RUNBOOK.md`

## Change Log
- 2025-10-07: Established scripts folder guide and introduced fork orchestration tooling.
