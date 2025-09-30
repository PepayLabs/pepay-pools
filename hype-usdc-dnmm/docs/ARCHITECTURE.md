# System Architecture

## Overview

The DNMM stack mirrors Lifinity v2 semantics while adapting to HyperEVM primitives:

- **`DnmPool`** – Core AMM vault controlling reserves, quoting, swap execution, fee state, inventory floors, pausing, and governance-controlled parameters.
- **`OracleAdapterHC`** – Reads HyperCore order-book precompiles for mid/bid/ask/EMA values and exposes normalized values to the pool.
- **`OracleAdapterPyth`** – Pulls Pyth HYPE/USD and USDC/USD feeds as fallback + divergence guard.
- **`QuoteRFQ`** (optional) – Verifies off-chain signed quotes and settles against the pool for makers that run in low-latency environments.

Supporting libraries provide fixed-point math, inventory deviation helpers, and partial-fill solving.

## Data Flow

1. **Quote request** – `quoteSwapExactIn` pulls the freshest HyperCore mid; if gates fail it walks the fallback tree (EMA → Pyth) with divergence checks.
2. **Fee computation** – Confidence proxy and inventory deviation feed into the DNMM fee surface with exponential decay back to base.
3. **Partial fill guard** – Before returning, the pool ensures post-trade reserves stay above floor thresholds; if not, it returns the maximal safe input amount.
4. **Swap execution** – `swapExactIn` reuses quote math, performs ERC20 transfers, updates fee state, emits telemetry events, and enforces reentrancy + deadline checks.
5. **Rebalancing** – Each swap calls `_checkAndRebalanceAuto` to refresh `targetBaseXstar` once drift > `recenterThresholdPct`, with permissionless `rebalanceTarget()` as the keeper-friendly fallback and `setTargetBaseXstar` retained for governance overrides.

## Storage Layout

| Slot | Component | Notes |
|------|-----------|-------|
| 0    | Tokens/reserve state | Uses 128-bit packing for base/quote balances |
| 1    | Inventory config     | Floor + recenter thresholds |
| 2    | Oracle config        | Freshness windows, confidence caps, divergence tolerance |
| 3    | Fee config           | Base/alpha/beta/cap/decay parameters |
| 4    | Maker config         | On-chain S0 settings for RFQ path |
| 5    | Guardians            | Governance + pauser |
| 6    | Fee state            | Last fee in bps + last update block |
| 7    | Cached mid           | Last mid used & timestamp for recentering |

## Contracts & Interfaces

- `IDnmPool` – Exposes read-only views plus swap/quote entrypoints.
- `IOracleAdapterHC` – Interface to HyperCore-specific reader contract.
- `IOracleAdapterPyth` – Interface to Pyth fallback/divergence contract.
- `IQuoteRFQ` – Optional verifying contract for off-chain quotes.

## Extensibility

- Additional oracles can be added by implementing the adapter interface and plugging into the pool's fallback chain.
- Hedging keeper integration is left as a v2 extension via events and read-only getters.
- Fee formulas allow parameterized exponent/coefficients; default matches spec but hook is general.
