# D12 – Artifacts Inventory

Maintain an auditable catalog of supporting data and binaries.

## Expected Entries
- Program ELF dump (`artifacts/lifinity_v2.so`)
- Disassembly outputs (`artifacts/lifinity_v2.disasm`)
- IDLs (if reconstructed)
- Pool state snapshots (`data/raw/pool_states/`)
- Oracle account snapshots (`data/raw/oracle_accounts/`)
- Transaction logs / parsed JSON (`data/raw/transactions/`)
- Backtest scripts and outputs (`scripts/`, `data/processed/backtests/`)

## Template
| Artifact | Path | Source | Notes |
| --- | --- | --- | --- |

Update the table as files are added. Include acquisition timestamp and verification status when possible.
