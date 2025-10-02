# HyperEVM HYPE/USDC Fee & Slippage Research

This package orchestrates deterministic quoting runs across HyperEVM DEXs and routed aggregators for the HYPE/USDC pair. It resolves chain/token metadata, auto-discovers adapter documentation, collects quotes for multiple notional sizes in both trade directions, and emits reproducible CSV and JSONL artifacts under `metrics/hype-metrics`.

## Key Features
- Automated registry management for chains, tokens, and adapter docs with verification timestamps.
- Resilient adapter interface supporting official SDKs, HTTP quote endpoints, and on-chain quoters.
- Direct Algebra (Kittenswap) and HyperSwap adapters that hit native quoters on HyperEVM to capture venue-specific mid prices, fees, and slippage.
- First-class Hypertrade aggregator integration providing executable quotes, route splits, and fee metadata.
- Quote plans spanning $1 to $10,000 notionals with log-bucket fill-in and both trade directions.
- Deterministic CSV/JSONL emitters plus structured run logs for downstream analytics.
- Built-in retry, rate limiting, and error capture so partial failures do not halt the run.
- Vitest-based unit/integration/live test suites for math invariants and adapter behavior.

## Running
1. Populate required env vars in `.env` (see `.env.example`).
2. Install dependencies: `pnpm install` (or `npm install`) within this folder.
3. Build the TypeScript bundle: `pnpm build`.
4. Execute the evaluator: `pnpm start -- --run live` (or use `tsx evaluate_hype.ts` during development).
5. Inspect artifacts in `metrics/hype-metrics`, and append run summaries to `README.md` as needed.

> Quick iteration tip: set `FAST_QUOTE_PLAN=1` (or `FAST_MODE=1`) to reduce the quote ladder to `[1, 10, 100, 1000]` during local development. Direct DEX adapters still require `HYPE_RPC_URL` to be populated so on-chain quoters have a provider.

## Testing
- `pnpm unit` for deterministic math/config tests.
- `pnpm integration` for adapter fallback and concurrency tests.
- `pnpm live` gated via `LIVE_TESTS=1` for real network calls against allowed endpoints.

## Repo Hygiene
- Keep `dex-docs.json`, `tokens.json`, and `chains.json` in sync with authoritative sources.
- Ensure `CLAUDE.md` mirrors the root template with folder-specific metadata.
- Regenerate the auto-doc header in `evaluate_hype.ts` whenever the docs registry changes.

## Outstanding Items
- Confirm router + quoter contracts for speculative DEX listings (Project X, Hybra, Gliquid, etc.).
- Backfill trusted token verification references beyond explorer lookups.
- Capture gas estimations via `eth_estimateGas` once HyperEVM RPC access is provisioned.
- Extend adapter coverage for non-aggregator DEXes once official docs or ABIs land.

## Latest Run Snapshot — 2025-10-02
- **run_id**: `2025-10-02T16:55:02.153Z__6wlgdv`
- **successful adapters**: Hypertrade Aggregator (baseline) with per-leg enrichment for HyperSwap, Kittenswap Finance, Project X, and Ramses v3 produced straight from Hypertrade routing legs
- **pending integrations**: 1inch, 0x, Odos, ParaSwap (chain 999 unsupported on HyperEVM), Curve Finance, Hybra, Gliquid, Upheaval Finance, Drip.Trade, HyperBrick, HX Finance, Hyperliquid (Hypertrade still reroutes these legs via other venues; direct router docs or ABI discovery remains TODO)
- **artifacts**: see `metrics/hype-metrics/hype-usdc-quotes__2025-10-02__2025-10-02T16:55:02.153Z__6wlgdv.{csv,jsonl}` and `metrics/hype-metrics/run-logs.jsonl`
