# HYPE/USDC DNMM (HyperEVM)

End-to-end research and engineering drop for a Lifinity v2–style dynamic no-manual-market-maker (DNMM) tailored to the HYPE/USDC spot market on HyperEVM. The design anchors on Hyperliquid HyperCore order-book data with a Pyth fallback/divergence oracle, provides on-chain quoting + swap execution, optional RFQ settlement, and exposes the governance/observability hooks required for mainnet-readiness.

## What lives here

- Production-focused Solidity contracts (`contracts/`) with modular oracle adapters and dedicated math/inventory libraries
- Configurable DNMM fee, inventory, and risk controls with guarded updates (`FeePolicy`, `Inventory`, `FixedPointMath`)
- Deployment and operations scaffolding (scripts, checklists, telemetry hooks)
- Research docs summarising math, oracle wiring, config provenance, and runbooks (`docs/`)
- Foundry-based test harness (`test/`) covering fee dynamics, partial fills, divergence gates, fuzzing, and RFQ verification flows
- Canonical parameter packs under `config/` derived from Lifinity SOL/USDC settings

## Quick Start

1. Run `./setup.sh` from the repo root to provision Node.js 20 and Foundry.
2. From this folder run `terragon-forge.sh install` commands as needed (wrapper passes `--root hype-usdc-dnmm`).
3. Configure HyperCore + Pyth identifiers under `config/oracle.ids.json` and token metadata under `config/tokens.hyper.json`.
4. Execute `terragon-forge.sh test` for the default suite or `terragon-forge.sh test --match-test testFeeDecay` to focus on a component.
5. Review `RUNBOOK.md`, `SECURITY.md`, and `docs/CONFIG.md` ahead of any deployment for operational expectations.

> ℹ️  HyperCore precompile addresses and asset identifiers are placeholders; confirm before stage deployments.

## Repo integration

This folder is self-contained and does not yet wire into CI/CD. After review, lift the deploy script + test suite into the main automation pipeline.

## Documentation Map

- `docs/architecture.md` – High-level design overview.
- `docs/CONFIG.md` – Parameter and ID management reference.
- `docs/ORACLE.md` – Oracle wiring, fallback, divergence policy.
- `docs/FEES_AND_INVENTORY.md` – Fee surface + inventory constraints.
- `docs/OBSERVABILITY.md` – Metrics and dashboard guidance.
- `docs/BYTECODE_ALIGNMENT.md` – Mapping to Lifinity Solana bytecode.
- `docs/rfq_spec.md` – RFQ message + settlement flow.
- `docs/TESTING.md` – Test suite layout and CI guidance.
- `RUNBOOK.md` / `SECURITY.md` – Ops + threat model.
