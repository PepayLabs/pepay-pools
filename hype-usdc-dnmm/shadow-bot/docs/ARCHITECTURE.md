# Shadow Bot Architecture

This reference explains how the HYPE/USDC shadow bot is organized after the TypeScript refactor and the multi-setting benchmark integration. It is intended to help new contributors orient themselves quickly and to keep the codebase and documentation in sync.

---

## 1. File Structure

```
shadow-bot/
├─ docs/                    # Developer-facing references (this file)
├─ settings/                # Example multi-run specifications (JSON)
├─ src/                     # All TypeScript source code
│  ├─ env.ts                # Lightweight .dnmmenv loader (replaces dotenv)
│  ├─ shadow-bot.ts         # Legacy single-run entrypoint (runShadowBot)
│  ├─ multi-run.ts          # Benchmark runner CLI entrypoint
│  ├─ config.ts             # ShadowBotConfig loader for mock/fork/live
│  ├─ config-multi.ts       # Multi-run settings loader/CLI parsing
│  │
│  ├─ benchmarks/           # DNMM, CPMM, StableSwap adapters
│  ├─ csv/                  # CSV writers (single + multi)
│  ├─ flows/                # Deterministic flow generators (arb/toxic/etc.)
│  ├─ metrics/              # Prometheus exporters (single + multi)
│  ├─ mock/                 # Scenario engine, mock pool/oracle/clock
│  ├─ runner/               # Multi-setting orchestration + scoreboard
│  ├─ sim/                  # Lightweight pool/oracle simulators for mock mode
│  ├─ __tests__/            # (To be migrated) historical Vitest suites
│  └─ ...                   # Support scripts (analysis.ts, monitor.ts, etc.)
│
├─ dist/                    # Compiled JavaScript (`npm run build`)
├─ metrics/                 # Runtime artefacts (quotes/trades/scoreboard)
├─ package.json             # Scripts and pinned toolchain (build/test)
└─ .dnmmenv                 # Sample environment variables (non-sensitive)
```

---

## 2. Core Modules

| Path | Purpose |
| --- | --- |
| `src/shadow-bot.ts` | Implements `runShadowBot(config)` — the original loop that samples HyperCore/Pyth, runs probe ladders, writes single-run CSVs, and emits `dnmm_*` metrics. `main()` simply calls this export. |
| `src/config.ts` | Produces a `ShadowBotConfig` by reading `.dnmmenv` (via `loadEnv`), optional address-book JSON, and fork deploy overrides. Supports `mock`, `fork`, and `live` modes. |
| `src/env.ts` | Minimal `.dnmmenv` loader. Applies `.dnmmenv.local` first, then `.dnmmenv`. Values never override explicit environment variables. |
| `src/multi-run.ts` | CLI entrypoint for the benchmark runner. Loads the multi-run config and hands it to `runMultiSettings`. |
| `src/config-multi.ts` | Parses CLI flags / env vars, loads the base ShadowBot config, reads the settings JSON, validates the schema, and resolves output paths + benchmark list. |
| `src/runner/multiSettings.ts` | Orchestrates concurrent runs (using `FlowEngine`), drives benchmark adapters, writes per-setting CSVs, records metrics, and aggregates scoreboard rows. |
| `src/runner/scoreboard.ts` | Aggregates per-trade statistics into the scoreboard (PnL, win rate, uptime, reject rate, clamp counts, etc.). |
| `src/csv/multiWriter.ts` | Handles `quotes/*.csv`, `trades/*.csv`, and `scoreboard.csv` emission for multi-run sessions. |
| `src/metrics/multi.ts` | Prometheus exporter for multi-run metrics. Metrics are prefixed `shadow.*` and labelled `{run_id, setting_id, benchmark, pair}`. |

---

## 3. Flow Patterns

`src/flows/patterns.ts` defines deterministic trade-intent generators. Each pattern is seeded for repeatability:

| Pattern | Behaviour |
| --- | --- |
| `arb_constant` | Constant attempts to exploit oracle vs. pool skew. |
| `toxic` | Toxic/adverse flow — front-runs the oracle move, stressing AOMQ and fallback logic. |
| `trend` | Positive drift with side bias to simulate momentum takers. |
| `mean_revert` | Shock + pullback to stress inventory tilt and floor logic. |
| `benign_poisson` | IID Poisson arrivals with small order sizes for baseline monitoring. |
| `mixed` | Random walk across the other regimes via a simple state machine. |

The flow engine yields `TradeIntent` objects every tick (default 250 ms) and is used by each benchmark worker.

---

## 4. Benchmark Adapters

| Adapter | File | Notes |
| --- | --- | --- |
| DNMM | `src/benchmarks/dnmm.ts` | Wraps the real pool client (`LivePoolClient` or simulated equivalent). Reuses live math, tracks inventory, and records mid/spread from HyperCore. |
| CPMM | `src/benchmarks/cpmm.ts` | Constant-product emulator with fee schedule and simple inventory accounting. |
| StableSwap | `src/benchmarks/stableswap.ts` | Curve-style invariant with amplification parameter `A`. |

Each adapter implements `init()`, `prepareTick()`, `sampleQuote()`, `simulateTrade()`, and `close()`, so adding a new comparator only requires implementing this interface.

---

## 5. Outputs & Metrics

### Single-run
- CSV rows produced by `src/csvWriter.ts` (unchanged from the original bot).
- Prometheus metrics retain the `dnmm_*` namespace (documented in `docs/OBSERVABILITY.md`).

### Multi-run
- `metrics/hype-metrics/run_<RUN_ID>/quotes/<SETTING>_<BENCHMARK>.csv`
- `metrics/hype-metrics/run_<RUN_ID>/trades/<SETTING>_<BENCHMARK>.csv`
- `metrics/hype-metrics/run_<RUN_ID>/scoreboard.csv`
- Prometheus endpoint on `http://0.0.0.0:${PROM_PORT}/metrics` exposing `shadow_*` gauges/counters/histograms.

A full metric glossary is maintained in `docs/METRICS_GLOSSARY.md` and now includes the `shadow.*` series.

---

## 6. Configuration & Environments

- `.dnmmenv` is shipped with safe defaults (mock mode, local RPC). Edit this file in-place to point at HyperEVM mainnet, forks, or bespoke settings. Because the loader never overrides existing variables, you can still set secrets via shell environment variables or CI runners.
- Example multi-run specification: `settings/hype_settings.json`. Additional files can be dropped into `settings/` and referenced via `--settings` or `SETTINGS_FILE`.
- CLI flags mirror the environment variables documented in the README (e.g. `--run-id`, `--max-parallel`, `--benchmarks`).

---

## 7. Command Reference

| Command | Description |
| --- | --- |
| `npm run build` | Compile TypeScript into `dist/`. Must be run before using the Node CLI entrypoints. |
| `node dist/shadow-bot.js` | Run the legacy single-setting bot (mock/fork/live). |
| `node dist/multi-run.js --settings …` | Launch multi-setting benchmarks (DNMM/CPMM/StableSwap). |
| `npm run clean` | Remove build artefacts and metric output directories. |
| `npm run monitor` | Legacy metrics monitor (ts-node) for quick diagnostics. |

---

## 8. Testing & QA

To avoid the sandbox issues encountered with Vitest, the repository now uses Node’s built-in test runner:

```bash
npm run build
node --test test
```

Place new test files in `test/` (e.g. `test/multi-run-smoke.test.mjs`). Existing suites under `src/__tests__/` were left for reference and should be ported to the new harness as time allows. A typical smoke test should:

1. Run the multi-setting CLI in mock mode for a short duration (≤5 s).
2. Assert that expected CSV files and scoreboard rows are produced.
3. Optionally scrape the Prometheus endpoint to verify new metrics.

---

## 9. Extending the Stack

1. **New flow pattern** → add generator to `src/flows/patterns.ts` and document the option in both the README and settings schema.
2. **New benchmark** → implement `BenchmarkAdapter`, register it in `runner/multiSettings.ts`, and update the settings schema + docs.
3. **Telemetry** → extend `src/metrics/multi.ts` or `src/metrics.ts`, add the documentation row in `docs/METRICS_GLOSSARY.md`, and provide Grafana examples under `docs/OBSERVABILITY.md`.
4. **Configuration knobs** → update `src/config.ts` and `src/config-multi.ts`, add defaults to `.dnmmenv`, and document them in the README’s configuration section.

---

_Last edited: 2025-10-04_
