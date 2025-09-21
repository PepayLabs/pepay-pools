# HYPE/USDC DNMM (HyperEVM)

End-to-end research and engineering drop for a Lifinity v2–style dynamic no-manual-market-maker (DNMM) tailored to the HYPE/USDC spot market on HyperEVM. The design anchors on Hyperliquid HyperCore order-book data with a Pyth fallback/divergence oracle, provides on-chain quoting + swap execution, optional RFQ settlement, and exposes the governance/observability hooks required for mainnet-readiness.

## What lives here

- Production-focused Solidity contracts (`contracts/`) with modular oracle adapters
- Configurable DNMM fee, inventory, and risk controls with guarded updates
- Deployment and operations scaffolding (scripts, checklists, telemetry hooks)
- Research docs summarising math, oracle wiring, and runbooks (`docs/`)
- Foundry-based test harness (`test/`) covering fee dynamics, partial fills, divergence gates, and RFQ verification flows

## Quick Start

1. Install Foundry (`curl -L https://foundry.paradigm.xyz | bash`) and run `foundryup`.
2. From this folder run `forge install foundry-rs/forge-std` and `forge install OpenZeppelin/openzeppelin-contracts@v5.0.2`.
3. Configure the HyperEVM+Pyth endpoints in `script/Deploy.s.sol` before dry runs.
4. Execute `forge test` for the default suite or `forge test --match-test testFeeDecay` to focus on a component.
5. Review `docs/OPERATIONS.md` ahead of any deployment for guardian/telemetry requirements.

> ℹ️  HyperCore precompile addresses and asset identifiers are placeholders; confirm before stage deployments.

## Repo integration

This folder is self-contained and does not yet wire into CI/CD. After review, lift the deploy script + test suite into the main automation pipeline.
