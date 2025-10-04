# Shadow Bot Docs Implementation Guide

**Path**: `hype-usdc-dnmm/shadow-bot/docs`

**Description**: Authoritative documentation set for the multi-run benchmark suite (architecture, configs, dashboards, risk scenarios, operations).

## Purpose
- Capture the intent of this module/folder and its relationship to the broader HYPE/HyperEVM initiative.
- Surface the critical user journeys, dependencies, and operational expectations for maintainers.

## Quick Start
- Review `ARCHITECTURE.md` for the high-level component map.
- Consult `CONFIG_GUIDE.md` before editing `.dnmmenv` or settings JSON files.
- Use `RISK_SCENARIOS.md` to align simulation knobs with experiment design.
- Mirror updates in documentation whenever code paths or metrics change.

## Coding Standards
- Solidity: target ^0.8.24; enable `unchecked` only with justification.
- TypeScript/Foundry scripts: prefer explicit types and non-async side effects.
- Document any non-obvious constants or math in comments or docstrings.

## Testing Expectations
- Include unit tests covering happy-path and failure-path behaviors.
- Provide property/invariant tests when math or state machines are involved.
- Attach reproducible scenarios (fixtures or scripts) for bugs before fixing.

## Operational Notes
- Docs must evolve with the code; update the relevant markdown file when altering configs, metrics, or risk knobs.
- Keep dashboard screenshots, runbooks, and experiment specs synchronized with the latest release branch.
- Highlight any guardrail changes (e.g., strict oracle freshness) so oncall engineers understand expected behaviour.

## Maintainers & Contacts
- Primary: TBD (assign owner)
- Backup: TBD (assign delegate)
- Pager/Alert Routing: See `docs/RUNBOOK.md`

## Change Log
- 2025-10-04: Expanded documentation set with risk scenario playbook and telemetry updates.
