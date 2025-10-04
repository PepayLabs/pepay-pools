# Dashboards & Telemetry Interpretation

This document captures how to interpret the CSV artefacts and Prometheus metrics exposed by the shadow bot. It is aimed at oncall engineers who triage the `shadow-*` dashboards and need to map time-series behaviour back to configuration changes.

---

## 1. Prometheus Series (`dnmm_*` vs `shadow_*`)

| Prefix | Scope | Labels | Typical Visualization |
| --- | --- | --- | --- |
| `dnmm_*` | Single-run bot (legacy), regardless of mock/fork/live | `pair`, `chain`, `mode`, plus per-metric extras (side, rung, regime) | Live dashboards that mirror production behaviour. |
| `shadow_*` | Multi-setting benchmark runner | `run_id`, `setting_id`, `benchmark`, `pair` (+ `side` for histograms) | Comparative panels for DNMM vs. baseline AMMs. |

### Key Gauges

- **`shadow_mid`** – HyperCore midpoint used for the most recent tick. Track divergence between settings (e.g., if a benchmark lags due to latency).
- **`shadow_spread_bps`** – BBO spread from HyperCore. When this widens, expect higher `shadow_trade_slippage_bps`.
- **`shadow_conf_bps`** – Pyth confidence. High confidence volatility often correlates with AOMQ clamps.
- **`shadow_sigma_bps`** – Scenario-driven volatility estimate (bps). Track alongside `shadow_spread_bps` to validate risk injections.
- **`shadow_uptime_two_sided_pct`** – Rolling 5-minute window showing the percentage of ticks where both sides of the book were available. Anything below ~99% warrants investigation.
- **`shadow_pnl_quote_cum` / `shadow_pnl_quote_rate`** – Total PnL per benchmark and its per-minute rate. Operators compare these to decide which configuration graduates to canary.

### Key Counters

- **`shadow_trades_total` / `shadow_rejects_total`** – Execution vs. rejection counts. A high reject fraction implies min-out or liquidity issues.
- **`shadow_aomq_clamps_total`** – Frequency of AOMQ protection; high counts indicate guardrails tripping.
- **`shadow_recenter_commits_total`** – Tracks recenter triggers (useful when inventory tilt or floor kicks in).
- **`shadow_pyth_strict_rejects_total`** – Count of trades rejected because Pyth data violated the strict freshness SLA. Spikes imply oracle instability or overly aggressive TTLs.

### Histograms

- **`shadow_trade_size_base_wad`** – Helps validate the intent size distribution against the configuration.
- **`shadow_trade_slippage_bps`** – Shows realised slippage; visualized as percentile chart.
- **`shadow_quote_latency_ms`** – Synthetic latency per side (baseline instrumentation for the simulation).

Refer to `docs/METRICS_GLOSSARY.md` for the complete metric table.

---

## 2. CSV Artefacts

Each benchmark run generates CSV files under `metrics/hype-metrics/run_<RUN_ID>/`:

| File | Use Case |
| --- | --- |
| `quotes/<SETTING>_<BENCHMARK>.csv` | Inspect quote ladders (fee BPS, mid, spread, confidence). Useful for debugging fallback vs. normal pricing. |
| `trades/<SETTING>_<BENCHMARK>.csv` | Deep-dive PnL components (amount in/out, fee, floor/tilt adjustments, AOMQ clamp flag). |
| `scoreboard.csv` | Roll-up view across benchmarks – the primary artefact for deciding winners. |

Suggested workflow:
1. Filter the scoreboard by `pnl_per_mm_notional_bps` to find the best performing settings per benchmark.
2. Check `two_sided_uptime_pct` and `reject_rate_pct` to ensure performance isn’t achieved by simply sitting out of the market.
3. Drill down into the corresponding trades CSV to review `aomq_clamped` and `slippage_bps_vs_mid` if anomalies appear.

---

## 3. Dashboards

While dashboards evolve, the canonical layout consists of:

1. **Summary Panel** – Current `scoreboard.csv` aggregated metrics (PnL, uptime, reject-rate). Refreshed per run.
2. **Quotes & Spread** – Plots of `shadow_mid` and `shadow_spread_bps` across settings/benchmarks. Useful for spotting spread widening or lag.
3. **Execution KPIs** – Bar/line charts for `shadow_trades_total`, `shadow_rejects_total`, and `shadow_aomq_clamps_total` keyed by `setting_id`. Quickly highlights underperforming or overly conservative settings.
4. **Win Rate vs. Uptime** – Combined panel using `shadow_pnl_quote_rate` and `shadow_uptime_two_sided_pct`. Optimal candidates live in the top-right quadrant (high uptime, positive PnL rate).
5. **Latency & Slippage Histograms** – Percentile charts derived from `shadow_quote_latency_ms` and `shadow_trade_slippage_bps` to check for outliers.

### Alerting Suggestions
- Reject rate > 0.5 over a 5-minute window (`shadow_rejects_total` vs. `shadow_trades_total`).
- Uptime < 98.5% for any benchmark (`shadow_uptime_two_sided_pct`).
- PnL rate sharply negative over a 15-minute window (use `shadow_pnl_quote_rate`).

---

## 4. Exporting Dashboards

Different teams may have slightly different exports. When committing Grafana dashboards:
- Save JSON exports annotated with `run_id` and `settings file` context.
- Store them under `dashboards/` with a clear naming convention (`benchmark_summary_vX.json`).
- Ensure the metric queries reference the correct label sets (`run_id`, `setting_id`, `benchmark`).

---

_Last updated: 2025-10-04._
