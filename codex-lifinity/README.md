# Codex Lifinity Portability Study

This workspace supports an end-to-end technical and empirical study of Lifinity's Solana AMM with the goal of evaluating EVM portability (BNB Smart Chain, Base). The repository is organized to capture specifications, recovered state layouts, oracle integration rules, backtesting experiments, and an EVM blueprint without modifying the upstream Solana program.

## Scope Highlights
- Document pricing curves, oracle anchoring, inventory management, delayed rebalancing, fees, POL, and authorities for `lifinity_v2_core` (`2wT8Yq49kHgDzXuPxZSaeLaH1qbmGXtEyPy64bL7aD3c`).
- Derive byte-accurate state layouts and instruction catalogs from on-chain data, SDK artifacts, and disassembly.
- Build reproducible empirical datasets (swaps, pool states, oracle snapshots) to backtest v1 vs. v2 mechanics and compare profitability under EVM constraints.
- Produce an implementation blueprint for an EVM-native deployment including contract decomposition, keeper/oracle adapters, and parameter translation guidance.

## Directory Guide
- `docs/` – Narrative deliverables (architecture map, instruction catalog, state layouts, algorithm specs, oracle rules, fee flows, security model, EVM blueprint).
- `data/` – Raw and processed datasets (transactions, pool states, oracle samples, backtest outputs). All CSV schemas tracked in `data/README.md`.
- `scripts/` – Collection, parsing, and analysis utilities for RPC queries, disassembly parsing, state diffing, backtesting, and reporting.
- `diagrams/` – Mermaid diagrams required for D10 deliverables.
- `notebooks/` – Optional exploratory analysis notebooks (Python/Jupyter or Quarto) referencing the reusable datasets.

## Deliverable Map
| ID  | Description | Target Location |
| --- | ----------- | --------------- |
| D1  | Architecture README | `docs/architecture.md` |
| D2  | Instruction Catalog | `docs/instruction_catalog.md` |
| D3  | State Layouts | `docs/state_layouts.md` |
| D4  | Algorithm Specs | `docs/algorithms_spec.md` |
| D5  | Oracle Integration | `docs/oracle_integration.md` |
| D6  | Rebalancing v1 vs v2 | `docs/rebalancing_v1_vs_v2.md` |
| D7  | Fees & POL Flow | `docs/fees_pol_flow.md` |
| D8  | Security Model | `docs/security_model.md` |
| D9  | Empirics Report | `docs/empirics.md` + CSVs under `data/processed/` |
| D10 | Mermaid Diagrams | `diagrams/*.mmd` |
| D11 | EVM Porting Report | `docs/evm_porting_report.md` |
| D12 | Artifacts Index | `docs/artifacts_index.md` |

## Workflow Overview
1. **Program Inventory** – Use `scripts/program_inventory.py` (TBD) to confirm active pools, PDAs, vaults, and oracle accounts; persist registry in `data/processed/program_inventory.json`.
2. **Binary & IDL Recovery** – Dump the BPF ELF (`lifinity_v2.so`), archive under `artifacts/` (path to be added), and parse dispatch tables using `scripts/disassembly_parser.py`.
3. **Instruction Mapping** – Sample ≥500 swap transactions via `scripts/tx_sampler.py`, extract discriminators, account metas, and classify instruction semantics.
4. **State Diffing & Layout Recovery** – Capture pre/post swap pool states with `scripts/state_diff.py`, annotate inferred fields, and reconcile with SDK types.
5. **Algorithm Derivation & Backtesting** – Fit oracle-anchored curve parameters, inventory adjustments, and threshold rebalancing using datasets in `data/processed/`; validate swaps within ≤2 bps median error.
6. **EVM Porting Analysis** – Translate findings into contract design, keeper/oracle requirements, and parameter guidance documented in `docs/evm_porting_report.md`.

### Automation Aids
- `Makefile` shortcuts: `make install`, `make inventory`, `make sample`, `make enrich`, `make empirics`.
- `scripts/pipeline.py` orchestrates multi-step pulls (`inventory`, `sample`, `empirics`) with shared configuration from `scripts/config.py`.
- `scripts/enrich_swaps.py` converts decoded transactions into a Lifinity-focused instruction ledger.
- `scripts/swap_enricher.py` blends instruction metadata with discriminator notes to form `tx_samples_enriched.csv`.
- `scripts/discriminators.yaml` tracks recovered 8-byte instruction keys once identified.

## Environment Setup
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r codex-lifinity/requirements.txt
```

Create a `.env` file (not committed) with Solana RPC endpoints if custom nodes are required:
```
SOLANA_RPC=https://api.mainnet-beta.solana.com
ALCHEMY_SOLANA_RPC=https://solana-mainnet.g.alchemy.com/v2/<key>
ANKR_SOLANA_RPC=https://rpc.ankr.com/solana
```
Scripts default to the public endpoint if variables are absent.

## Status Log (initial)
- ✅ Repository skeleton prepared.
- ⏳ Data collectors, parsers, and documentation content pending.
- ⚠️ Requires Solana RPC connectivity and Python dependencies (`solana`, `solders`, `aiohttp`, `pandas`, `numpy`, `mermaid-cli` optional).

## Next Steps
- Populate `docs/` files with recovered findings as analysis progresses.
- Implement and validate scripts under `scripts/` (see stubs for guidance).
- Schedule batch jobs to refresh empirical datasets (24h/7d/30d) and attach CSV exports.
- Update `CLAUDE.md` checklist as setup, validation, and ownership details are completed.
