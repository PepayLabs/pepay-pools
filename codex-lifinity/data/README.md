# Data Directory Guide

## Structure
- `raw/` – Direct outputs from RPC queries, account dumps, oracle snapshots, and intermediate JSON prior to cleaning.
- `processed/` – Curated CSV/Parquet files ready for analysis and reporting.

## Target Files
| Path | Description | Source Script |
| --- | --- | --- |
| raw/tx_samples.csv | Stratified swap sample covering ≥500 transactions | `scripts/tx_sampler.py` |
| raw/pool_states/*.json | Pool PDA snapshots keyed by slot | `scripts/state_diff.py` |
| raw/oracle_accounts/*.json | Oracle account data at swap slot | `scripts/oracle_snapshot.py` |
| processed/program_inventory.json | Registry of pools, vaults, oracle accounts | `scripts/program_inventory.py` |
| processed/pool_state_timeseries.csv | Derived reserves, inventory ratios, parameters | `scripts/state_diff.py` |
| processed/slippage_curve.csv | Trade size vs realized slippage | `scripts/slippage_analysis.py` |
| processed/fees_timeseries.csv | Fees per period | `scripts/fees_tracker.py` |
| processed/backtest_results.csv | v1 vs v2 profitability comparison | `scripts/backtest_simulator.py` |

Record schema and timestamp metadata inside each script to ensure reproducibility.
