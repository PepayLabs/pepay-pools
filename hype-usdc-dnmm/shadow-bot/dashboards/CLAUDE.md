# Shadow Bot Dashboards Implementation Guide

**Path**: `hype-usdc-dnmm/shadow-bot/dashboards`

**Description**: Grafana-ready JSON exports for DNMM shadow bot observability (scoreboard, oracle health, inventory posture, quote quality).

## Purpose
- Keep dashboard exports synchronized with the metrics emitted by the multi-run harness.
- Ensure operators have consistent visualizations for uptime, PnL rate, and divergence guardrails.
- Provide integrators and oncall with actionable panels for debugging preview freshness and LVR fees.

## Quick Start
- Import `dnmm_shadow_metrics.json` via Grafana HTTP API: `curl -sS -H "Authorization: Bearer $GRAFANA_TOKEN" -H "Content-Type: application/json" -X POST https://$GRAFANA_HOST/api/dashboards/db --data-binary @dashboards/dnmm_shadow_metrics.json`.
- Cross-check panel queries against `docs/DASHBOARDS.md` before publishing changes.
- Run `jq empty dashboards/*.json` to validate JSON syntax before opening a PR.

## Coding Standards
- Keep JSON indented with two spaces and stable `uid` values for Grafana folder scoping.
- Use Prometheus query snippets that match the label sets documented in `docs/METRICS_GLOSSARY.md`.
- Document any experimental panels in commit messages and link back to the originating doc change.

## Testing Expectations
- Generate a fresh metrics snapshot with `npm run build && npm run multi -- --settings settings/hype_settings.json --ttl-sec 60 --export metrics/hype-metrics` to confirm panels render end-to-end.
- Validate scoreboard quadrants (top-right uptime vs PnL rate) against the latest multi-run output before sign-off.

## Operational Notes
- Coordinate dashboard updates with `docs/DASHBOARDS.md` so operators receive a single source of truth.
- Refresh alert thresholds when LVR surcharge, rebate caps, or preview TTL assumptions change.
- Archive superseded dashboards under `dashboards/archive/` with a README entry when deprecating panels.

## Maintainers & Contacts
- Primary: TBD (assign owner)
- Backup: TBD (assign delegate)
- Pager/Alert Routing: See `docs/RUNBOOK.md`

## Change Log
- 2025-10-07: Documented dashboard export guardrails — aligns dashboards with refreshed observability docs.
