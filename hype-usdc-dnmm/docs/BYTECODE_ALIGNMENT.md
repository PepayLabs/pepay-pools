# Bytecode Alignment Map

| Solana Decomp (offset / symbol) | Behaviour Summary | Solidity Counterpart | Notes |
|---------------------------------|-------------------|----------------------|-------|
| `FUN_ram_00000120` (entry) | Instruction decode, account checks, state deserialisation | `DnmPool` constructor + `swapExactIn` access guards | State layout mirrored via struct packing / accessors. |
| `FUN_ram_00007e74` (oracle gate) | Pyth header validation, confidence clamp, slot freshness | `DnmPool._readOracle` + `OracleAdapterHC` / `OracleAdapterPyth` | Uses HyperCore + Pyth fallback; strict/spot caps from SOL/USDC config. |
| `FUN_ram_00010dd0` (swap handler) | Oracle mid fetch → fee calc → partial fill solver | `DnmPool._quoteInternal` + `Inventory.quoteBaseIn/quoteQuoteIn` + `FeePolicy` | Partial solver leaves inventory floor, matching decompiled branch. |
| `FUN_ram_00014620` (recenter) | Updates target inventory once oracle drift > threshold | `DnmPool.setTargetBaseXstar` + deviation checks | Threshold pulled from config `recenterThresholdPct`. |
| `FUN_ram_00015b80` (fee decay) | Exponential decay of dynamic fee toward baseline | `FeePolicy.preview` / `FeePolicy.settle` | Utilises per-block decay with α/β components. |
| `FUN_ram_00017140` (EMA fallback) | If spot fails, load EMA window and reuse solver | `_readOracle` EMA branch gated by `allowEmaFallback` | Divergence vs Pyth enforced before swap proceeds. |
| `FUN_ram_00019590` (partial fill guard) | Solve quadratic to leave liquidity floor | `Inventory.quoteBaseIn` / `Inventory.quoteQuoteIn` | Uses `FixedPointMath` for deterministic scaling and matches Solana big-int ops. |
| `FUN_ram_0001c050` (event emit) | Emit swap + fee telemetry | `SwapExecuted` / `QuoteServed` events | Event fields mirror Solana logging schema. |

## HyperCore Precompile Pinning

HyperCore exposes dedicated read-only precompiles at 0x…0800+. The adapter calls them with raw ABI-encoded 32-byte inputs (no selectors) and decodes the returned tuples.

| Call | Precompile Address | Solidity Helper |
|------|--------------------|-----------------|
| `markPx(uint32)` | `0x0000000000000000000000000000000000000806` | `HyperCoreConstants.MARK_PX_PRECOMPILE` |
| `oraclePx(uint32)` | `0x0000000000000000000000000000000000000807` | `HyperCoreConstants.ORACLE_PX_PRECOMPILE` |
| `spotPx(uint32)` | `0x0000000000000000000000000000000000000808` | `HyperCoreConstants.SPOT_PX_PRECOMPILE` |
| `bbo(uint32)` | `0x000000000000000000000000000000000000080e` | `HyperCoreConstants.BBO_PRECOMPILE` |

Update Procedure:
1. Fetch the latest `L1Read.sol` from the HyperCore documentation bundle and confirm the precompile addresses/return structs.
2. If Hyperliquid shifts addresses, update `contracts/oracle/HyperCoreConstants.sol` and re-run `test/unit/OracleAdapterHC_Selectors.t.sol` (now checking addresses).
3. Adjust mocks in `test/utils/Mocks.sol` so canonical addresses continue to respond during unit tests.
4. Record provenance (doc URL + retrieval date) in this file and in release notes.

## Gap Review
- **EMA exact weighting**: Lifinity caches EMA in state; HyperCore exposes via precompile – weighting remains aligned with current docs.
- **Rebalance automation**: Solana program has keeper hook; EVM version exposes `setTargetBaseXstar` for governance/keeper. Keeper automation scheduled post-MVP.
