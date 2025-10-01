# Shadow Bot Implementation Guide

**Path**: `shadow-bot/`

**Description**: Enterprise shadow simulation bot that mirrors the on-chain DNMM protocol behavior exactly. Tests oracle integration, validates pricing logic, monitors health, and generates performance metrics.

---

## Purpose

The shadow bot is a **1:1 off-chain simulation** of `DnmPool.sol` that:

1. **Validates Oracle Integration**: Confirms HyperCore and Pyth oracles return correct, live data
2. **Tests Contract Logic**: Simulates all contract calculations before deployment
3. **Monitors Health**: Tracks divergence, confidence, spreads, and system validity
4. **Generates Metrics**: Produces CSV data and Prometheus metrics for analysis
5. **Performance Testing**: Simulates trades and validates inventory/fee calculations

### Why It Exists

Before deploying $1M+ in capital, we need to verify:
- ✅ Oracles work correctly (not returning garbage)
- ✅ Prices match reality (HyperCore ~= Pyth ~= CEX)
- ✅ Fee calculations are correct
- ✅ Inventory management works
- ✅ Divergence detection triggers appropriately
- ✅ System handles edge cases (stale data, wide spreads, etc.)

**Shadow bot = Contract dress rehearsal with real market data**

---

## Architecture

### Components

```
shadow-bot.ts (1064 lines)
├── Configuration (lines 1-175)
│   ├── Environment variables (RPC, keys, scaling factors)
│   ├── Oracle configs (divergence, confidence, age limits)
│   ├── Inventory configs (floor, target, rebalancing)
│   └── Fee configs (base, alpha, beta, decay)
│
├── Oracle Integration (lines 176-400)
│   ├── readHyperCore() - SPOT_PX (0x0808) + BBO (0x080e)
│   ├── readPythPair() - HYPE/USD and USDC/USD feeds
│   ├── readPythDerived() - Synthetic HYPE/USDC pair
│   └── Price scaling (10^6 → 10^18 WAD)
│
├── Core Logic (lines 401-650)
│   ├── updateSigma() - EWMA volatility calculation
│   ├── calculateInventoryDeviation() - Target vs actual base
│   ├── calculateConfidence() - Blend spread + sigma + Pyth
│   ├── calculateFee() - Dynamic fees with decay
│   ├── checkOracleValidity() - Divergence + staleness gates
│   └── simulateTrade() - Floor-protected partial fills
│
├── Metrics & Output (lines 651-800)
│   ├── Prometheus gauges (prices, confidence, fees)
│   ├── CSV export (timestamped oracle reads)
│   ├── HTTP metrics endpoint (:9464/metrics)
│   └── Console logging (human-readable)
│
└── Main Loop (lines 801-1064)
    ├── loadDNMMConfig() - Pull config from deployed pool
    ├── sampleOnce() - Read oracles, calculate, log
    └── setInterval() - Run every 5 seconds
```

---

## Configuration

### Required Environment Variables

```bash
# Network
RPC_URL=https://hyperliquid-mainnet.g.alchemy.com/v2/YOUR_KEY

# Market Type
USE_SPOT=true  # true for spot markets, false for perps

# Pyth (optional for validation)
PYTH_ADDR=0xe9d69CdD6Fe41e7B621B4A688C5D1a68cB5c8ADc
PYTH_BASE_FEED_ID=0x4279e31cc369bbcc2faf022b382b080e32a8e689ff20fbc530d2a603eb6cd98b  # HYPE/USD
PYTH_QUOTE_FEED_ID=0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a # USDC/USD

# Optional: Override defaults
INTERVAL_MS=5000
OUT_CSV=hype_usdc_shadow_enterprise.csv
PROM_PORT=9464
```

### Optional: Load from Deployed Pool

```bash
DNMM_POOL_ADDRESS=0x...  # If set, loads config from on-chain contract
```

When `DNMM_POOL_ADDRESS` is provided, shadow bot reads:
- Oracle config (divergence limits, confidence caps)
- Inventory config (floor, target, rebalancing thresholds)
- Fee config (base, alpha, beta, cap, decay)
- Current reserves

This ensures shadow bot matches the deployed contract exactly.

---

## Oracle Integration

### HyperCore Oracle (Primary)

**Critical Discovery**: For **spot markets**, must use `SPOT_PX` (0x0808), NOT `ORACLE_PX` (0x0807).

```typescript
// CORRECT for spot (HYPE/USDC)
const ORACLE_PX = '0x0000000000000000000000000000000000000808'; // SPOT_PX
const ORACLE_PRICE_KEY = 107; // Market ID, NOT token ID
const raw = await provider.call({ to: ORACLE_PX, data: encodedKey });
const price = BigInt(raw) * 1e12; // Scale 10^6 → 10^18 WAD
// Result: $46.521 ✅

// WRONG for spot (returns garbage)
const ORACLE_PX = '0x0000000000000000000000000000000000000807'; // ORACLE_PX (perp)
// Result: $0.027 ❌
```

**Why?**
- `ORACLE_PX` (0x0807) = Perp markets only
- `SPOT_PX` (0x0808) = Spot markets only
- Same key (market ID 107) returns different values!

**Scaling**: HyperCore returns prices in `10^(8-szDecimals)` units.
- For HYPE (szDecimals=2): `10^6` units
- To convert to WAD (10^18): multiply by `10^12`

### Pyth Oracle (Validation)

```typescript
// Read HYPE/USD and USDC/USD, compute pair mid
const hypeUsd = await pyth.getPriceUnsafe(HYPE_FEED);
const usdcUsd = await pyth.getPriceUnsafe(USDC_FEED);
const pairMid = (hypeUsd * 1e18) / usdcUsd;
// Result: $46.571 ✅
```

**Purpose**: Cross-validate HyperCore prices
- Divergence >75 bps → Alert/reject
- Confidence >80 bps → Downgrade or reject

### EMA Fallback (Disabled for Spot)

**Important**: `MARK_PX` (0x0806) returns wrong values for spot markets.

```typescript
// Shadow bot disables EMA for spot
if (!USE_SPOT) {
  emaWad = readEMA(); // Only for perps
}
```

**Fallback strategy for spot**:
1. Primary: SPOT_PX (0x0808)
2. If unavailable: Pyth (not HC EMA)
3. If both fail: Reject trade

---

## Core Logic

### 1. Oracle Reading & Fallback

```typescript
async function sampleOnce() {
  // Read HyperCore
  const hc = await readHyperCore();
  const hcFresh = hc.ageSec <= MAX_AGE_SEC;

  // Read Pyth
  const pyth = await readPythAny();
  const pythFresh = pyth.ts && (now - pyth.ts) <= MAX_AGE_SEC;

  // Determine which price to use
  let usedMid = hc.midHC;
  let reason = 'HC_PRIMARY';

  if (!hcFresh && ALLOW_EMA_FALLBACK && hc.emaWad) {
    usedMid = hc.emaWad;
    reason = 'EMA_FALLBACK';
  }

  if (usedMid === 0n && pythFresh && pyth.mid) {
    usedMid = pyth.mid;
    reason = 'PYTH_FALLBACK';
  }

  // Contract flow: DnmPool.sol:558-651 (_readOracle)
}
```

**Matches**: `DnmPool.sol:558-651`

### 2. Divergence Detection

```typescript
// Symmetric formula (matches OracleUtils.computeDivergenceBps)
const hi = max(usedMid, pyth.mid);
const lo = min(usedMid, pyth.mid);
const deltaBps = (10000n * (hi - lo)) / hi;

// Check threshold
if (deltaBps > DIVERGENCE_BPS) {
  validity.valid = false;
  validity.reason = 'DIVERGENCE_EXCEEDED';
}
```

**Matches**: `OracleUtils.sol:25-37`, `DnmPool.sol:640-648`

### 3. Confidence Blending

```typescript
function calculateConfidence(spreadBps, pythConfBps, pythUsed, spreadAvailable) {
  const fallbackConf = pythUsed ? pythConfBps : 0;

  if (!BLEND_ON) {
    return max(spreadBps, fallbackConf); // Legacy mode
  }

  // Weighted blend (matches contract)
  const confSpread = spreadAvailable ? (spreadBps * WEIGHT_SPREAD) / 10000 : 0;
  const confSigma = (sigmaBps * WEIGHT_SIGMA) / 10000;
  const confPyth = fallbackConf > 0 ? (fallbackConf * WEIGHT_PYTH) / 10000 : 0;

  // Take MAX of components
  return max(confSpread, confSigma, confPyth);
}
```

**Matches**: `DnmPool.sol:653-712` (`_computeConfidence`)

### 4. Dynamic Fees with Decay

```typescript
function calculateFee(confBps, invDeviationBps, currentBlock) {
  // Apply decay to previous fee
  if (blocksElapsed > 0 && lastFeeBps > BASE_BPS) {
    const delta = lastFeeBps - BASE_BPS;
    let decayed = delta;
    for (let i = 0; i < blocksElapsed; i++) {
      decayed = (decayed * (100 - DECAY_RATE)) / 100;
    }
    lastFeeBps = BASE_BPS + decayed;
  }

  // Calculate new components
  const confComponent = (confBps * ALPHA_NUM) / ALPHA_DENOM;
  const invComponent = (invDeviationBps * BETA_NUM) / BETA_DENOM;

  let fee = BASE_BPS + confComponent + invComponent;
  if (fee > CAP_BPS) fee = CAP_BPS;

  return fee;
}
```

**Matches**: `FeePolicy.sol:50-130`

### 5. Inventory Deviation

```typescript
function calculateInventoryDeviation() {
  const baseWad = baseReserves; // Already 18 decimals
  const quoteWad = quoteReserves * 1e12; // 6 → 18 decimals
  const targetWad = targetBase; // Already 18 decimals

  const baseNotional = (baseWad * lastMid) / 1e18;
  const totalNotional = quoteWad + baseNotional;

  const deviation = abs(baseWad - targetWad);
  return (deviation * 10000) / totalNotional; // bps
}
```

**Matches**: `Inventory.sol:25-40`

### 6. Trade Simulation

```typescript
function simulateTrade(isBuy: boolean, amountIn: bigint) {
  const floor = (reserves * FLOOR_BPS) / 10000;
  const available = reserves > floor ? reserves - floor : 0;

  // Apply fee
  const netAmount = isBuy
    ? (amountIn * (10000 - FEE_BPS)) / 10000
    : /* quote-in calculation */;

  // Check floor
  if (netAmount <= available) {
    reserves -= netAmount;
    return { executed: true, partial: false };
  }

  // Partial fill
  reserves = floor;
  return { executed: true, partial: true };
}
```

**Matches**: `Inventory.sol:42-107`, `DnmPool.sol:233-299`

---

## Output & Metrics

### CSV Export

**File**: `hype_usdc_shadow_enterprise.csv`

**Columns** (23 total):
```csv
timestamp,mid_hc_wad,bid_wad,ask_wad,spread_bps,
mid_pyth_wad,conf_pyth_bps,mid_ema_wad,
delta_bps,conf_total_bps,conf_spread_bps,conf_sigma_bps,conf_pyth_bps,
sigma_bps,inventory_deviation_bps,fee_bps,
base_reserves,quote_reserves,
decision,used_fallback,pyth_fresh,ema_fresh,
hysteresis_frames,rejection_duration
```

**Example Row**:
```csv
1759184151,46561000000000000000,46561000000000000000,46561000000000000000,0,
46549225416763342891,11,0,
2,0,0,0,0,
0,117,10,
100000.0,3000000.0,
VALID,false,false,false,
0,0
```

**Interpretation**:
- HC mid: $46.561
- Pyth mid: $46.549
- Divergence: 2 bps ✅
- Confidence: 0 bps (tight spread)
- Fee: 10 bps
- Decision: VALID ✅

### Prometheus Metrics

**Endpoint**: `http://localhost:9464/metrics`

**Exported Metrics**:

| Metric | Type | Description |
|--------|------|-------------|
| `mid_hc_wad` | Gauge | HyperCore mid price (WAD) |
| `bid_wad` | Gauge | HyperCore bid (WAD) |
| `ask_wad` | Gauge | HyperCore ask (WAD) |
| `spread_bps` | Gauge | Orderbook spread (bps) |
| `mid_pyth_wad` | Gauge | Pyth mid price (WAD) |
| `conf_bps` | Gauge | Pyth confidence (bps) |
| `delta_bps` | Gauge | HC vs Pyth divergence (bps) |
| `delta_bps_hist` | Histogram | Divergence distribution |
| `conf_bps_hist` | Histogram | Confidence distribution |
| `decision_total` | Counter | Decisions by type (VALID/REJECT/etc) |

**Grafana Integration**: Metrics can be scraped for real-time dashboards.

### Console Output

**Format**:
```
[1759184151] HC: mid=46.561 spread=0bps age=0s
  | Pyth: mid=46.549 conf=11bps
  | delta=2bps conf=0bps (spread=0 sigma=0 pyth=0)
  | sigma=0bps inv_dev=117bps fee=10bps
  | HC_PRIMARY | VALID
```

**Interpretation**:
- HyperCore: $46.561, fresh (age=0), tight spread (0 bps)
- Pyth: $46.549, low confidence (11 bps)
- Divergence: 2 bps (well within 75 bps limit) ✅
- Fee: 10 bps (base fee, no confidence/inventory adjustments)
- Decision: VALID (trade would execute)

---

## Validation Gates

Shadow bot implements the same gates as `DnmPool.sol`:

### 1. Staleness Check
```typescript
if (hc.ageSec > MAX_AGE_SEC && !emaFresh && !pythFresh) {
  return { valid: false, reason: 'ORACLE_STALE' };
}
```
**Matches**: `DnmPool.sol:622-625`

### 2. Spread Check
```typescript
if (!usedFallback && spreadAvailable && spreadBps > CONF_CAP_BPS_SPOT) {
  return { valid: false, reason: 'SPREAD_TOO_WIDE' };
}
```
**Matches**: `DnmPool.sol:587-588, 623`

### 3. Divergence Check
```typescript
if (!usedFallback && pythFresh && deltaBps > DIVERGENCE_BPS) {
  return { valid: false, reason: 'DIVERGENCE_EXCEEDED' };
}
```
**Matches**: `DnmPool.sol:640-648`

### 4. Confidence Cap Check
```typescript
if (confBps > CONF_CAP_BPS_STRICT) {
  return { valid: false, reason: 'CONF_CAP_EXCEEDED' };
}
```
**Matches**: `DnmPool.sol:667-677`

---

## Testing & Verification

### Running Shadow Bot

```bash
# Basic run
npm run shadow-bot

# With deployed pool config
DNMM_POOL_ADDRESS=0x... npm run shadow-bot

# View metrics
curl http://localhost:9464/metrics

# Tail CSV
tail -f hype_usdc_shadow_enterprise.csv
```

### Verification Tests

```bash
# Test oracle connectivity
npx tsx test-oracle.ts

# Verify HyperLiquid responses
npx tsx verify-hyperliquid.ts

# Test all precompiles
npx tsx test-precompiles.ts
```

### Expected Results

**Healthy Operation**:
- Delta: <10 bps (HC ~= Pyth)
- Confidence: <50 bps (tight markets)
- Spread: <20 bps (liquid orderbook)
- Decision: VALID >95% of time
- Fees: 10-30 bps (base + adjustments)

**Alert Conditions**:
- Delta >50 bps → Investigate oracle discrepancy
- Confidence >80 bps → Wide spreads or volatility
- Decision: REJECT → Check staleness or divergence
- Fees >80 bps → High risk conditions detected

---

## Maintenance

### Updating Configuration

If `DnmPool.sol` config changes:

1. **Option A**: Restart with `DNMM_POOL_ADDRESS` set
   ```bash
   DNMM_POOL_ADDRESS=0xNEW_ADDRESS npm run shadow-bot
   ```

2. **Option B**: Update env vars manually
   ```bash
   DIVERGENCE_BPS=100  # New threshold
   CONF_CAP_BPS_SPOT=150
   npm run shadow-bot
   ```

### Monitoring

**Key Metrics to Watch**:
- `delta_bps` > 50 for >5 minutes → Oracle divergence
- `decision_total{decision="REJECT"}` increasing → System issues
- `conf_bps` > 100 persistently → Market volatility
- `spread_bps` > 50 → Illiquid conditions

**Grafana Alerts** (recommended):
```yaml
- alert: OracleDivergence
  expr: delta_bps > 75
  for: 5m

- alert: HighRejectionRate
  expr: rate(decision_total{decision="REJECT"}[5m]) > 0.5
  for: 10m
```

---

## Contract Parity Checklist

Shadow bot matches these exact contract behaviors:

- ✅ Oracle precompile calls (`OracleAdapterHC.sol:64-118`)
- ✅ Price scaling (raw → WAD)
- ✅ EMA fallback logic (`DnmPool.sol:591-609`)
- ✅ Pyth fallback logic (`DnmPool.sol:611-620`)
- ✅ Divergence calculation (`OracleUtils.sol:25-37`)
- ✅ Confidence blending (`DnmPool.sol:653-712`)
- ✅ EWMA sigma update (`DnmPool.sol:715-790`)
- ✅ Fee calculation with decay (`FeePolicy.sol:50-130`)
- ✅ Inventory deviation (`Inventory.sol:25-40`)
- ✅ Floor-protected fills (`Inventory.sol:42-107`)
- ✅ Validation gates (`DnmPool.sol:587-648`)

**Verification**: Compare shadow bot CSV output with on-chain events.

**Divergence >5%?** → Bug in shadow bot or contract needs update.

---

## Common Issues

### Issue: "Pyth stale/missing"

**Cause**: Pyth prices older than `MAX_AGE_SEC` (60s)

**Fix**:
- Increase `MAX_AGE_SEC` if acceptable
- Check Pyth network health
- Verify feed IDs are correct

### Issue: Delta = 9994 bps

**Cause**: Using wrong precompile (ORACLE_PX instead of SPOT_PX)

**Fix**: Verify `USE_SPOT=true` in env

### Issue: BBO spread = 0

**Cause**: BBO precompile returns wrong units for spot

**Fix**: Shadow bot falls back to mid ± small spread estimate

### Issue: EMA returns $0.027

**Cause**: MARK_PX doesn't work for spot markets

**Fix**: Shadow bot disables EMA for spot, uses Pyth fallback

---

## Future Improvements

### Phase 1: Multi-Pool Support
```typescript
const POOLS = [
  { base: 'HYPE', quote: 'USDC', marketId: 107 },
  { base: 'ETH', quote: 'USDC', marketId: 42 }
];
```

### Phase 2: Live Trading Integration
```typescript
if (validity.valid && shouldTrade()) {
  const tx = await dnmmPool.swapExactIn(amount, 0, true, ...);
  console.log(`Executed: ${tx.hash}`);
}
```

### Phase 3: Advanced Analytics
- Slippage analysis
- MEV detection
- Arbitrage opportunity tracking
- LP profitability modeling

### Phase 4: WebSocket Integration
```typescript
const ws = new WebSocket('wss://hyperliquid.com/ws');
ws.on('trade', (data) => updateMetrics(data));
```

---

## Maintainers & Contacts

- **Primary**: TBD (assign owner)
- **Backup**: TBD (assign delegate)
- **Alerts**: See `OPERATIONS.md`

## Change Log

- **2025-10-01**: Parsed expanded `oracleConfig()` (accept/soft/hard, haircut) and `feeConfig()` (size-fee gammas + cap) return values; synced feature flag environment toggles to the zero-default set (blend/soft divergence/size fee/BBO floor/inventory tilt/AOMQ/rebates/auto recenter).

- **2025-09-29**: Initial implementation with correct SPOT_PX oracle integration
  - Fixed precompile selection (0x0808 for spot, not 0x0807)
  - Added price scaling (10^6 → 10^18 WAD)
  - Disabled EMA fallback for spot markets
  - Verified live HyperLiquid data with 2 bps divergence vs Pyth
  - Implemented full DNMM simulation (fees, inventory, confidence)
  - Added Prometheus metrics and CSV export
  - Created verification tests (test-oracle.ts, verify-hyperliquid.ts)
