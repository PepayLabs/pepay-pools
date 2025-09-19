# Data Pipeline Overview

This document explains how raw Solana transactions flow into the processed datasets that back deliverables D2–D9.

## Stage 1 – Signature Sampling
- Command: `make sample` (wraps `scripts/tx_sampler.py` and `scripts/tx_decoder.py`).
- Output: `data/raw/tx_signatures.csv`, `data/raw/tx_samples.json`.
- Notes: Adjust `--limit` / `--decode-limit` to balance coverage and RPC load.

## Stage 2 – Instruction Extraction
- Command: `make enrich` (runs `scripts/enrich_swaps.py`).
- Output: `data/processed/lifinity_instructions.csv` with discriminator + account map per invocation.
- Next Actions: Populate `scripts/discriminators.yaml` with decoded schemas, then join into D2 Instruction Catalog.

## Stage 3 – Swap Enrichment
- Command: `make enrich` (second step) or `python scripts/swap_enricher.py`.
- Inputs: `data/processed/lifinity_instructions.csv`, optional discriminator metadata (`scripts/discriminators.yaml`).
- Output: `data/processed/tx_samples_enriched.csv` with preliminary instruction names and account counts.
- Notes: Rows remain high-level until state/amount decoding is completed; add columns incrementally as schemas are recovered.

## Stage 4 – KPI Aggregations
- Commands: `scripts/slippage_analysis.py`, `scripts/fees_tracker.py` (invoked via `make empirics`).
- Outputs: `data/processed/slippage_curve.csv`, `data/processed/fees_timeseries.csv`.
- Inputs (expected): `data/processed/tx_samples_enriched.csv`.

## Stage 5 – State & Oracle Context (Planned)
- Scripts: `scripts/state_diff.py`, `scripts/oracle_snapshot.py`.
- Purpose: Attach reserve, parameter, and oracle freshness data to each swap row for D3–D6.

## Stage 6 – Backtesting
- Command: `python scripts/backtest_simulator.py --help`.
- Notes: Requires curated price series + swap flow exports. Update once Stage 3 populated.

Keep `docs/research_plan.md` in sync as each stage is implemented. Record schema changes in `data/README.md` and update `CLAUDE.md` checklist once setup is validated.
