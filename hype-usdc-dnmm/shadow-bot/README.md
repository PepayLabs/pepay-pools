# DNMM Shadow Bot – HYPE/USDC Observer

Enterprise telemetry harness for the HYPE/USDC Dynamic Nonlinear Market Maker (DNMM). The bot mirrors the on-chain preview pipeline, streams oracle/pool state, and publishes an identical Prometheus + CSV surface for dashboards regardless of mode.

## Modes at a Glance

| `MODE` | Purpose | Backing | Notes |
| --- | --- | --- | --- |
| `live` | Monitor production DNMM deployment | Real RPC / WebSocket providers | Requires full address config or address-book entry. |
| `fork` | Exercise a local anvil/Foundry fork | RPC to fork node + mocks | Run `forge script script/DeployMocks.s.sol --rpc-url http://127.0.0.1:8545` to seed mock contracts and addresses. |
| `mock` *(default)* | Pure TypeScript simulation for dashboards & drills | Scenario engine + deterministic clock | No chain required. Scenario regime toggles expose edge cases safely. |

Set `MODE` via environment variables (`MODE=mock` when omitted). All modes share identical CSV schema, JSON summary, and Prometheus labels (now `{pair, chain, mode, …}`).

## Quick Start

```bash
npm install

# Mock mode (default) – CALM scenario
npm run start

# Fork mode – assumes DeployMocks.s.sol already ran
MODE=fork RPC_URL=http://127.0.0.1:8545 npm run start

# Live mode – supply production addresses + RPC
MODE=live RPC_URL=https://mainnet.rpc ... npm run start

# Run the test suite
npm run test
```

To deploy fork mocks:

```bash
# in ./hype-usdc-dnmm
anvil --chain-id 31337 --fork-url $MAINNET_RPC &
forge script script/DeployMocks.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

The script prints JSON with pool/token/oracle addresses and writes `metrics/hype-metrics/output/deploy-mocks.json`. `loadConfig()` consumes that file when `MODE=fork`.

## Multi-setting Benchmark Runner

The benchmark harness replays deterministic order-flow patterns against DNMM and baseline AMMs (CPMM, StableSwap) without mutating chain state. It reuses the live HyperCore/Pyth samplers, quote path, and CSV/Prom stack to keep parity with production telemetry.

```bash
npm run build

# Execute five settings concurrently using the bundled specification
node dist/multi-run.js \
  --settings settings/hype_settings.json \
  --run-id $(date -u +%Y%m%dT%H%M%SZ) \
  --max-parallel 6 \
  --benchmarks dnmm,cpmm,stableswap

# Override duration and Prometheus port
MODE=fork RPC_URL=http://127.0.0.1:8545 \
  node dist/multi-run.js --settings path/to/custom.json --duration-sec 900 --prom-port 9465
```

Outputs are written under `metrics/hype-metrics/run_<RUN_ID>/`:

| Artifact | Path | Description |
| --- | --- | --- |
| `trades/<SETTING>_<BENCHMARK>.csv` | Per-intent execution outcomes (pricing, fees, inventory deltas). |
| `quotes/<SETTING>_<BENCHMARK>.csv` | Quote ladder snapshots for `base_in`/`quote_in` probes. |
| `scoreboard.csv` | Aggregate KPIs per setting & benchmark (PnL, uptime, win-rate, clamps). |

Prometheus metrics for multi-run sessions are exposed on `http://0.0.0.0:${PROM_PORT}/metrics` with label set `{run_id, setting_id, benchmark, pair}` and metric names prefixed `shadow.*` (see [Observability](../docs/OBSERVABILITY.md)).

The multi-run loader reads the same environment variables as the single-run bot (e.g. `MODE`, `RPC_URL`) and augments them with runner-specific options:

| Flag / Env | Default | Description |
| --- | --- | --- |
| `--settings`, `SETTINGS_FILE` | `settings/hype_settings.json` | Multi-run specification (see [Settings Schema](#settings-schema)). |
| `--run-id`, `RUN_ID` | ISO8601 timestamp | Used for output folder & Prom labels. |
| `--max-parallel`, `MAX_PARALLEL` | `6` | Concurrent settings processed. |
| `--benchmarks`, `BENCHMARKS` | `dnmm` | Comma list of enabled benchmarks. |
| `--seed-base`, `SEED_BASE` | `1337` | Base seed for deterministic RNG seeding. |
| `--duration-sec`, `DURATION_SEC` | per-setting | Optional cap on run length. |
| `--prom-port`, `PROM_PORT` | Single-run `PROM_PORT` | HTTP port for multi-run Prometheus exporter. |
| `--persist-csv`, `PERSIST_CSV` | `true` | Disable to skip CSV emission (metrics only). |

### Settings Schema

```
{
  "version": "1",
  "pair": "HYPE/USDC",
  "runs": [
    {
      "id": "A",
      "label": "baseline_calm",
      "featureFlags": { "enableSoftDivergence": true, ... },
      "makerParams": { "betaFloorBps": 15, "alphaBboBps": 2500, "S0Notional": 10000 },
      "inventoryParams": { "invTiltBpsPer1pct": 100, ... },
      "aomqParams": { "minQuoteNotional": 200, ... },
      "flow": {
        "pattern": "benign_poisson",
        "seconds": 600,
        "seed": 42,
        "txn_rate_per_min": 20,
        "size_dist": "lognormal",
        "size_params": { "mu": 0, "sigma": 0.9, "min": 50, "max": 2500 }
      },
      "latency": { "quote_to_tx_ms": 250, "jitter_ms": 50 },
      "router": { "slippage_bps": 30, "ttl_sec": 20, "minOut_policy": "preview" }
    }
  ],
  "benchmarks": ["dnmm", "cpmm", "stableswap"]
}
```

Benchmarks share the DNMM `PoolClientAdapter` interface and consume HyperCore/Pyth snapshots every tick. 
- `dnmm` – wraps the live/fork pool (read-only). 
- `cpmm` – constant-product emulator with identical decimals & fee schedule. 
- `stableswap` – amplification-based comparator mirroring Curve-style invariant.

## Configuration

### Common variables

| Variable | Default | Description |
| --- | --- | --- |
| `MODE` | `mock` | Operation mode (`live`, `fork`, `mock`). |
| `INTERVAL_MS` | `5000` | Loop cadence. |
| `SIZES_WAD` | `0.1,0.5,1,2,5,10` | Comma list of base sizes in WAD for probes. |
| `CSV_DIR` | `../metrics/hype-metrics` | CSV output directory. |
| `JSON_SUMMARY_PATH` | `../metrics/hype-metrics/shadow_summary.json` | Summary JSON path. |
| `PROM_PORT` | `9464` | Prometheus HTTP port. |
| `LOG_LEVEL` | `info` | `info` or `debug`. |
| `MIN_OUT_CALM_BPS` / `MIN_OUT_FALLBACK_BPS` | `10` / `20` | Guaranteed min-out policy (clamped by `MIN_OUT_CLAMP_MIN/MAX`). |
| `BASE_DECIMALS` / `QUOTE_DECIMALS` | `18` / `6` | Token decimals (mock mode requires these; live/fork can infer). |
| `ADDRESS_BOOK_JSON` | `shadow-bot/address-book.json` | Optional address presets per chain. |

### Live & Fork specific

| Variable | Default | Description |
| --- | --- | --- |
| `RPC_URL` | – | HTTPS RPC endpoint (required). |
| `WS_URL` | – | WebSocket endpoint for on-chain events (optional). |
| `POOL_ADDR` | – | DNMM pool address (can be supplied by deploy JSON in fork mode). |
| `HYPE_ADDR` / `USDC_ADDR` | – | Token addresses. |
| `PYTH_ADDR` | – | Pyth adapter contract. |
| `PYTH_PRICE_ID` | – | Pyth feed id for HYPE/USDC. |
| `HC_PX_PRECOMPILE` | `0x000…0807` | HyperCore price precompile (or mock oracle when forking). |
| `HC_BBO_PRECOMPILE` | `0x000…080e` | HyperCore BBO precompile. |
| `HC_PX_KEY` | `107` | HyperCore market key. |
| `HC_BBO_KEY` | `HC_PX_KEY` | HyperCore BBO key. |
| `HC_MARKET_TYPE` | `spot` | `spot` or `perp`; controls scaling. |
| `HC_SIZE_DECIMALS` | `2` | HyperCore size decimals. |
| `CHAIN_ID` | address-book/default | Optional explicit chain id. |
| `FORK_DEPLOY_JSON` | `metrics/hype-metrics/output/deploy-mocks.json` | Overrides addresses when `MODE=fork`. |

### Mock-only knobs

| Variable | Default | Description |
| --- | --- | --- |
| `SCENARIO` | `calm` | Built-in scenario (`calm`, `delta_soft`, `delta_hard`, `stale_pyth`, `near_floor`, `aomq_on`, `rebalance_jump`, `custom`). Case-insensitive. |
| `SCENARIO_FILE` | – | JSON file with custom timeline / random-walk overrides (see `metrics/hype-metrics/input/scenario.json` schema). |

## Scenario Engine

Mock mode feeds probes with deterministic regimes:

- **CALM** – HC≈Pyth, tight spreads, low confidence.
- **DELTA_SOFT** – divergence in soft band introduces haircuts.
- **DELTA_HARD** – delta breaches hard band triggering AOMQ.
- **STALE_PYTH** – Pyth marked stale to exercise fallback logic.
- **NEAR_FLOOR** – inventory close to floor produces partial fills.
- **AOMQ_ON** – assert emergency spread + clamp bits.
- **REBALANCE_JUMP** – mid jump to verify auto-recenter instrumentation.

Use `SCENARIO_FILE` to blend timelines (`timeline[{t_sec,...}]`) or enable `random_walk` parameters for stress drills.

## Loop Outputs

### Prometheus metrics

Exposed at `http://0.0.0.0:${PROM_PORT}/metrics` with common labels `{pair, chain, mode}`. Key series:

| Metric | Type | Extra labels | Notes |
| --- | --- | --- | --- |
| `dnmm_snapshot_age_sec` | gauge | – | Preview snapshot age. |
| `dnmm_regime_bits` | gauge | – | Bitmask (1=AOMQ, 2=Fallback, 4=NearFloor, 8=SizeFee, 16=InvTilt). |
| `dnmm_pool_base_reserves`, `dnmm_pool_quote_reserves` | gauge | – | Raw reserves. |
| `dnmm_last_mid_wad`, `dnmm_last_rebalance_price_wad` | gauge | – | Last mid + event-driven rebalance price. |
| `dnmm_delta_bps`, `dnmm_conf_bps`, `dnmm_bbo_spread_bps` | histogram | – | Oracle deltas, confidence, spreads. |
| `dnmm_quote_latency_ms` | histogram | – | Quote latency. |
| `dnmm_fee_bps`, `dnmm_total_bps` | histogram | `side,rung,regime` | Fee and total cost per probe rung. |
| `dnmm_quotes_total` | counter | `result` | Probe outcomes (`ok`, `fallback`, `error`). |
| `dnmm_provider_calls_total` | counter | `method,result` | JSON-RPC health instrumentation. |
| `dnmm_precompile_errors_total`, `dnmm_preview_stale_reverts_total`, `dnmm_aomq_clamps_total`, `dnmm_recenter_commits_total` | counter | – | Error/alert counters. |
| `dnmm_two_sided_uptime_pct` | gauge | – | Rolling 15m two-sided liquidity success rate. |

### CSV & JSON artifacts

- `metrics/hype-metrics/dnmm_shadow_<YYYYMMDD>.csv` — per-probe rows with header `ts,size_wad,side,ask_fee_bps,bid_fee_bps,total_bps,clamp_flags,risk_bits,min_out_bps,mid_hc,mid_pyth,conf_bps,bbo_spread_bps,success,status_detail,latency_ms`.
- `metrics/hype-metrics/shadow_summary.json` — latest loop snapshot (BigInt fields emitted as decimal strings).

CSV rotation writes headers once per day and logs (without throwing) on filesystem errors.

## Probe Pipeline Recap

Each loop executes synthetic probes for every size rung and side:

1. Select a mid reference (HC → Pyth → pool fallback).
2. Call `quoteSwapExactIn` (live/fork) or mock preview (mock mode).
3. Decode fee/slippage, clamp flags, and regime bits.
4. Record metrics, append CSV rows, and update JSON summary.

Guaranteed min-out policy applies 10 bps in calm conditions, 20 bps when fallback/AOMQ bits are set, clamped to `[5,25]`.

## Testing

Vitest targets the modular architecture:

- `config.spec.ts` — default configuration behaviour and mode parsing.
- `fork.spec.ts` — verifies fork-mode JSON overrides for pool/token/oracle addresses.
- `mockOracle.spec.ts` — scenario-driven oracle snapshots.
- `mockPool.spec.ts` — mock pool previews, regime bits, and min-out policy.
- `probes.spec.ts` — synthetic probes across CALM/AOMQ regimes.
- `metrics.spec.ts` — Prometheus registry enforces `{mode}` label.
- `csvWriter.spec.ts` — daily rotation guards header duplication and tolerates filesystem hiccups.

Run `npm run test`; all suites use mocks and require no chain connectivity.

## Operations Checklist

- **Live alerts**
  - `dnmm_snapshot_age_sec` > `SNAPSHOT_MAX_AGE_SEC` → trigger pool snapshot refresh workflow.
  - `increase(dnmm_aomq_clamps_total[5m]) > 0` or `dnmm_regime_bits & 1 == 1` → check fallback policy and HyperCore divergence.
  - `dnmm_two_sided_uptime_pct` < target → inspect inventory floor proximity (`NearFloor` bit) and size-fee clamps.
- **Fork diagnostics** – run DeployMocks, export metrics, and validate dashboards before shipping config changes.
- **Mock drills** – iterate `SCENARIO` values or supply JSON timelines to reproduce incidents without RPC dependencies.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| `Missing required env` on start | Ensure `MODE`-specific variables are present (see tables above). |
| `dnmm_precompile_errors_total` ticking up | Confirm HyperCore contract addresses/keys, RPC health, and fork mocks. |
| CSV directory empty | Check `CSV_DIR` permissions; errors are logged as `csv.append.failed`. |
| Prometheus scrape empty | Verify the process is listening on `PROM_PORT` and not firewalled. |

## Further Work

- Surface size ladder previews in mock mode for large rung coverage.
- Extend scenario engine with scripted AOMQ off ramp and EMA fallback sequencing.
- Add CLI to snapshot/export historical probe distributions for offline analysis.
