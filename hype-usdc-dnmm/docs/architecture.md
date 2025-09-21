# HYPE/USDC DNMM Architecture

## Components
- `DnmPool`: On-chain vault, fee logic, inventory management, governance controls.
- `OracleAdapterHC`: Wraps HyperCore precompiles for spot, orderbook, EMA data.
- `OracleAdapterPyth`: Pulls Pyth prices (HYPE/USD, USDC/USD) for fallback + divergence.
- `Inventory` library: Floors + partial-fill solver ensuring reserves never breach target buffers.
- `FeePolicy` library: Lifinity-style dynamic fee surface with α·confidence + β·inventory deviation and per-block decay.
- `QuoteRFQ`: Optional RFQ verifier for maker-signed, TTL-bounded quotes.

## Data Flow
1. Caller issues `quoteSwapExactIn` or `swapExactIn`.
2. `_readOracle` fetches HyperCore mid/metadata, falling back to EMA or Pyth under configured gates.
3. `FeePolicy` computes fee_bps using SOL/USDC coefficients (base, α, β, cap, decay).
4. `Inventory` evaluates partial fills against floor bps and returns net amounts.
5. Reserves update, events emitted, and `feeState` cached for decay on next block.

## Config Derivation
- Oracle caps/freshness sourced from `lifinity_pools_oracle_config.json` (wSOL/USDC entry) and translated to seconds.
- Dynamic fee multipliers & thresholds adapted from `CONFIGURATION_VALUES.md` Lifinity notes.
- Divergence threshold defaults to 50 bps (aligns with HyperCore/Pyth drift policy).

## Extensibility
- Additional oracle adapters can implement `IOracleAdapterHC` interface and plug into `_readOracle` chain.
- Fee and inventory parameters adjustable via `updateParams`, wrapped in governance access controls.
- RFQ path optional; aggregator adapters can integrate via `getTopOfBookQuote` telemetry.

See `docs/BYTECODE_ALIGNMENT.md` for Solana bytecode ↔ Solidity mapping.
