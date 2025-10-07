# Shadow Bot Metrics Implementation Guide

**Path**: `hype-usdc-dnmm/shadow-bot/metrics`

**Description**: Local snapshots of Prometheus scrape data, scoreboard exports, and CSV artifacts produced by the DNMM shadow bot multi-run harness.

## Purpose
- Preserve reproducible evidence for benchmark runs and oncall investigations.
- Align stored metrics with the schemas documented in `docs/METRICS_GLOSSARY.md` and `docs/OBSERVABILITY.md`.
- Provide QA and protocol engineers with reference datasets for regression tests and pipeline tuning.

## Quick Start
- Build and execute the harness export: `npm run build && npm run multi -- --settings settings/hype_settings.json --ttl-sec 60 --export metrics/hype-metrics`.
- Inspect scoreboard outputs with `column -t -s, metrics/hype-metrics/run_<TIMESTAMP>/scoreboard.csv` to verify {run_id, setting_id, benchmark, pair} labels.
- Sync curated datasets to the shared location documented in `docs/OBSERVABILITY.md` once validated.

## Coding Standards
- Maintain directory naming as `run_<ISO8601>` to match automation hooks.
- Keep large gzip archives out of the repository; store only trimmed samples needed for documentation.
- Add README snippets to run folders when applying manual trims or anonymisation.

## Testing Expectations
- Spot-check emitted metrics using `rg 'shadow_preview_stale_total' metrics/hype-metrics/run_<TIMESTAMP>` and related key series.
- Diff scoreboard columns against the canonical header in `docs/MULTI_RUN_PIPELINE.md` before publishing new datasets.

## Operational Notes
- Mirror significant datasets to the shared bucket referenced in `docs/OBSERVABILITY.md#data-retention` for retention.
- Redact or rotate sensitive API keys before attaching logs alongside metrics.
- Coordinate deletions with oncall to avoid breaking active investigations or regression baselines.

## Maintainers & Contacts
- Primary: TBD (assign owner)
- Backup: TBD (assign delegate)
- Pager/Alert Routing: See `docs/RUNBOOK.md`

## Change Log
- 2025-10-07: Established metrics export handling guidance — unifies multi-run datasets with observability docs.
