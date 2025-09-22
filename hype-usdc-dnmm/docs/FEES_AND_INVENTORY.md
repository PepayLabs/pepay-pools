# Fee Surface & Inventory Controls

## Fee Formula (FeePolicy)
`fee_bps = baseBps + α·conf_bps + β·inventoryDeviationBps`, capped at `capBps`, followed by exponential decay toward `baseBps` each block.

- **α (confidence slope)** → `alphaConfNumerator / alphaConfDenominator` (SOL/USDC parity: 0.60).
- **β (inventory slope)** → `betaInvDevNumerator / betaInvDevDenominator` (SOL/USDC parity: 0.10).
- **Decay** → `decayPctPerBlock` (20% per block by default). Implemented via scaled exponentiation in `FeePolicy`.
- **State**: `FeePolicy.FeeState` caches last fee + block to ensure accurate decay before recomputation.
- **Observability**: `SwapExecuted` emits `feeBps`, allowing dashboards to reconstruct effective fees; extend analytics to derive component breakdown off-chain using oracle/conf inputs.

## Confidence (`conf_bps`)
- Blended per block as `max(w_spread·spread, w_sigma·sigma, w_pyth·pyth_conf)` with weights from `config/parameters_default.json`.
- `sigma` is an EWMA of realized price deltas (λ ≈ 0.9) and updates at most once per block; fallback to spread seeds the initial value.
- Final confidence is clamped by `confCapBpsSpot` (quotes) or `confCapBpsStrict` (strict mode, e.g. RFQ).
- When `DEBUG_EMIT` is enabled the `ConfidenceDebug` event exposes each component (`confSpread`, `confSigma`, `confPyth`, blended `conf_bps`, and fee decomposition) for telemetry.

## Inventory Deviation (`Inventory.deviationBps`)
- `|baseReserves - targetBaseXstar| / poolNotional × 10_000` using latest mid price.
- `targetBaseXstar` updates only when price change exceeds `recenterThresholdPct` (7.5% default).

## Floors & Partial Fills (`Inventory` Library)
- `floorBps` reserves safeguarded per side (default 3%).
- `Inventory.quoteBaseIn` / `quoteQuoteIn` ensure post-trade reserves stay above floor; if not, they compute maximal safe input and flag partial fills.
- `SwapExecuted` carries `partial=true` with `reason="FLOOR"` so telemetry can track liquidity exhaustion.

## Implementation Notes
- All math uses `FixedPointMath` (wad + bps) to match Solana big-int semantics.
- `Errors.FLOOR_BREACH` protects against attempts that would empty the vault.
- Governance may tune α/β/cap/decay via `updateParams(ParamKind.Fee, ...)`; bounds checks ensure cap ≥ base and decay ≤ 100.
- Fee-on-transfer tokens are not supported: inbound transfers must deliver the full requested notional or the swap reverts with `Errors.TOKEN_FEE_UNSUPPORTED`. The pool emits `TokenFeeUnsupported(user, isBaseIn, expectedIn, receivedIn)` before reverting to simplify alerting.

Refer to `test/unit/FeePolicy.t.sol` and `test/unit/Inventory.t.sol` for coverage of these behaviours.
