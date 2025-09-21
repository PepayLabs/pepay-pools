# Observability & Telemetry Hooks

## Metrics

- `effective_price_bps` – Execution vs. oracle mid per swap.
- `fee_bps` – Post-trade fee value; track percentile bands.
- `conf_bps` – Confidence proxy from oracle pathway.
- `inventory_deviation_bps` – Distance from `targetBaseXstar`.
- `partial_fill_ratio` – Partial fill notional vs. requested.
- `oracle_mode` – Spot / EMA / Pyth fallback usage breakdown.
- `reject_reason` – Count by `Divergence`, `Stale`, `Spread`, `Floor`.

## Logs & Events

- `SwapExecuted(user, isBaseIn, amountIn, amountOut, mid, feeBps, partial, reason)`
- `QuoteServed(bid, ask, s0, ttlMs, mid, feeBps)`
- `ParamsUpdated(kind, oldVal, newVal)`
- `Paused(pauser)` / `Unpaused(pauser)`

## Dashboards

- **Liquidity Health** – Inventory deviation, floor breaches, partial fills.
- **Oracle Health** – HyperCore freshness vs. fallback usage; divergence histogram.
- **Fee Dynamics** – Base vs. dynamic fee components over time.
- **Revenue** – LP fee accrual vs. hedging costs (if keeper enabled).

## Alerting Baselines

- Divergence rejection ratio > 3% over 5 minutes.
- Partial fill count > 3 per minute sustained.
- Oracle fallback usage > 25% of swaps.
- No `QuoteServed` in > 1 minute (RFQ degradation signal).

## Telemetry Integration

- Emit structured logs via an off-chain indexer; recommended stack: Subsquid (on HyperEVM) + Prometheus exporters.
- Correlate on-chain block timestamps with maker service telemetry for latency analysis.
- Ship aggregated metrics to Grafana/Looker dashboards; include runbook links.
