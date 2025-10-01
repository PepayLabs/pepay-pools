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

### Inventory Tilt (F06)
- When `featureFlags.enableInvTilt` is true the pool applies an additional signed adjustment derived from the instantaneous neutral inventory `x* = (Q + P × B) / (2P)`.
- `invTiltBpsPer1pct` defines the base adjustment per percentage point of deviation; `invTiltMaxBps` clamps the final change.
- Weighting knobs scale the base adjustment: `tiltConfWeightBps` (confidence) and `tiltSpreadWeightBps` (order-book spread) operate in BPS space so `1.0 = 10_000`.
- Trades that worsen the deviation (e.g., base-heavy + base-in) receive a surcharge, while restorative trades are discounted. The helper runs in both swap and preview flows and the result is still bounded by `FeeConfig.capBps`.
- See `test/unit/InventoryTiltTest.t.sol` for regression coverage and `shadow-bot/shadow-bot.ts` for telemetry exposure of the new inventory knobs.

## Floors & Partial Fills (`Inventory` Library)
- `floorBps` reserves safeguarded per side (default 3%).
- `Inventory.quoteBaseIn` / `quoteQuoteIn` ensure post-trade reserves stay above floor; if not, they compute maximal safe input and flag partial fills.
- `SwapExecuted` carries `partial=true` with `reason="FLOOR"` so telemetry can track liquidity exhaustion.

## Implementation Notes
- All math uses `FixedPointMath` (wad + bps) to match Solana big-int semantics.
- `Errors.FloorBreach()` protects against attempts that would empty the vault.
- Governance may tune α/β/cap/decay via `updateParams(ParamKind.Fee, ...)`; bounds checks ensure cap ≥ base and decay ≤ 100.
- Fee-on-transfer tokens are not supported: inbound transfers must deliver the full requested notional or the swap reverts with `Errors.TokenFeeUnsupported()`. The pool emits `TokenFeeUnsupported(user, isBaseIn, expectedIn, receivedIn)` before reverting to simplify alerting.

Refer to `test/unit/FeePolicy.t.sol` and `test/unit/Inventory.t.sol` for coverage of these behaviours.

---

## Oracle Update Costs

### Pyth Network Price Feed Fees

The DnmPool relies on Pyth Network for price validation and fallback oracle data. Understanding Pyth's fee structure is critical for cost optimization.

#### Fee Structure on HyperEVM

**Base Fee**: **1 wei of HYPE** per price update call
- HyperEVM uses HYPE as its native gas token
- Pyth charges the minimum denomination (1 wei) on all EVM chains
- This fee is set by Pyth governance and may change in the future

**Cost Calculation** (as of deployment):
```
HYPE Price: ~$46.50 USD
1 wei = 0.000000000000000001 HYPE
1 wei = $0.0000000000000000465 USD

Effective cost: ~$0.00000000000000005 USD per update
```

**Practical Impact**: Pyth update fees are essentially **free** (~$0.00000000000000005 per call). The actual transaction gas cost dominates.

#### Update Frequency & Validity

**Pyth Price Updates**:
- **Source Frequency**: Pyth aggregates prices on Pythnet every **400 milliseconds** (0.4 seconds)
- **On-Chain Updates**: Only occur when `updatePriceFeeds()` is called with fresh data
- **Price Validity**: Configurable via `maxAgeSec` parameter (default: 48-60 seconds)

**Contract Configuration** (`OracleConfig`):
```solidity
maxAgeSec: 48         // Accept prices up to 48 seconds old
stallWindowSec: 10    // EMA must be fresher than 10s (not used for spot)
divergenceBps: 50     // Reject if HC vs Pyth diverges by >50 bps
```

**Update Strategies**:

1. **User-Paid Updates** (Default)
   - Each trader provides fresh Pyth data with their transaction
   - User pays 1 wei + gas for the update
   - Guarantees freshest possible prices
   ```solidity
   // User fetches Pyth update data from Hermes API
   bytes memory pythData = fetchLatestPythUpdate();

   // Passes data and 1 wei fee to contract
   dnmPool.swapExactIn(amount, minOut, isBuy, pythData, { value: 1 });
   ```

2. **Conditional Updates** (Gas Optimized)
   - Only update if on-chain Pyth data is stale (>48s old)
   - Skip update if recent data exists
   - Saves gas when prices are already fresh
   ```solidity
   uint256 pythAge = block.timestamp - pyth.getPrice(HYPE_FEED).publishTime;
   bytes memory pythData = pythAge > 48 ? fetchPythUpdate() : bytes("");
   uint256 fee = pythData.length > 0 ? 1 : 0;

   dnmPool.swapExactIn(amount, minOut, isBuy, pythData, { value: fee });
   ```

3. **Keeper-Bot Pre-Updates** (Pool Operator)
   - Run automated bot updating Pyth every 30-45 seconds
   - Users trade with no Pyth data (empty bytes)
   - Pool operator pays 1 wei per update, users pay zero
   ```typescript
   // Keeper bot runs every 30 seconds
   setInterval(async () => {
     const pythData = await fetchLatestPythUpdate();
     await pythContract.updatePriceFeeds([pythData], { value: 1 });
   }, 30_000);

   // Users can now trade without Pyth data
   await dnmPool.swapExactIn(amount, minOut, isBuy, "0x", { value: 0 });
   ```

#### HyperCore vs Pyth Oracle Usage

**Primary Oracle**: HyperCore (Free)
- Uses native HyperLiquid precompiles (SPOT_PX at 0x0808)
- No external fees - data available on-chain
- Real-time spot market prices
- **Staleness Detection**: Validated against Pyth via divergence check

**Validation/Fallback Oracle**: Pyth Network (1 wei per update)
- Cross-validates HyperCore prices
- Rejects trades if HC vs Pyth diverges >75 bps (configurable)
- Falls back to Pyth if HyperCore fails or returns stale data
- **Update Required**: Only when providing fresh price data

**Oracle Selection Flow**:
```
1. Read HyperCore SPOT_PX (free, always attempted)
   ├─ If fresh & valid → Use HC price
   ├─ If stale/failed → Try Pyth fallback
   └─ If diverges from Pyth >75 bps → REJECT trade

2. Read Pyth (1 wei if updating, free if already fresh)
   ├─ Validates HC price (divergence check)
   └─ Fallback if HC unavailable

3. If both fail → Revert transaction
```

#### Cost Optimization Recommendations

**For High-Frequency Traders**:
- Implement conditional update logic (skip if Pyth fresh <48s)
- Batch multiple trades per Pyth update
- Expected savings: ~90% of Pyth update calls eliminated

**For Pool Operators**:
- Run keeper bot updating Pyth every 30-40 seconds
- Cost: ~1 wei × 2,160 updates/day = 2,160 wei/day
- At HYPE = $46.50: **~$0.0000001 USD per day**
- Users trade with zero oracle fees

**For Casual Traders**:
- Always provide fresh Pyth data (safest)
- Cost: 1 wei per trade (~$0.00000000000000005)
- Negligible compared to gas costs

#### Total Trading Costs Breakdown

Typical HYPE/USDC trade costs on HyperEVM:

| Cost Component | Amount | Notes |
|----------------|--------|-------|
| Pool Swap Fee | 10-100 bps | Dynamic (base + confidence + inventory) |
| Pyth Oracle Fee | 1 wei HYPE | ~$0.00000000000000005 USD |
| Transaction Gas | ~0.0001-0.001 HYPE | ~$0.005-$0.05 USD (varies by network congestion) |
| **Total** | **~0.1-1% + gas** | Oracle fees negligible vs swap fees |

**Key Insight**: Pyth oracle update fees are **17+ orders of magnitude smaller** than typical swap fees and gas costs. Optimization efforts should focus on gas efficiency and minimizing swap fees through good timing, not oracle update frequency.

#### Monitoring & Alerts

Track oracle costs via:
- On-chain events: Monitor `updatePriceFeeds` calls to Pyth contract
- Pool telemetry: `OracleDivergenceChecked` events show HC vs Pyth comparison
- Shadow-bot metrics: `pythUsed` flag in CSV indicates Pyth fallback usage

Recommended alerts:
- Pyth fallback usage >10% (indicates HC issues)
- Divergence events >5% of trades (indicates price feed problems)
- Pyth staleness >60 seconds (indicates update mechanism failure)
