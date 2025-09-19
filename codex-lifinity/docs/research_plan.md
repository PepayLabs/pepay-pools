# Research Plan & Milestones

This plan tracks progress across the A–Z portability study. Update statuses and owners routinely to keep stakeholders aligned.

## Phase Overview

| Phase | Focus | Primary Outputs | Owner | Status |
| --- | --- | --- | --- | --- |
| PH1 | Program inventory & pool registry | `data/processed/program_inventory.json`, pool catalog table (D1) | TBD | Not started |
| PH2 | Binary & IDL recovery | `artifacts/lifinity_v2.so`, `artifacts/lifinity_v2.disasm`, decoder notes (D12) | TBD | Not started |
| PH3 | Instruction mapping | `docs/instruction_catalog.md`, discriminator registry (`scripts/discriminators.yaml`) | TBD | Not started |
| PH4 | State diffing | `docs/state_layouts.md`, `data/raw/pool_states/` snapshots | TBD | Not started |
| PH5 | Algorithm derivation | `docs/algorithms_spec.md`, regression notebooks | TBD | Not started |
| PH6 | Rebalance recovery | `docs/rebalancing_v1_vs_v2.md`, `diagrams/rebalance_sequence_v1_v2.mmd` | TBD | Not started |
| PH7 | Oracle rules | `docs/oracle_integration.md`, `data/processed/oracle_usage.csv` | TBD | Not started |
| PH8 | Fees & POL | `docs/fees_pol_flow.md`, `data/processed/fees_timeseries.csv` | TBD | Not started |
| PH9 | Backtesting & validation | `scripts/backtest_simulator.py`, `data/processed/backtest_results.csv` | TBD | Not started |
| PH10 | EVM portability | `docs/evm_porting_report.md`, parameter translation tables | TBD | Not started |
| PH11 | Documentation polish | D1–D12 finalized, Mermaid diagrams rendered | TBD | Not started |

## Weekly Cadence

- **Day 1–2:** Data refresh (inventory, transaction sampling), update raw dumps.
- **Day 3:** Decode new instructions/state diffs, annotate docs.
- **Day 4:** Run empirics (slippage, fees, inventory metrics) and backtests.
- **Day 5:** Synthesize findings into D11 EVM report; circulate progress summary.

## Decision Log

| Date | Decision | Context | Impact |
| --- | --- | --- | --- |
| _TBD_ | Populate after first technical decision |  |  |

## Risks & Mitigations

- **RPC Rate Limits:** Maintain multiple endpoints (`config.RPC_ENDPOINTS`); cache responses to disk.
- **Oracle Coverage Gaps:** Flag missing oracle snapshots in `docs/oracle_integration.md`; consider alternate data providers.
- **Backtest Accuracy:** Track simulator error vs on-chain amounts; document parameter assumptions per pool.
- **Time Constraints:** Use `Makefile` tasks to automate routine data pulls and processing.

## Action Items Queue

- [ ] Assign owners for each methodology phase.
- [ ] Populate `scripts/discriminators.yaml` once initial instruction parsing completes.
- [ ] Stand up storage (S3 or equivalent) for large artifacts if repo limits exceeded.
- [ ] Schedule keeper simulation environment (e.g., Hardhat/Foundry) aligned with EVM blueprint.

Keep this plan in sync with `CLAUDE.md` checklist items.
