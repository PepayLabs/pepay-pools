# Observability & Telemetry Hooks

## Metrics
- `effective_price_bps` – Swap execution vs. oracle mid (compute off-chain from `SwapExecuted`).
- `fee_bps` – Emitted in `SwapExecuted`; combine with configuration to derive α/β components.
- `conf_bps` – Reconstruct from HyperCore spread / Pyth confidence stored alongside swap context.
- `inventory_deviation_bps` – Available from view helpers; track target vs actual inventory.
- `partial_fill_ratio` – Partial fill notional vs. requested (from `SwapExecuted.partial` + `partialFillAmountIn`).
- `oracle_mode` – Spot/EMA/Pyth fallback; use `reason` field (`"EMA"`, `"PYTH"`, etc.).
- `reject_reason` – Count occurrences of `Errors.Oracle*` and `Errors.FloorBreach()` via revert tracking.
- `fee_state_decay` – Monitor gap between `feeConfig.baseBps` and emitted `feeBps` across blocks for decay health.
- Parity exports (`mid_event_vs_precompile_mid_bps.csv`, `canary_deltas.csv`, `divergence_rate.csv`, `divergence_histogram.csv`) – snapshot oracle parity, fallback reasons, and divergence guard hit-rates per Δ bucket.
- Load test artefacts (`load_burst_summary.csv`, `load_fee_decay_series.csv`) – failure-rate, average fee, and recorded `fee_cap_bps` for the stress harness.

## Logs & Events
- `SwapExecuted(user, isBaseIn, amountIn, amountOut, mid, feeBps, partial, reason)` – Primary execution telemetry.
- `QuoteServed(bid, ask, s0, ttlMs, mid, feeBps)` – Top-of-book quoting for RFQ/aggregators.
- `TokenFeeUnsupported(user, isBaseIn, expectedAmountIn, receivedAmountIn)` – Canary for fee-on-transfer tokens causing swap aborts.
- `QuoteRFQ.hashQuote(params)` / `QuoteRFQ.hashTypedDataV4(params)` / `QuoteRFQ.verifyQuoteSignature(maker, params, sig)` – View helpers to confirm RFQ EIP-712 struct hashes and present the signable digest to off-chain monitors.
- `ParamsUpdated(kind, oldVal, newVal)` – Governance changes (Oracle/Fee/Inventory/Maker).
- `Paused(pauser)` / `Unpaused(pauser)` – Lifecycle controls.
- `ConfidenceDebug(confSpreadBps, confSigmaBps, confPythBps, confBps, sigmaBps, feeBaseBps, feeVolBps, feeInvBps, feeTotalBps)` – Optional diagnostic log gated by `DEBUG_EMIT`; surfaces confidence blend and fee decomposition per quote/swap.
- `OracleDivergenceChecked(pythMid, hcMid, deltaBps, divergenceBps)` – Emitted before `Errors.OracleDiverged` reverts when `debugEmit` is enabled; attach to divergence alerting.
- `OracleSnapshot(label, mid, ageSec, spreadBps, pythMid, deltaBps, hcSuccess, bookSuccess, pythSuccess)` – Emitted by the on-chain observer canary; mirrors pool oracle reads for block-synchronous parity dashboards.
- `OracleAlert(source, kind, value, threshold, critical)` – Emitted by `OracleWatcher` when observed age, divergence, or fallback usage violates configured thresholds. `kind` enumerates `Age`, `Divergence`, `Fallback`.
- `AutoPauseRequested(source, handlerCalled, handlerData)` – Fired by `OracleWatcher` whenever auto-pause is enabled and a critical alert is detected. The optional pause handler hook is invoked first; `handlerCalled` captures the call outcome, while `handlerData` surfaces revert payloads for debugging.

## Dashboards
- **Liquidity Health** – Track inventory deviation, floor breaches, partial percentages.
- **Oracle Health** – Monitor fallback usage, divergence rejects (`Errors.OracleDiverged()`).
- **Canary Shadow** – Track `canary_deltas.csv` median vs ε and ensure divergence rejections line up with observer deltas.
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
- Archive observer events alongside pool swaps to validate block-level parity (HC→EMA→PYTH) and drive automatic alerts when deltas exceed ε.
- After invariant or parity refresh jobs, consume `reports/metrics/freshness_report.json` to ensure CSV exports are ≤ 30 minutes old and meet minimum row counts before promoting artefacts to dashboards.
- Wire the daemon in `scripts/watch_oracles.ts` (see RUNBOOK) to ingest `OracleAlert`/`AutoPauseRequested` events, expose Prometheus metrics, and escalate on `critical=true`.

See also `docs/CONFIG.md` for parameter traceability and `docs/rfq_spec.md` for RFQ-specific telemetry.
