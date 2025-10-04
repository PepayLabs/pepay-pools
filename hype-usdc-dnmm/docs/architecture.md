---
title: "Architecture Overview"
version: "8e6f14e"
last_updated: "2025-10-04"
---

# HYPE/USDC DNMM Architecture

## Components
- **`DnmPool`** – Manages reserves, quotes, swaps, fee decay, inventory thresholds, LVR surcharge, and governance controls. It now consumes:
  - `FeePolicy` for Lifinity-style α/β fee dynamics.
  - `Inventory` for floors and partial fill solving.
  - `FixedPointMath` for deterministic 512-bit mul/div arithmetic.
  - Aggregator allowlist (`setAggregatorRouter`) and feature flags enabling rebates/LVR.
- **`OracleAdapterHC`** – Wraps HyperCore precompiles (spot, top-of-book, EMA). Function selectors are placeholders until HyperEVM publishes the canonical ABI.
- **`OracleAdapterPyth`** – Pulls HYPE/USD and USDC/USD feeds, returning a synthetic HYPE/USDC mid plus confidence data for divergence checks.
- **`QuoteRFQ`** – Optional RFQ settlement path verifying maker signatures and relaying swaps to `DnmPool`.
- **Libraries**
  - `FixedPointMath`: WAD/BPS helpers with overflow checks.
  - `FeePolicy`: Dynamic fee surface (base + α·conf + β·inventory deviation) with per-block decay.
  - `Inventory`: Floor math and invariant-preserving partial fill solver.
  - `OracleUtils`, `SafeTransferLib`, `ReentrancyGuard`, `Errors` supporting utilities.

## Data Flow
1. Caller requests `quoteSwapExactIn` / `swapExactIn`.
2. `_readOracle` gathers HyperCore spot + bid/ask. If spread/age fail gates, EMA or Pyth fallback is used.
3. `FeePolicy` computes `fee_bps` using SOL/USDC-derived coefficients; `_computeLvrFeeBps` optionally adds sigma×√TTL surcharge when `enableLvrFee` and `fee.kappaLvrBps` are set.
4. Aggregator discount (fixed 3 bps) applies for allow-listed executors without ever breaching BBO floors.
5. `Inventory` determines safe output size and whether a partial is required to preserve floors.
6. `swapExactIn` handles ERC-20 transfers, updates reserves, decays fee state, and emits telemetry (`SwapExecuted`, `LvrFeeApplied`, `PreviewLadderServed`).
7. Governance operations (`updateParams`, `setTargetBaseXstar`, `setAggregatorRouter`, `pause`, `unpause`) rely on dedicated structs with bounds checks.

## Configuration Source of Truth
- Defaults live under `config/parameters_default.json` (Lifinity parity + Core-4 updates: preview freshness 1s, LVR slope default 0, rebates/LVR flags disabled).
- Token + oracle identifiers in `config/tokens.hyper.json` and `config/oracle.ids.json`.
- Mapping back to Solana bytecode documented in `docs/BYTECODE_ALIGNMENT.md`.

## Extensibility & Roadmap
- Swap keepers or routers can rely on `getTopOfBookQuote` for S0 quotes.
- Additional oracle adapters can implement the shared interfaces and be injected via governance upgrades.
- RFQ path can be extended to support EIP-712 once signer UX requires it (currently EIP-191 padded).

Consult `docs/CONFIG.md` for parameter management, `docs/OBSERVABILITY.md` for telemetry, and `RUNBOOK.md` for deployment procedures.
