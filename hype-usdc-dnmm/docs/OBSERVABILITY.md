# Observability & Telemetry Hooks

## Metrics
- **Oracle alignment**
  - `delta_bps` – |HyperCore mid − Pyth mid| in basis points.
  - `pyth_conf_bps` – Pyth confidence scaled to BPS.
  - `hc_spread_bps` – Live HyperCore order-book spread in BPS.
  - `decision{decision}` – Counter labelling accept / haircut / reject / aomq outcomes.
- **Economics**
  - `fee_ask_bps`, `fee_bid_bps` – Applied fees per side after discounts/floors.
  - `size_bucket{bucket}` – Counter for trade notional buckets (`<=S0`, `S0..2S0`, `>2S0`).
  - `ladder_points{bucket,side}` – Gauge exposing `previewFees` for `[S0,2S0,5S0,10S0]` buckets.
  - `agg_discount_bps` – Instantaneous aggregator discount for the configured executor address.
  - `rebates_applied_total` – Counter bump when an allow-listed executor receives a rebate.
- **Inventory & reliability**
  - `inventory_dev_bps` – Absolute deviation vs `targetBaseXstar`.
  - `recenter_commits_total` – Count of `TargetBaseXstarUpdated` events.
  - `two_sided_uptime_pct` – Rolling % of time both sides retain post-floor inventory.
  - `preview_snapshot_age_sec` – Age of the cached preview snapshot; pair with
    `preview_stale_reverts_total` (reverts surfaced to routers).
- **Canary artefacts**
  - Parity CSVs (`mid_event_vs_precompile_mid_bps.csv`, `canary_deltas.csv`, `divergence_histogram.csv`) continue to backfill dashboards.
  - Load-test exports (`load_burst_summary.csv`, `load_fee_decay_series.csv`) track decay drift and failure envelopes.

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
- `AutoPaused(watcher, reason, timestamp)` – Emitted by `DnmPauseHandler` once the watcher-driven pause succeeds; pairs with `Paused(pauser)` from the pool for operator acknowledgement.

## Dashboards
- **Liquidity Health** – Track inventory deviation, floor breaches, partial percentages.
- **Oracle Health** – Monitor fallback usage, divergence rejects (`Errors.OracleDiverged()`).
- **Canary Shadow** – Track `canary_deltas.csv` median vs ε and ensure divergence rejections line up with observer deltas.
- **Fee Dynamics** – Graph fee_bps vs time; overlay α/β contributions derived from oracle + inventory inputs.
- **Revenue** – Aggregate LP fees per period (amountIn × fee_bps/BPS).
- **Preview & Ladder** – Track snapshot age vs. max-age, the current ask/bid ladder, and clamp flags to surface impending stale previews before routers hit them.

## Alerting Baselines
- `reject_rate_pct_5m > 0.5` – either router misconfiguration or oracle stress; auto-escalate.
- `delta_bps_p95_15m > divergenceSoftBps` – parity risk; verify HyperCore + Pyth feeds.
- `precompile_error_rate > 0.1` – HyperCore read instability.
- `two_sided_uptime_pct < 98.5` – points to AOMQ / floor exhaustion.
- `abs(mid / lastRebalancePrice - 1) > divergenceHard && recenter_commits_total == 0` within 24h – recenter automation gap.
- `preview_snapshot_age_sec > previewMaxAgeSec` for two consecutive samples.
- `preview_stale_reverts_total` derivative > 0.5/min – routers hitting stale snapshots; check keepers.
- Partial fills > 10% of swap notional in an hour.
- `reason` = `"PYTH"` or `"EMA"` exceeding baseline (oracle degradation).

## Telemetry Integration
- Ingest events via an indexer (e.g., Subsquid on HyperEVM) and push to Prometheus/Grafana.
- Join on block timestamps with RFQ service logs to analyse latency and S0 consumption.
- Emit structured logs in keeper services including oracle payload metadata for replay.
- Archive observer events alongside pool swaps to validate block-level parity (HC→EMA→PYTH) and drive automatic alerts when deltas exceed ε.
- After invariant or parity refresh jobs, consume `reports/metrics/freshness_report.json` to ensure CSV exports are ≤ 30 minutes old and meet minimum row counts before promoting artefacts to dashboards.
- Wire the daemon in `scripts/watch_oracles.ts` (see RUNBOOK) to ingest `OracleAlert`/`AutoPauseRequested` events, expose Prometheus metrics, and escalate on `critical=true`.

See also `docs/CONFIG.md` for parameter traceability and `docs/rfq_spec.md` for RFQ-specific telemetry.
