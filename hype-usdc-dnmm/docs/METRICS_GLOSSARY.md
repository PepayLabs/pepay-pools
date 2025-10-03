---
title: "Metrics Glossary"
version: "8e6f14e"
last_updated: "2025-10-03"
---

# Metrics Glossary

## Table of Contents
- [Contract Signals](#contract-signals)
- [Shadow Bot Metrics](#shadow-bot-metrics)
- [Derived KPIs](#derived-kpis)
- [Dashboards Index](#dashboards-index)

## Contract Signals
Name | Type | Labels | Unit | Description | Source
--- | --- | --- | --- | --- | ---
`PreviewSnapshotRefreshed` | Event | `caller` | - | Snapshot persisted with mid, divergence, flags. | `contracts/DnmPool.sol:292`
`TargetBaseXstarUpdated` | Event | `oldTarget,newTarget,mid` | base WAD | Recenter executed. | `contracts/DnmPool.sol:288`
`DivergenceHaircut` | Event | `deltaBps,feeBps` | bps | Soft divergence haircut applied. | `contracts/DnmPool.sol:308`
`DivergenceRejected` | Event | `deltaBps` | bps | Hard divergence triggered; swap reverted. | `contracts/DnmPool.sol:309`
`ManualRebalanceExecuted` | Event | `caller,price` | WAD | Manual recenter completed. | `contracts/DnmPool.sol:289`
`QuoteFilled` | Event | `taker,isBaseIn,actualAmountIn,actualAmountOut` | token units | RFQ quote settled with partial fill info. | `contracts/quotes/QuoteRFQ.sol:55`
`AggregatorDiscountUpdated` | Event | `executor,discountBps` | bps | Rebate schedule change. | `contracts/DnmPool.sol:283`

## Shadow Bot Metrics
Name | Type | Labels | Unit | Description | Source
--- | --- | --- | --- | --- | ---
`dnmm_snapshot_age_sec` | Gauge | `pair,chain,mode` | seconds | Age of the preview snapshot. | `shadow-bot/metrics.ts:234`
`dnmm_regime_bits` | Gauge | `pair,chain,mode` | bitmask | Regime flags (soft divergence, AOMQ). | `shadow-bot/metrics.ts:243`
`dnmm_pool_base_reserves` | Gauge | `pair,chain,mode` | token units | Latest base reserves. | `shadow-bot/metrics.ts:252`
`dnmm_pool_quote_reserves` | Gauge | `pair,chain,mode` | token units | Latest quote reserves. | `shadow-bot/metrics.ts:256`
`dnmm_last_mid_wad` | Gauge | `pair,chain,mode` | WAD | Mid price at snapshot. | `shadow-bot/metrics.ts:260`
`dnmm_last_rebalance_price_wad` | Gauge | `pair,chain,mode` | WAD | Price recorded at last recenter. | `shadow-bot/metrics.ts:264`
`dnmm_quote_latency_ms` | Histogram | `pair,chain,mode` | milliseconds | Quote loop latency distribution. | `shadow-bot/metrics.ts:270`
`dnmm_delta_bps` | Histogram | `pair,chain,mode` | bps | HyperCore vs Pyth divergence. | `shadow-bot/metrics.ts:279`
`dnmm_conf_bps` | Histogram | `pair,chain,mode` | bps | Confidence value fed to fees. | `shadow-bot/metrics.ts:284`
`dnmm_bbo_spread_bps` | Histogram | `pair,chain,mode` | bps | HyperCore spread. | `shadow-bot/metrics.ts:289`
`dnmm_fee_bps` | Histogram | `pair,chain,mode,side,rung,regime` | bps | Fee pipeline output. | `shadow-bot/metrics.ts:294`
`dnmm_total_bps` | Histogram | `pair,chain,mode,side,rung,regime` | bps | Fee minus rebates. | `shadow-bot/metrics.ts:300`
`dnmm_provider_calls_total` | Counter | `pair,chain,mode,method,result` | count | Oracle RPC successes/failures. | `shadow-bot/metrics.ts:308`
`dnmm_precompile_errors_total` | Counter | `pair,chain,mode` | count | HyperCore read failures. | `shadow-bot/metrics.ts:318`
`dnmm_preview_stale_reverts_total` | Counter | `pair,chain,mode` | count | Preview requests that reverted on staleness. | `shadow-bot/metrics.ts:322`
`dnmm_aomq_clamps_total` | Counter | `pair,chain,mode` | count | AOMQ clamp occurrences. | `shadow-bot/metrics.ts:326`
`dnmm_recenter_commits_total` | Counter | `pair,chain,mode` | count | Auto/manual recenter commits. | `shadow-bot/metrics.ts:330`
`dnmm_quotes_total` | Counter | `pair,chain,mode,result` | count | Quote outcomes (`ok`, `error`, `fallback`). | `shadow-bot/metrics.ts:334`
`dnmm_two_sided_uptime_pct` | Gauge | `pair,chain,mode` | percent | Rolling two-sided uptime. | `shadow-bot/metrics.ts:340`

## Derived KPIs
KPI | Formula | Target
--- | --- | ---
Two-sided uptime | `avg_over_time(dnmm_two_sided_uptime_pct[15m])` | ≥ 99.5%
Adverse selection | `avg(dnmm_total_bps) - avg(dnmm_fee_bps)` (when AOMQ inactive) | ≥ -10 bps (positive preferred)
Divergence breach rate | `sum(dnmm_quotes_total{result="error"}) / sum(dnmm_quotes_total)` | ≤ 0.5%
Preview staleness | `dnmm_preview_stale_reverts_total` trend | Flat; revisit if slope positive

## Dashboards Index
File | Purpose
--- | ---
`shadow-bot/dashboards/dnmm_shadow_metrics.json` | Executive overview; pair summary.
`shadow-bot/dashboards/oracle-health.json` | Divergence, provider errors, TTL compliance.
`shadow-bot/dashboards/inventory-rebalancing.json` | Tilt, recenter cooldown, floor proximity.
`shadow-bot/dashboards/quote-health.json` | RFQ vs pool parity, AOMQ triggers, latency.
