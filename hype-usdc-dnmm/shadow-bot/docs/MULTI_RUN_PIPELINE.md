# Multi-Setting Benchmark Pipeline

This document dives into the end-to-end flow when you invoke the multi-setting runner (`node dist/multi-run.js`). It complements `docs/ARCHITECTURE.md` by focusing specifically on the benchmarking path.

## High-Level Steps

1. **Environment Load** – `src/env.ts` reads `.dnmmenv.local` then `.dnmmenv`, populating `process.env` without overwriting existing variables.
2. **Settings Resolution** – `src/config-multi.ts` consumes CLI flags/env vars, loads the base `ShadowBotConfig` via `loadConfig()`, then parses the JSON settings file. It produces a `MultiRunRuntimeConfig` that includes:
   - Derived output paths (`metrics/hype-metrics/run_<RUN_ID>/…`).
   - Normalized `RunSettingDefinition[]` collection.
   - Benchmark list (`BenchmarkId[]`).
   - Runtime descriptor (`ChainBackedConfig` or `MockShadowBotConfig`).
3. **Runner Execution** – `runMultiSettings()` (in `src/runner/multiSettings.ts`) spins up to `MAX_PARALLEL` workers. For each setting it:
   - Instantiates benchmark adapters (DNMM, CPMM, StableSwap) with per-mode clients (live or sim).
   - Creates a seeded flow engine for deterministic trade intent generation.
   - Enters a tick loop (default 250 ms) that fetches oracle/pool state, samples quotes, executes trades, and updates metrics/CSV/scoreboard.
   - Every 30 minutes (configurable via `CHECKPOINT_MINUTES`) the aggregator snapshot is persisted to `metrics/hype-metrics/run_<RUN_ID>/checkpoint.json`; the file also records which setting IDs completed so a multi-day run can resume after interruption.
   - When a `riskScenarioId` is attached to a run, the loader now hydrates deterministic oracle simulations (spread/sigma ranges, Pyth outages/dropouts, latency spikes) so the mock adapters mirror stress conditions without mutating the base run definition.
4. **Output Finalization** – Once all settings finish, the runner writes `scoreboard.csv`, shuts down the Prometheus server, and prints a summary JSON log (`shadowbot.multi.completed`).
   - In addition to the CSV, the runner now emits `scoreboard.json`, `scoreboard.md`, and `summary.md` (analyst narrative) alongside checkpoint cleanup.

## Adapter Responsibilities

Each adapter implements:

| Method | Description |
| --- | --- |
| `init()` | Cache state, warm up connections. |
| `prepareTick(context)` | Receive `BenchmarkTickContext` (oracle + pool snapshot) prior to quotes/trades. |
| `sampleQuote(side,size)` | Return a `BenchmarkQuoteSample` for logging + metrics. |
| `simulateTrade(intent)` | Execute trade logic, update local inventory, and return `BenchmarkTradeResult`. |
| `close()` | Release resources (close connections if any). |

The DNMM adapter reuses the live pool path (`LivePoolClient`) so behaviour stays aligned with production previews. CPMM and StableSwap emulate alternative invariants for comparison.

## CSV Schema Recap

Refer to README for the CSV column definitions. Each setting writes separate files per benchmark. A scoreboard row aggregates success metrics, PnL, win rate, uptime, reject rate, and clamp counts — this is what oncall uses to decide the next candidate configuration.

## Prometheus Labels

All multi-run metrics share `{run_id, setting_id, benchmark, pair}`. Gauges/counters/histograms are prefixed `shadow_*`. Derived KPIs from the scoreboard (`shadow_router_win_rate_pct`, `shadow_pnl_per_risk`, `shadow_lvr_capture_bps`, etc.) are materialised as gauges during the finalize step. When the runner is pointed at a live/fork network, a parallel `dnmm_*` stream mirrors on-chain telemetry (mid, spread, reserves, sigma) into the same registry so Grafana dashboards can overlay simulated vs. production values. The exporter listens on the port specified by `PROM_PORT` or `--prom-port`.

---

Last updated: 2025-10-04.
