# DNMM Shadow Bot – HYPE/USDC Observer

Enterprise telemetry harness for the HYPE/USDC Dynamic Nonlinear Market Maker (DNMM). The bot mirrors the on-chain preview pipeline, streams oracle/pool state, and publishes an identical Prometheus + CSV surface for dashboards regardless of mode.

- [Architecture Overview](docs/ARCHITECTURE.md)
- [Runtime Modes](docs/RUNTIME_MODES.md)
- [Multi-Setting Pipeline](docs/MULTI_RUN_PIPELINE.md)
- [Configuration Guide](docs/CONFIG_GUIDE.md)
- [Known Issues](docs/KNOWN_ISSUES.md)

## Table of Contents
1. [Installation](#installation)
2. [Building](#building)
3. [Running the Single-Setting Bot](#running-the-single-setting-bot)
4. [Running Multi-Setting Benchmarks](#running-multi-setting-benchmarks)
5. [Outputs](#outputs)
6. [Configuration](#configuration)
7. [Troubleshooting](#troubleshooting)

## Installation

```bash
npm install
```

The project pins TypeScript (`5.6.3`) and relies only on the dependencies declared in `package.json`. All env var loading is handled by `src/env.ts` using `.dnmmenv` files (see [Configuration](#configuration)).

## Building

```bash
npm run build
```

This compiles `src/` to `dist/`. All CLI entrypoints (`shadow-bot.js`, `multi-run.js`, etc.) load from `dist/`.

## Running the Single-Setting Bot

```bash
node dist/shadow-bot.js
```

The bot automatically selects the mode based on `MODE` (`mock`, `fork`, `live`). See [Runtime Modes](docs/RUNTIME_MODES.md) for details.

## Running Multi-Setting Benchmarks

The multi-setting runner reuses the same primitives to replay deterministic flows across DNMM, CPMM, and StableSwap comparators.

```bash
node dist/multi-run.js \
  --settings settings/hype_settings.json \
  --run-id $(date -u +%Y%m%dT%H%M%SZ) \
  --max-parallel 6 \
  --benchmarks dnmm,cpmm,stableswap
```

Outputs are written under `metrics/hype-metrics/run_<RUN_ID>/`:

| Artifact | Path | Description |
| --- | --- | --- |
| Quotes CSV | `quotes/<SETTING>_<BENCHMARK>.csv` | Quote samples collected each tick. |
| Trades CSV | `trades/<SETTING>_<BENCHMARK>.csv` | Trade execution results per intent. |
| Scoreboard | `scoreboard.csv` | Aggregated KPIs for each setting/benchmark. |

Prometheus metrics are served on `http://0.0.0.0:${PROM_PORT}/metrics` with labels `{run_id, setting_id, benchmark, pair}` and names prefixed `shadow.*`.

See [Multi-Setting Pipeline](docs/MULTI_RUN_PIPELINE.md) for a full walk-through.

## Outputs
- CSV schema is documented inline in the settings file and in [Architecture Overview](docs/ARCHITECTURE.md).
- Prometheus metrics are catalogued in `docs/OBSERVABILITY.md` and `docs/METRICS_GLOSSARY.md` (multi-run entries included).

## Configuration

Environment variables are loaded via `.dnmmenv.local` (highest precedence) followed by `.dnmmenv`. Non-sensitive defaults are provided in the repository; update them with the correct HyperEVM RPC and addresses before going live. Reference the [Configuration Guide](docs/CONFIG_GUIDE.md) for the complete variable list and JSON schema.

Key settings for single-run operation:

| Variable | Default | Description |
| --- | --- | --- |
| `MODE` | `mock` | Runtime mode. |
| `RPC_URL` | _(required for fork/live)_ | HyperEVM RPC endpoint. |
| `POOL_ADDR` | `0x…` | DNMM pool address. |
| `PROM_PORT` | `9464` | Prometheus port. |
| `INTERVAL_MS` | `5000` | Loop cadence. |

Multi-run specific overrides are described in the CLI table under [Configuration Guide](docs/CONFIG_GUIDE.md).

## Troubleshooting

| Symptom | Likely Cause | Resolution |
| --- | --- | --- |
| `node dist/multi-run.js` exits immediately | `.dnmmenv` missing required fields | Provide RPC URL/addresses in `.dnmmenv`. |
| Missing Prometheus metrics | Check port conflicts and confirm `PROM_PORT` is exposed | Update `.dnmmenv` or CLI flag. |
| CSV files empty | Flow `seconds` may be too small or `txn_rate_per_min` low | Adjust settings JSON and rerun. |

For deeper debugging, enable verbose logging (`LOG_LEVEL=debug`) or run a mock scenario with `npm run start:dev`.

---
