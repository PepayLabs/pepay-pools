# Observability & Telemetry Hooks

## Metrics
- `effective_price_bps` – Swap execution vs. oracle mid (compute off-chain from `SwapExecuted`).
- `fee_bps` – Emitted in `SwapExecuted`; combine with configuration to derive α/β components.
- `conf_bps` – Reconstruct from HyperCore spread / Pyth confidence stored alongside swap context.
- `inventory_deviation_bps` – Available from view helpers; track target vs actual inventory.
- `partial_fill_ratio` – Partial fill notional vs. requested (from `SwapExecuted.partial` + `partialFillAmountIn`).
- `oracle_mode` – Spot/EMA/Pyth fallback; use `reason` field (`"EMA"`, `"PYTH"`, etc.).
- `reject_reason` – Count occurrences of `Errors.ORACLE_*`, `Errors.FLOOR_BREACH` via revert tracking.
- `fee_state_decay` – Monitor gap between `feeConfig.baseBps` and emitted `feeBps` across blocks for decay health.

## Logs & Events
- `SwapExecuted(user, isBaseIn, amountIn, amountOut, mid, feeBps, partial, reason)` – Primary execution telemetry.
- `QuoteServed(bid, ask, s0, ttlMs, mid, feeBps)` – Top-of-book quoting for RFQ/aggregators.
- `ParamsUpdated(kind, oldVal, newVal)` – Governance changes (Oracle/Fee/Inventory/Maker).
- `Paused(pauser)` / `Unpaused(pauser)` – Lifecycle controls.

## Dashboards
- **Liquidity Health** – Track inventory deviation, floor breaches, partial percentages.
- **Oracle Health** – Monitor fallback usage, divergence rejects (`Errors.ORACLE_DIVERGENCE`).
- **Fee Dynamics** – Graph fee_bps vs time; overlay α/β contributions derived from oracle + inventory inputs.
- **Revenue** – Aggregate LP fees per period (amountIn × fee_bps/BPS).

## Alerting Baselines
- Divergence rejections > 3% of calls within 5 minutes.
- Partial fills > 10% of swap notional in an hour.
- `reason` = `"PYTH"` or `"EMA"` exceeding baseline (oracle degradation).
- `SwapExecuted` absence for >1 minute when maker S0 expected (RFQ degradation signal).

## Telemetry Integration
- Ingest events via an indexer (e.g., Subsquid on HyperEVM) and push to Prometheus/Grafana.
- Join on block timestamps with RFQ service logs to analyse latency and S0 consumption.
- Emit structured logs in keeper services including oracle payload metadata for replay.

See also `docs/CONFIG.md` for parameter traceability and `docs/rfq_spec.md` for RFQ-specific telemetry.
