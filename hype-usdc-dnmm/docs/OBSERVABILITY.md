---
title: "Observability"
version: "8e6f14e"
last_updated: "2025-10-03"
---

# Observability

## Table of Contents
- [Prometheus Metrics](#prometheus-metrics)
- [Derived KPIs](#derived-kpis)
- [Grafana Dashboards](#grafana-dashboards)
- [Alerts & Thresholds](#alerts--thresholds)
- [Event → Metric Mapping](#event--metric-mapping)

## Prometheus Metrics
Metric | Type | Labels | Unit | Description | Source
--- | --- | --- | --- | --- | ---
`dnmm_snapshot_age_sec` | Gauge | `pair, chain, mode` | seconds | Age of the preview snapshot consumed in the last loop. | `shadow-bot/metrics.ts:234`
`dnmm_regime_bits` | Gauge | `pair, chain, mode` | bitmask | Current pool regime flags (`SOFT`, `AOMQ_ASK`, `AOMQ_BID`). | `shadow-bot/metrics.ts:243`
`dnmm_pool_base_reserves` | Gauge | `pair, chain, mode` | token units | Last observed base reserves pulled from the pool. | `shadow-bot/metrics.ts:252`
`dnmm_pool_quote_reserves` | Gauge | `pair, chain, mode` | token units | Last observed quote reserves. | `shadow-bot/metrics.ts:256`
`dnmm_last_mid_wad` | Gauge | `pair, chain, mode` | WAD | Latest mid price captured in snapshot. | `shadow-bot/metrics.ts:260`
`dnmm_last_rebalance_price_wad` | Gauge | `pair, chain, mode` | WAD | Mid price recorded on last auto/manual recenter. | `shadow-bot/metrics.ts:264`
`dnmm_quote_latency_ms` | Histogram | `pair, chain, mode` | milliseconds | End-to-end quote loop latency. | `shadow-bot/metrics.ts:270`
`dnmm_delta_bps` | Histogram | `pair, chain, mode` | bps | HyperCore vs Pyth mid divergence per poll. | `shadow-bot/metrics.ts:279`
`dnmm_conf_bps` | Histogram | `pair, chain, mode` | bps | Confidence value used during fee computation. | `shadow-bot/metrics.ts:284`
`dnmm_bbo_spread_bps` | Histogram | `pair, chain, mode` | bps | Live HyperCore BBO spread. | `shadow-bot/metrics.ts:289`
`dnmm_fee_bps` | Histogram | `pair, chain, mode, side, rung, regime` | bps | Final fee applied per ladder rung and regime flags. | `shadow-bot/metrics.ts:294`
`dnmm_total_bps` | Histogram | `pair, chain, mode, side, rung, regime` | bps | Total fees including rebates and floors. | `shadow-bot/metrics.ts:300`
`dnmm_provider_calls_total` | Counter | `pair, chain, mode, method, result` | count | Oracle provider RPC attempts vs results. | `shadow-bot/metrics.ts:308`
`dnmm_precompile_errors_total` | Counter | `pair, chain, mode` | count | HyperCore precompile read failures. | `shadow-bot/metrics.ts:318`
`dnmm_preview_stale_reverts_total` | Counter | `pair, chain, mode` | count | Preview requests that reverted due to staleness. | `shadow-bot/metrics.ts:322`
`dnmm_aomq_clamps_total` | Counter | `pair, chain, mode` | count | AOMQ-triggered clamps in the last loop. | `shadow-bot/metrics.ts:326`
`dnmm_recenter_commits_total` | Counter | `pair, chain, mode` | count | Auto/manual recenter executions observed. | `shadow-bot/metrics.ts:330`
`dnmm_quotes_total` | Counter | `pair, chain, mode, result` | count | Quote attempts classified as `ok`, `error`, `fallback`. | `shadow-bot/metrics.ts:334`
`dnmm_two_sided_uptime_pct` | Gauge | `pair, chain, mode` | percent | Rolling two-sided liquidity uptime over 15 minutes. | `shadow-bot/metrics.ts:340`

### Multi-run (Benchmark) Metrics

When the multi-setting runner is active (`node dist/multi-run.js`), the Prometheus exporter exposes an additional family of `shadow.*` series labelled by `{run_id, setting_id, benchmark, pair}`.

Metric | Type | Labels | Unit | Description | Source
--- | --- | --- | --- | --- | ---
`shadow_mid` | Gauge | `run_id, setting_id, benchmark, pair` | WAD | Latest HyperCore mid observed for the benchmark during the tick. | `shadow-bot/src/metrics/multi.ts`
`shadow_spread_bps` | Gauge | `run_id, setting_id, benchmark, pair` | bps | HyperCore BBO spread forwarded to adapters. | `shadow-bot/src/metrics/multi.ts`
`shadow_conf_bps` | Gauge | `run_id, setting_id, benchmark, pair` | bps | Pyth confidence captured per tick. | `shadow-bot/src/metrics/multi.ts`
`shadow_uptime_two_sided_pct` | Gauge | `run_id, setting_id, benchmark, pair` | percent | Rolling 5-minute two-sided uptime for simulated quotes. | `shadow-bot/src/metrics/multi.ts`
`shadow_pnl_quote_cum` | Gauge | `run_id, setting_id, benchmark, pair` | quote units | Cumulative PnL accrued by the benchmark. | `shadow-bot/src/metrics/multi.ts`
`shadow_pnl_quote_rate` | Gauge | `run_id, setting_id, benchmark, pair` | quote units/min | PnL run-rate derived from cumulative PnL. | `shadow-bot/src/metrics/multi.ts`
`shadow_quotes_total` | Counter | `run_id, setting_id, benchmark, pair, side` | count | Quote samples taken (`base_in` / `quote_in`). | `shadow-bot/src/metrics/multi.ts`
`shadow_trades_total` | Counter | `run_id, setting_id, benchmark, pair` | count | Executed trades where `success=true`. | `shadow-bot/src/metrics/multi.ts`
`shadow_rejects_total` | Counter | `run_id, setting_id, benchmark, pair` | count | Trade intents rejected (min-out, insufficient liquidity, etc.). | `shadow-bot/src/metrics/multi.ts`
`shadow_aomq_clamps_total` | Counter | `run_id, setting_id, benchmark, pair` | count | Trades where AOMQ clamp engaged. | `shadow-bot/src/metrics/multi.ts`
`shadow_recenter_commits_total` | Counter | `run_id, setting_id, benchmark, pair` | count | Placeholder counter for recenter triggers (driver increments when applicable). | `shadow-bot/src/metrics/multi.ts`
`shadow_trade_size_base_wad` | Histogram | `run_id, setting_id, benchmark, pair` | WAD | Distribution of simulated trade sizes. | `shadow-bot/src/metrics/multi.ts`
`shadow_trade_slippage_bps` | Histogram | `run_id, setting_id, benchmark, pair` | bps | Observed slippage versus oracle mid. | `shadow-bot/src/metrics/multi.ts`
`shadow_quote_latency_ms` | Histogram | `run_id, setting_id, benchmark, pair, side` | milliseconds | Synthetic quote latency measurement per side. | `shadow-bot/src/metrics/multi.ts`

## Derived KPIs
- `two_sided_uptime_pct` = rolling success rate of quotes returning non-zero liquidity; use `dnmm_two_sided_uptime_pct`.
- `adverse_selection_bps` = `avg(dnmm_fee_bps)` − `avg(dnmm_total_bps)` when AOMQ inactive; negative swings warrant review of rebates.
- `preview_staleness_ratio` = `dnmm_preview_stale_reverts_total / dnmm_quotes_total{result="ok"}`.

## Grafana Dashboards
Dashboard | Path | Focus
--- | --- | ---
Inventory & Recenter | `shadow-bot/dashboards/inventory-rebalancing.json` | Tilt, recenter cooldown, floor proximity.
Oracle Health | `shadow-bot/dashboards/oracle-health.json` | Divergence histograms, provider error rates.
Quote Health | `shadow-bot/dashboards/quote-health.json` | TTL expiry, ladder parity, AOMQ triggers.
Shadow Summary | `shadow-bot/dashboards/dnmm_shadow_metrics.json` | Executive overview combining uptime, divergence, and fees.

## Alerts & Thresholds
Condition | Threshold | Action
--- | --- | ---
`dnmm_snapshot_age_sec > 2 * preview.maxAgeSec` (when `maxAgeSec > 0`) | Trigger warning | Refresh snapshot (`refreshPreviewSnapshot`) and inspect watcher logs.
`dnmm_delta_bps_p95_15m > oracle.hypercore.divergenceSoftBps` | Warning | Confirm HyperCore order-book health; review divergence policy.
`dnmm_preview_stale_reverts_total` increasing with default zero thresholds | Critical | Enable `revertOnStalePreview` or widen refresh cadence.
`dnmm_aomq_clamps_total` sustained > 0.1 per second | Critical | Review divergence soft gate and available inventory.
`dnmm_two_sided_uptime_pct < 99%` over 15 min | Warning | Inspect floors, auto recenter health, and AOMQ clamps.

## Event → Metric Mapping
Event | Metrics to Watch | Notes
--- | --- | ---
`PreviewSnapshotRefreshed` (`contracts/DnmPool.sol:292`) | `dnmm_snapshot_age_sec`, `dnmm_regime_bits` | Ensure age resets and flags match emitted decision.
`TargetBaseXstarUpdated` (`contracts/DnmPool.sol:288`) | `dnmm_recenter_commits_total`, `dnmm_last_rebalance_price_wad` | Confirm recenter increments counter and price stored.
`ManualRebalanceExecuted` (`contracts/DnmPool.sol:289`) | `dnmm_recenter_commits_total` | Manual runs should be rare; alert if >1 per hour.
`QuoteFilled` (`contracts/quotes/QuoteRFQ.sol:55`) | `dnmm_quotes_total{result="ok"}` | Compare taker fill rate vs pool parity via shadow bot.
`AggregatorDiscountUpdated` (`contracts/DnmPool.sol:283`) | `dnmm_fee_bps`, `dnmm_total_bps` | Validate discount effect on observed fees.
`PreviewSnapshotStale` (revert) | `dnmm_preview_stale_reverts_total` | Align with preview config changes.
