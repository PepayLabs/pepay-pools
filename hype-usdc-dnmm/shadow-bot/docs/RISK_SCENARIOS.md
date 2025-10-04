# Risk Scenario Playbook

This document explains how multi-run risk scenarios shape simulations, which knobs they touch, and how to validate outcomes with the emitted metrics and reports.

## Overview

```
"riskScenarios": [
  {
    "id": "crisis",
    "bbo_spread_bps": [60, 200],
    "sigma_bps": [80, 300],
    "pyth_outages": {"bursts": 3, "secs_each": 20},
    "pyth_drop_rate": 0.02,
    "quote_latency_ms": 400,
    "ttl_expiry_rate_target": 0.05,
    "autopause_expected": true
  }
]
```

Attach scenarios to a run via `riskScenarioId`. The runner clones the run, then applies the scenario rules before handing the configuration to adapters.

## Scenario Effects

| Scenario Field | Simulation Effect | Observability |
| --- | --- | --- |
| `bbo_spread_bps` | Expands or narrows the HyperCore spread range. | `shadow_spread_bps`, trade slippage histograms. |
| `sigma_bps` | Drives the stochastic shock amplitude for the simulated oracle. | `shadow_sigma_bps`. |
| `quote_latency_ms` | Overrides router latency, inducing larger min-out windows. | `shadow_quote_latency_ms`. |
| `duration_min` | Extends runtime length to guarantee sufficient coverage. | Run log (`shadowbot.multi.completed`). |
| `ttl_expiry_rate_target` | Scales maker/router TTL by `(1 - target)` to hit the desired timeout rate. | `timeout_expiry_rate_pct`, `shadow_pyth_strict_rejects_total`. |
| `pyth_outages` | Schedules deterministic outage bursts; oracle samples return `status: error`. | `shadow_pyth_strict_rejects_total`, analyst summary “Risk & Uptime”. |
| `pyth_drop_rate` | Adds independent dropout noise to Pyth responses. | Reject counters + preview staleness ratios. |
| `autopause_expected` | Narrative hint for the analyst summary. | Summary -> Risk & Uptime section. |

## Strict Freshness Guardrail

When the scenario (or live data) delivers stale Pyth quotes beyond `maxAgeSecStrict`, DNMM intents are rejected with reason `PythStaleStrict`. The rejection shows up in:

- `shadow_pyth_strict_rejects_total` Prometheus counter.
- `preview_staleness_ratio_pct` in the scoreboard.
- Analyst summary Risk section.

Use these signals to confirm the strict SLA is doing its job during outage simulations.

For TTL stress tests, compare the scenario target with the observed scoreboard value (analyst summary lists both). The difference highlights whether additional pressure or latency tweaks are required.

`scoreboard.json` captures the same run-level `scenarioMeta` map so downstream tooling can reconcile scenario configuration without reopening the original settings file.

## Operational Checklist

1. Ensure the scenario IDs in `runs[]` match an entry in `riskScenarios[]`.
2. Verify TTL adjustments: maker/router TTLs scale automatically; confirm the expected values in the `settings` artefact logged at runtime.
3. Watch `shadow_sigma_bps` & `shadow_pyth_strict_rejects_total` while the run executes. Spike patterns should align with the scenario definition.
4. If `autopause_expected` is true, confirm the summary narrative mentions it and that uptime dips remain above floor thanks to floors/min-outs.

---

_Last updated: 2025-10-04._
