# Settings Specifications Implementation Guide

**Path**: `hype-usdc-dnmm/shadow-bot/settings`

**Description**: JSON templates that drive multi-setting benchmark runs (DNMM + comparators), including sweeps, risk scenarios, and trade flow definitions.

## Purpose
- Capture reproducible multi-run configurations for the Shadow Bot suite.
- Document expectations for settings sweeps, comparator knobs, and scenario coverage.
- Ensure operators can audit run inputs alongside metrics outputs.

## Quick Start
- Reference the root template (`CLAUDE_TEMPLATE.md`) for required fields and conventions.
- Adjust `settings/*.json` when adding new experiments; keep IDs stable for diff-friendly comparisons.
- Align benchmark/comparator parameters with the on-chain contract configuration before launching runs.

## Coding Standards
- JSON files must be pretty-printed with two-space indentation.
- Use lowercase `snake_case` keys to match loader expectations.
- Keep numeric values explicit (no trailing commas, avoid scientific notation).

## Testing Expectations
- After editing settings, run `npm run build` and `node dist/multi-run.js --settings <file> --duration 5` to sanity-check parsing.
- Validate that generated CSV/metrics directories follow `metrics/hype-metrics/run_<RUN_ID>/…` conventions.

## Operational Notes
- Update `settings/hype_settings.json` in tandem with any `src/config-multi.ts` schema changes.
- Document experimental matrices and annotations in `docs/MULTI_RUN_PIPELINE.md` when adding new sweeps.

## Maintainers & Contacts
- Primary: TBD
- Backup: TBD

## Change Log
- 2025-10-04: Added guide to enforce documentation parity for settings sweeps and scenarios.
