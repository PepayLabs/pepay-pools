# Shadow Bot Architecture

This document explains how the HYPE/USDC shadow bot is organized after the TypeScript refactor and multi-setting benchmark integration.

## Source Layout

```
shadow-bot/
├─ src/
│  ├─ env.ts              # Minimal .env loader used by all CLIs
│  ├─ shadow-bot.ts       # Legacy single-run loop (unchanged behaviour)
│  ├─ multi-run.ts        # Entry point for the benchmark runner
│  ├─ config.ts           # Legacy ShadowBotConfig loader (live/fork/mock)
│  ├─ config-multi.ts     # Multi-run settings loader / CLI parsing
│  ├─ flows/              # Deterministic flow generators (arb, toxic, etc.)
│  ├─ benchmarks/         # DNMM/CPMM/StableSwap adapters
│  ├─ runner/             # Orchestrator + scoreboard utilities
│  ├─ metrics/            # Prometheus exporters (single + multi)
│  ├─ csv/                # Writers for single-run rows & multi-run CSVs
│  └─ sim/                # Lightweight pool/oracle simulators for mock mode
├─ dist/                  # Compiled JavaScript (`npm run build`)
├─ metrics/               # CSV/scoreboard output (created at runtime)
├─ settings/              # Example multi-run specifications
└─ docs/                  # Architecture, runbooks, reference material
```

The baseline `runShadowBot(config)` still drives the exact same HyperCore/Pyth sampling, probe ladder, CSV writer, and Prometheus metrics as before. Multi-run functionality composes those primitives without altering live behaviour.

## Execution Paths

### Single Run
1. `node dist/shadow-bot.js`
2. `src/env.ts` loads `.env.local` then `.env` (if present) and populates `process.env`.
3. `src/config.ts` produces a `ShadowBotConfig` (mock/fork/live).
4. `runShadowBot()` spins the probe loop, writes `metrics/hype-metrics/shadow_summary.json`, and emits `dnmm_*` Prometheus series.

### Multi-Setting Runner
1. `node dist/multi-run.js --settings settings/hype_settings.json`
2. `src/config-multi.ts` reads the legacy config, merges JSON settings (5–7 runs), and resolves benchmark list + output paths.
3. `src/runner/multiSettings.ts` launches up to `MAX_PARALLEL` workers:
   - Each worker creates adapters (DNMM via live pool client, CPMM invariant, StableSwap A-curve).
   - Flow engines generate deterministic trade intents per tick.
   - Quotes/trades are recorded via `src/csv/multiWriter.ts` and `src/metrics/multi.ts`.
4. Outputs:
   - `metrics/hype-metrics/run_<RUN_ID>/quotes/*.csv`
   - `metrics/hype-metrics/run_<RUN_ID>/trades/*.csv`
   - `metrics/hype-metrics/run_<RUN_ID>/scoreboard.csv`
   - Prometheus endpoint labelled `{run_id, setting_id, benchmark, pair}` with `shadow.*` metrics.

## Settings Schema
See `settings/hype_settings.json` for an example. Each `runs[]` entry encodes feature flags, maker/inventory knobs, AOMQ params, flow pattern, latency, and router strategy. The loader enforces unique IDs and validates numeric fields before execution.

## Prometheus Metrics
- Single-run metrics retain the `dnmm_*` namespace documented in `docs/OBSERVABILITY.md`.
- Multi-run adds `shadow_*` gauges/counters/histograms for benchmark telemetry. Refer to the updated glossary for label definitions.

## Extending the Bot
- Add new benchmarks by implementing `BenchmarkAdapter` in `src/benchmarks/` and wiring it into `runner/multiSettings.ts`.
- Add new flow patterns by registering generators in `src/flows/patterns.ts` and updating the settings schema validator.
- To integrate additional telemetry, extend `src/metrics/multi.ts` and update the documentation tables.

## Testing Strategy
- Unit tests live under `src/__tests__/` (Vitest). They should be run with Node 20 while npm supplies complete tarballs.
- Golden CSV fixtures should be maintained for representative multi-run outputs.
- CI should build the TypeScript project, execute mock-mode multi-run (short duration), and archive the scoreboard for regression tracking.

## Environment Loading
### File Precedence
1. `.env.local`
2. `.env`

Later files supplement (not override) existing values unless `override=true` is explicitly provided.

### Supported Syntax
- `KEY=value`
- Quoted strings (`KEY="value"`, escapes `\n`, `\r`).
- Commented lines starting with `#` are ignored.

This custom loader removes the dependency on the `dotenv` package, avoiding registry caching issues while preserving previous behaviour.

---
_Last updated: 2025-10-04_
