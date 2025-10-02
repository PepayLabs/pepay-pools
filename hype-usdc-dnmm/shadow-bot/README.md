# DNMM Shadow Bot – HYPE/USDC Observer

Enterprise telemetry harness for the HYPE/USDC Dynamic Nonlinear Market Maker (DNMM) on HypeEVM. The bot mirrors the full preview pipeline, streams state, and publishes a Prometheus surface for live dashboards and alerting.

## Quick Start

```bash
# install dependencies
npm install

# run once with local .env
npm run start

# run tests
npm run test
```

The entrypoint `shadow-bot.ts` loads configuration from environment variables (see next section), opens JSON-RPC + optional WebSocket providers, and executes the loop every `INTERVAL_MS` milliseconds. Each loop performs:

1. Read HyperCore price/BBO precompiles and optional Pyth feed.
2. Pull DNMM pool state and config (fee, inventory, maker, flags).
3. Replay preview paths for both sides across the configured size grid.
4. Emit Prometheus metrics, append CSV traces under `metrics/hype-metrics/`, and refresh the JSON summary payload.

## Configuration

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `RPC_URL` | ✅ | – | HTTPS RPC endpoint for HypeEVM reads. |
| `WS_URL` | optional | – | WebSocket endpoint for event subscriptions (TargetBaseXstarUpdated, AomqActivated). |
| `POOL_ADDR` | ✅ | – | Deployed `DnmPool` address. |
| `PYTH_ADDR` | optional | – | Pyth contract address used for `getPriceUnsafe` checks. |
| `PYTH_PRICE_ID` | optional | – | 32-byte feed id (use HYPE/USDC composite). |
| `HC_PX_PRECOMPILE` | optional | `0x…0807` | HyperCore oraclePx precompile. |
| `HC_BBO_PRECOMPILE` | optional | `0x…080e` | HyperCore BBO precompile. |
| `HC_PX_KEY` | optional | `107` | Market index for oraclePx lookup. |
| `HC_BBO_KEY` | optional | `HC_PX_KEY` | Market index for BBO lookup. |
| `HC_MARKET_TYPE` | optional | `spot` | `spot` or `perp`; controls price scaling. |
| `HC_SIZE_DECIMALS` | optional | `2` | HyperCore size decimals (used for scaling multiplier). |
| `BASE_DECIMALS` / `QUOTE_DECIMALS` | optional | 18 / 6 | Token decimals override. |
| `HYPE_ADDR` / `USDC_ADDR` | optional | – | Token addresses (falls back to address-book when present). |
| `SIZES_WAD` | optional | `0.1,0.5,1,2,5,10` | Comma-separated base sizes in WAD for probes. |
| `INTERVAL_MS` | optional | `5000` | Loop cadence. |
| `SNAPSHOT_MAX_AGE_SEC` | optional | `30` | Alert threshold for preview staleness. |
| `PROM_PORT` | optional | `9464` | Prometheus HTTP port. |
| `GAS_PRICE_GWEI` | optional | – | Used for gas normalization metrics (future work placeholder). |
| `LOG_LEVEL` | optional | `info` | `info` or `debug`. |
| `CSV_DIR` | optional | `../metrics/hype-metrics` | Override CSV output directory. |
| `JSON_SUMMARY_PATH` | optional | `../metrics/hype-metrics/shadow_summary.json` | Summary JSON location. |

Optional: provide `ADDRESS_BOOK_JSON` (defaults to `shadow-bot/address-book.json`). When present, the book can preload addresses, decimals, and WS endpoints per environment.

## Loop Outputs

### Prometheus Metrics

The registry is exposed at `http://0.0.0.0:${PROM_PORT}/metrics` with common labels `{pair="HYPE/USDC", chain="HypeEVM"}`.

| Metric | Type | Labels | Description |
| --- | --- | --- | --- |
| `dnmm_snapshot_age_sec` | gauge | – | Age of the preview snapshot reported by the pool. |
| `dnmm_regime_bits` | gauge | – | Bitmask of current regime (1=AOMQ, 2=Fallback, 4=NearFloor, 8=SizeFee, 16=InvTilt). |
| `dnmm_pool_base_reserves` / `dnmm_pool_quote_reserves` | gauge | – | Raw reserves from `reserves()`. |
| `dnmm_last_mid_wad` | gauge | – | Latest mid in WAD units. |
| `dnmm_last_rebalance_price_wad` | gauge | – | Updated on `TargetBaseXstarUpdated` events. |
| `dnmm_delta_bps` | histogram | – | HC vs Pyth delta in basis points. |
| `dnmm_conf_bps` | histogram | – | Pyth confidence interval in bps. |
| `dnmm_bbo_spread_bps` | histogram | – | HyperCore BBO spread in bps. |
| `dnmm_quote_latency_ms` | histogram | – | Latency of preview quote calls. |
| `dnmm_fee_bps` | histogram | `side`, `rung`, `regime` | Fee component per probe. |
| `dnmm_total_bps` | histogram | `side`, `rung`, `regime` | Fee + slippage per probe. |
| `dnmm_two_sided_uptime_pct` | gauge | – | Rolling 15 minute proportion of loops with both sides liquid. |
| `dnmm_recenter_commits_total` | counter | – | Total `TargetBaseXstarUpdated` events observed. |
| `dnmm_aomq_clamps_total` | counter | – | Lifetime `AomqActivated` events plus probe-level clamps. |
| `dnmm_precompile_errors_total` | counter | – | HyperCore read failures. |
| `dnmm_preview_stale_reverts_total` | counter | – | Preview calls rejected for stale snapshots. |
| `dnmm_quotes_total` | counter | `result` | Per probe result (`ok`, `fallback`, `error`). |
| `dnmm_provider_calls_total` | counter | `method`, `result` | JSON-RPC health instrumentation. |

### CSV & JSON Artifacts

- `metrics/hype-metrics/dnmm_shadow_<YYYYMMDD>.csv` – per probe row with columns
  `ts,size_wad,side,ask_fee_bps,bid_fee_bps,total_bps,clamp_flags,risk_bits,min_out_bps,mid_hc,mid_pyth,conf_bps,bbo_spread_bps,success,status_detail,latency_ms`.
- `metrics/hype-metrics/shadow_summary.json` – latest loop snapshot containing oracle readings, pool state, and probe summaries (numbers stored as decimal strings for BigInt compatibility).

CSV files rotate daily, headers are emitted once per file, and directories are created on demand.

## Synthetic Probes

The bot replays preview flows for both directions:

- `base_in` – user sells HYPE (base) for USDC. Input amount equals the rung size. Expected output uses HyperCore/Pyth mid.
- `quote_in` – user buys HYPE with USDC. Quote notionals are derived from mid price so the expected base out matches the rung size.

For each probe the bot records:

- Fee, slippage, and total bps vs mid reference.
- Clamp flags (AOMQ, Fallback) decoded from `QuoteResult.reason` or fallback usage.
- Regime bits derived from feature flags, inventory proximity to floor, and fallback/AOMQ activation.
- Latency, success/error taxonomy, and minimum output guard computed from the configured policy (10 bps calm, 20 bps fallback/AOMQ, clamped to [5,25]).

## Testing

Vitest covers core modules with deterministic fixtures:

- `poolClient.spec.ts` – getters decode the on-chain structs and regime/min-out logic behaves as expected.
- `oracleReader.spec.ts` – HyperCore precompile decoding and Pyth integration with scaling.
- `probes.spec.ts` – synthetic probes capture clamp flags, risk bits, and latency metadata.
- `metrics.spec.ts` – exported Prometheus surface avoids NaNs and respects label sets.
- `csvWriter.spec.ts` – ensures CSV rotation writes the header once and appends properly formatted rows.

Run tests with `npm run test`. The suite uses mocked providers and contracts; no live RPC is required.

## Operations Guide

- **Metrics scrape**: point Prometheus at `http://<host>:${PROM_PORT}/metrics`.
- **Alerting hints**:
  - `dnmm_snapshot_age_sec > SNAPSHOT_MAX_AGE_SEC` → refresh preview snapshots (`previewConfig()` parameters, call `refreshPreviewSnapshot`).
  - `increase(dnmm_precompile_errors_total[5m]) > 0` → inspect HyperCore precompile availability or chain congestion.
  - `dnmm_delta_bps{quantile="0.95"}` above `oracle.divergenceSoftBps` → investigate oracle divergence and potential fallback usage.
  - `dnmm_two_sided_uptime_pct < 98.5` → inventory near floor or clamps active; consider widening caps or pausing routing.
- **Graceful shutdown**: the process traps `SIGINT`/`SIGTERM`, waits for the current loop to finish, closes event subscriptions, and stops the metrics HTTP server.

## Troubleshooting

| Symptom | Mitigation |
| --- | --- |
| `dnmm_precompile_errors_total` rising | Validate `HC_PX_PRECOMPILE`, key indices, and RPC health. |
| `dnmm_preview_stale_reverts_total` rising | Snapshot older than `SNAPSHOT_MAX_AGE_SEC`; call `refreshPreviewSnapshot` or lower interval. |
| CSV missing rows | Ensure `CSV_DIR` is writable and the parent directory exists; check logs for filesystem errors. |
| No WebSocket events | Provide `WS_URL`; without it, counters fall back to probe-observed clamps only. |
| Tests fail with module resolution errors | Run `npm install` from the `shadow-bot` folder to ensure `node_modules` exists. |

## Coverage Roadmap

- Wire `GAS_PRICE_GWEI` and `NATIVE_USD` into cost-normalized metrics.
- Surface preview ladder snapshots (sigma/conf) once exposed on-chain.
- Expand address book for multiple HypeEVM environments.
