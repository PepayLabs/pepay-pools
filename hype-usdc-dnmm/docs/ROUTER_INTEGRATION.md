# Router Integration Guide

## Purpose
Document the off-path (router) process for quote distribution, size tiers, and anti-gaming controls demanded by the DNMM L3 hybrid spec (F10).

## Audience
- Routing partners (aggregators, RFQ desks) integrating the DNMM pool off-chain.
- Internal operations monitoring inventory tilt, rebate performance, and timelock deployments.

## Quote Lifecycle
1. **Top-of-book fetch**: Call `getTopOfBookQuote(s0Notional)` every 250–500 ms. Respect the returned TTL and `quoteId`.
2. **Size ladder preview**: Use `previewFeesFresh` with sizes `[S0, 2S0, 5S0, 10S0]` to map fee steps before routing. Routers must retry with the latest oracle payload once `preview_snapshot_age_sec > preview.maxAgeSec` (shadow bot exports this metric).
3. **Swap submission**: Submit `swapExactIn` with the signed oracle bundle and include the TTL guard. Always surface `QuoteResult.reason` to downstream analytics for reject categorisation (accept/haircut/reject/AOMQ).
4. **Partial fills**: DNMM may partially fill to the floor when AOMQ is active. Routers must propagate the returned `partialFillAmountIn` and treat residual notionals as cancelled.

## Volume Tiering (Off-Path)
- **Size buckets**
  - `<=S0`: Standard routing tier, no rebates.
  - `S0..2S0`: Eligible for aggregator rebates when governance enables `enableRebates` and allow-lists the executor (≤3 bps discount after size/tilt/haircut).
  - `>2S0`: Routed via RFQ desks or internal inventory balancing; expect AOMQ clamps under degraded states.
- **Fee expectations**
  - Lin/quad size fees increase monotonically with size before rebates.
  - BBO-aware floors (`alphaBboBps`, `betaFloorBps`) prevent sub-book quotes after discounts.
  - Inventory tilt shifts bid/ask asymmetrically based on deviation and spread/conf weighting.

## Anti-Gaming Controls
- **Timelocked params**: Oracle/fee/inventory/maker/AOMQ/feature changes are staged with `queueParams` and executed after the timelock. Routers should track `ParamsQueued/ParamsExecuted` events to invalidate cached configs.
- **Preview freshness**: Reverts with `PreviewSnapshotStale`; routers must refresh snapshots or fallback to `previewFeesFresh` before resubmitting.
- **Rebates**: Discounts apply only to allow-listed executors and never breach the floor. Monitor `dnmm_agg_discount_bps` & `dnmm_rebates_applied_total` to detect abuse.
- **Recenter cadence**: `TargetBaseXstarUpdated` events are exported as Prometheus counters; operators investigate if hard divergence persists with zero commits in 24h.
- **Autopause**: Oracle watcher + pause handler halt the pool under critical divergence/age. Routers must honour `Paused` events and retry only after `Unpaused`.

## Operational Checklist
- Track Grafana dashboards `Oracles Health`, `Quote Health`, `Economics`, `Inventory Balance and Tilt`, `Recenter Activity`, and `Preview Freshness` (see `shadow-bot/dashboards/dnmm_shadow_metrics.json`).
- Run `forge test --match-path test/perf/GasSnapshots.t.sol` after any config change to ensure fast-path gas budgets remain ≤ spec limits.
- Keep `rebates.allowlist`/timelock actions documented in governance runbooks (see `RUNBOOK.md`).
