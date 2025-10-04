# Configuration Guide

This guide documents every configuration surface for the shadow bot so that operators can reason about environment variables, JSON overrides, and CLI flags without hunting through source code.

## 1. `.dnmmenv` Files

Order of precedence:
1. `.dnmmenv.local` (highest precedence).
2. `.dnmmenv`.
3. OS environment variables / CI secrets (always override loader defaults).

Sample `./.dnmmenv` (non-sensitive defaults):
```
MODE=mock
INTERVAL_MS=5000
SNAPSHOT_MAX_AGE_SEC=30
PROM_PORT=9464
LOG_LEVEL=info
BASE_DECIMALS=18
QUOTE_DECIMALS=6
RPC_URL=http://127.0.0.1:8545
POOL_ADDR=0x0000...0000
HYPE_ADDR=0x0000...0000
USDC_ADDR=0x0000...0000
SETTINGS_FILE=settings/hype_settings.json
```

Replace the placeholder addresses/RPC URL with production values or fork endpoints as needed.

## 2. Single-Run Environment Variables

| Key | Default | Description |
| --- | --- | --- |
| `MODE` | `mock` | Runtime mode (`mock`, `fork`, `live`). |
| `RPC_URL` | _(required for fork/live)_ | HTTP RPC endpoint. |
| `WS_URL` | optional | WebSocket RPC endpoint (subscriptions). |
| `POOL_ADDR` | `0x…` | DNMM pool contract address. |
| `HYPE_ADDR`, `USDC_ADDR` | `0x…` | Token addresses. |
| `PYTH_ADDR` | optional | Pyth contract address (live). |
| `HC_PX_PRECOMPILE`, `HC_BBO_PRECOMPILE` | defaults | HyperCore precompile addresses. |
| `HC_PX_KEY`, `HC_BBO_KEY` | `107` | HyperCore oracle keys. |
| `INTERVAL_MS` | `5000` | Loop cadence. |
| `PROM_PORT` | `9464` | Prometheus port. |
| `CSV_DIR` | `metrics/hype-metrics` | Base directory for CSV outputs. |
| `JSON_SUMMARY_PATH` | `<CSV_DIR>/shadow_summary.json` | Summary artefact path. |
| `BASE_DECIMALS`, `QUOTE_DECIMALS` | `18`, `6` | Token decimals (used in mock mode). |
| `SAMPLING_TIMEOUT_MS` | `7500` | RPC timeout. |
| `SAMPLING_RETRY_ATTEMPTS` | `3` | Retry count on sampling failure. |
| `SAMPLING_RETRY_BACKOFF_MS` | `500` | Backoff between retries. |

Optional files:
- `address-book.json` — preset deployment metadata keyed by chain ID.
- `FORK_DEPLOY_JSON` — output from deployment scripts to auto-populate fork addresses.

## 3. Multi-Run CLI Flags

| Flag / Env | Description |
| --- | --- |
| `--settings`, `SETTINGS_FILE` | Path to the settings JSON. |
| `--run-id`, `RUN_ID` | Identifier used for output directories and metrics labels. |
| `--max-parallel`, `MAX_PARALLEL` | Concurrency limit (default `6`). |
| `--benchmarks`, `BENCHMARKS` | Comma-separated list (`dnmm,cpmm,stableswap`). |
| `--duration-sec`, `DURATION_SEC` | Optional cap per run. |
| `--seed-base`, `SEED_BASE` | Base RNG seed (default `1337`). |
| `--prom-port`, `PROM_PORT` | Port for multi-run metrics server. |
| `--persist-csv`, `PERSIST_CSV` | Set to `false` to skip CSV emission. |
| `--log-level`, `LOG_LEVEL` | `info` or `debug`. |
| `--run-root`, `METRICS_ROOT` | Override base directory for run artefacts. |

## 4. Settings JSON Schema

Each `runs[]` entry must include:
- `id` (unique single character or string identifier).
- `label` (human readable name).
- `featureFlags`, `makerParams`, `inventoryParams`, `aomqParams` (integer/boolean fields).
- `flow` object with `pattern`, `seconds`, `seed`, `txn_rate_per_min`, `size_dist`, `size_params`, and optional `toxicity` block.
- `latency` object (`quote_to_tx_ms`, `jitter_ms`).
- `router` object (`slippage_bps`, `ttl_sec`, `minOut_policy`).

Benchmarks default to `[
  "dnmm"
]

Optional arrays override at runtime. Unknown fields raise errors to prevent silent drift.

## 5. Address Book Format

`shadow-bot/address-book.json` allows centralizing deployment metadata:
```
{
  "defaultChainId": 1234,
  "deployments": {
    "hyperEVM": {
      "chainId": 1234,
      "poolAddress": "0x...",
      "baseToken": "0x...",
      "quoteToken": "0x...",
      "pyth": "0x...",
      "hcPx": "0x0000000000000000000000000000000000000807",
      "hcBbo": "0x000000000000000000000000000000000000080e",
      "hcSizeDecimals": 2
    }
  }
}
```

The config loader matches entries by `poolAddress` (case-insensitive) or `chainId` and fills missing values.

## 6. Production Checklist

1. Ensure `.dnmmenv` contains the correct HyperEVM RPC and contract addresses.
2. Confirm Prometheus port doesn’t collide with existing services.
3. Point `SETTINGS_FILE` to the experiment plan for the deployment (or remove it to run single-mode).
4. Snapshot `.dnmmenv` and settings JSON in the release artefacts so runs are reproducible.
5. Use `node dist/multi-run.js --run-id <release>` to record performance metrics during canary.

---

Last updated: 2025-10-04.
