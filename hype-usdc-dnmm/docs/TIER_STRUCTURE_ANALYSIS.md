---
title: "Tier Structure Analysis"
version: "8e6f14e"
last_updated: "2025-10-04"
---

# Volume Tier Structure Analysis - Aggregator-Focused Design

## Problem with Original Tiers

**Original Design** (WRONG):
```solidity
VolumeTier({ monthlyVolumeUSD: 2_000_000e6, discountBps: 40, makerRebateBps: -5 })
```

**Math at 30 bps average fee:**
```
30 bps - 40 bps discount = 0 bps (floored)
Then: 0 bps - 5 bps rebate = -5 bps

Result: We PAY the trader 0.05% to trade with us!
```

**At $2M monthly volume:**
```
Revenue: $2M × -0.05% = -$10,000 LOSS per month
```

---

## Critical Insight: Aggregators Drive 70%+ of Volume

### Real Volume Breakdown
```
Aggregators (1inch, CoW, etc.):  70-80% of volume
Direct Institutions:              15-25% of volume
Retail (our UI):                  <5% of volume
```

### How Aggregators Route

Aggregators DON'T care about "volume tiers" - they calculate **best execution**:

```typescript
// 1inch routing algorithm (simplified)
const venues = [
  { name: 'Uniswap', fee: 30, slippage: 20, gas: 180k },  // Total: 50 bps
  { name: 'DNMM',    fee: 15, slippage: 5,  gas: 225k },  // Total: 20 bps ✅
  { name: 'Curve',   fee: 4,  slippage: 8,  gas: 200k }   // Total: 12 bps ✅✅
];

// Routes to LOWEST total cost (fee + slippage + gas impact)
```

**Key**: We win aggregator routing by having **low total cost**, NOT by giving "tier discounts"!

---

## Corrected Strategy: Two-Tier System

### Tier A: Aggregator Recognition (70-80% of volume)
**Who**: Known aggregator router contracts (1inch, CoW, Matcha, Paraswap)
**How**: Simple address whitelist
**Discount**: Fixed 3 bps (protocol constant; keeps routing parity while respecting floors)
**Gas**: +~2k (single allowlist SLOAD)

### Tier B: Direct Institutional (15-25% of volume)
**Who**: Professional traders with direct integration
**How**: Volume-based monthly tracking
**Discount**: Conservative (5-15 bps max)
**Gas**: +15k (acceptable for direct relationships)

---

## Industry Benchmark Analysis

### What Competitors Charge

| Venue | Base Fee | Aggregator Discount | Direct Institution Discount |
|-------|----------|-------------------|---------------------------|
| **Uniswap v3** | 30 bps | ❌ None | ❌ None |
| **Curve** | 4-5 bps | ❌ None | ❌ None |
| **Balancer** | 15-25 bps | ❌ None | ❌ None |
| **1inch Fusion** | Variable | ❌ None (charges!) | ❌ None |
| **TraderJoe v2** | 20-40 bps | ❌ None | ❌ None |

**Key Finding**: NO major DEX gives aggregators explicit discounts!

### Why We Should Still Give Aggregator Discount

Even though others don't, a small fixed discount (3 bps) helps us:
1. Consistently beat Uniswap (30 bps) in routing
2. Signal that we WANT aggregator integration
3. Cost is minimal (3-5 bps on 70% of volume)

---

## Recommended Tier Structure

### Aggregator Tier (Simple Address-Based)

```solidity
mapping(address => bool) private _aggregatorRouters;
uint16 public constant AGGREGATOR_DISCOUNT_BPS = 3;

function setAggregatorRouter(address executor, bool allowed) external onlyGovernance {
    if (executor == address(0)) revert Errors.InvalidConfig();
    _aggregatorRouters[executor] = allowed;
    emit AggregatorDiscountUpdated(executor, allowed ? AGGREGATOR_DISCOUNT_BPS : 0);
}

function _aggregatorDiscount(address executor) internal view returns (uint16) {
    return _aggregatorRouters[executor] ? AGGREGATOR_DISCOUNT_BPS : 0;
}
```

**Known Aggregator Addresses to Whitelist:**
```
1inch Router v5:     0x1111111254EEB25477B68fb85Ed929f73A960582
CoW Protocol:        0x9008D19f58AAbD9eD0D60971565AA8510560ab41
Matcha (0x):         0xDef1C0ded9bec7F1a1670819833240f027b25EfF
Paraswap v5:         0xDEF171Fe48CF0115B1d80b88dc8eAB59176FEe57
KyberSwap:           0x6131B5fae19EA4f9D964eAc0408E4408b66337b5
```

### Institutional Tiers (Volume-Based)

```solidity
struct VolumeTier {
    uint256 monthlyVolumeUSD;
    uint16 discountBps;
    int16 makerRebateBps;  // Negative = rebate
}

// CORRECTED: Conservative discounts that won't bankrupt us
VolumeTier[5] public institutionalTiers = [
    // Tier 0: Retail (<$100k/month)
    VolumeTier({
        monthlyVolumeUSD: 0,
        discountBps: 0,
        makerRebateBps: 0
    }),

    // Tier 1: Small Institution ($100k-$1M/month)
    // Discount: ~10% of typical fee above base
    VolumeTier({
        monthlyVolumeUSD: 100_000e6,
        discountBps: 3,    // 3 bps off (e.g., 30 → 27 bps)
        makerRebateBps: 0
    }),

    // Tier 2: Medium Institution ($1M-$10M/month)
    // Discount: ~20% of typical fee above base
    VolumeTier({
        monthlyVolumeUSD: 1_000_000e6,
        discountBps: 5,    // 5 bps off (e.g., 30 → 25 bps)
        makerRebateBps: 0
    }),

    // Tier 3: Large Institution ($10M-$50M/month)
    // Discount: ~33% + small rebate for market making
    VolumeTier({
        monthlyVolumeUSD: 10_000_000e6,
        discountBps: 8,    // 8 bps off (e.g., 30 → 22 bps)
        makerRebateBps: -2 // 2 bps rebate if providing liquidity
    }),

    // Tier 4: VIP ($50M+/month)
    // Discount: ~50% + enhanced rebate (custom negotiated)
    VolumeTier({
        monthlyVolumeUSD: 50_000_000e6,
        discountBps: 12,   // 12 bps off (e.g., 30 → 18 bps)
        makerRebateBps: -4 // 4 bps rebate
    })
];
```

---

## Fee Calculation Examples

### Example 1: Calm Market (15 bps base fee)

**Aggregator Route:**
```
Dynamic fee: 15 bps (base only, no volatility)
Aggregator discount: -3 bps
Final fee: 12 bps ✅ (vs Uniswap 30 bps - we win!)
```

**Tier 3 Institution ($15M/month volume):**
```
Dynamic fee: 15 bps
Institution discount: -8 bps
Maker rebate: -2 bps
Final fee: 5 bps ✅ (competitive with Curve!)
```

---

### Example 2: Normal Market (30 bps = base 15 + 15 volatility)

**Aggregator Route:**
```
Dynamic fee: 30 bps
Aggregator discount: -3 bps
Final fee: 27 bps ✅ (still cheaper than Uniswap 30 bps)
```

### Example 3: Volatile Frame (LVR enabled)

**Aggregator Route:**
```
Base fee: 15 bps
Confidence term: +9 bps (σ-driven)
LVR surcharge: +6 bps (enableLvrFee, kappa=800)
Subtotal: 30 bps
Aggregator discount: -3 bps
Final fee: 27 bps ✅ (volatility priced without violating floor)
```

**Tier 3 Institution:**
```
Dynamic fee: 30 bps
Institution discount: -8 bps
Maker rebate: -2 bps
Final fee: 20 bps ✅ (competitive)
Revenue on $10M: $10M × 0.20% = $20,000/month
```

---

### Example 3: Volatile Market (80 bps = base 15 + 65 high confidence)

**Aggregator Route:**
```
Dynamic fee: 80 bps
Aggregator discount: -3 bps
Final fee: 77 bps ✅ (higher than Uniswap, but justified by volatility)
```

**Tier 3 Institution:**
```
Dynamic fee: 80 bps
Institution discount: -8 bps
Maker rebate: -2 bps
Final fee: 70 bps ✅ (good profit margin)
Revenue on $10M: $10M × 0.70% = $70,000/month
```

---

## Revenue Impact Analysis

### Scenario: $50M Monthly Volume Mix

**Volume Breakdown:**
- Aggregators: $35M (70%)
- Tier 3 Institutions: $10M (20%)
- Tier 1-2: $5M (10%)

**Fee Assumptions** (average 30 bps dynamic):

**Aggregator Revenue:**
```
$35M × (30 - 3) bps = $35M × 0.27% = $94,500
```

**Tier 3 Institution Revenue:**
```
$10M × (30 - 8 - 2) bps = $10M × 0.20% = $20,000
```

**Tier 1-2 Revenue:**
```
$5M × (30 - 4) bps = $5M × 0.26% = $13,000
```

**Total Monthly Revenue: $127,500**

**Plus Rebalancing Profits:**
```
Rebalancing typically yields 0.15-0.25% of volume
$50M × 0.20% = $100,000/month
```

**Total: $227,500/month** ✅ PROFITABLE

---

## Comparison: Original vs Corrected Tiers

### Original Tier 5 ($50M institution at 30 bps avg fee):
```
30 bps - 80 bps discount = 0 bps (floored)
0 bps - 15 bps rebate = -15 bps
Revenue: $50M × -0.15% = -$75,000 LOSS
```

### Corrected Tier 4 ($50M institution at 30 bps avg fee):
```
30 bps - 12 bps discount = 18 bps
18 bps - 4 bps rebate = 14 bps
Revenue: $50M × 0.14% = $70,000 PROFIT
```

**Difference: +$145,000/month swing** (from -$75k to +$70k)

---

## Implementation: Swap Function with Aggregator Check

```solidity
function swapExactIn(
    uint256 amountIn,
    uint256 minAmountOut,
    bool isBaseIn,
    OracleMode mode,
    bytes calldata oracleData,
    uint256 deadline
) external nonReentrant whenNotPaused returns (uint256 amountOut) {
    if (block.timestamp > deadline) revert Errors.DeadlineExpired();

    // ... existing oracle + risk checks ...

    QuoteResult memory result = _quoteInternal(...);
    uint16 dynamicFeeBps = result.feeBpsUsed;
    uint16 finalFeeBps = dynamicFeeBps;
    uint8 routeType = 0;  // 0 = retail, 1 = aggregator, 2 = institution

    // CHEAPEST PATH: Check if aggregator (no volume tracking)
    if (isAggregatorRouter[msg.sender]) {
        finalFeeBps = dynamicFeeBps > AGGREGATOR_DISCOUNT_BPS
            ? dynamicFeeBps - AGGREGATOR_DISCOUNT_BPS
            : 0;
        routeType = 1;
    }
    // MORE EXPENSIVE: Volume tier tracking for direct traders
    else if (traderVolumes[msg.sender].currentTier > 0 ||
             traderVolumes[msg.sender].last30DayVolume > 0) {

        TraderVolume storage vol = traderVolumes[msg.sender];
        _updateTraderVolume(vol, amountIn, isBaseIn, result.midUsed);

        VolumeTier memory tier = institutionalTiers[vol.currentTier];

        // Apply discount
        finalFeeBps = dynamicFeeBps > tier.discountBps
            ? dynamicFeeBps - tier.discountBps
            : 0;

        // Apply rebate if applicable
        if (tier.makerRebateBps < 0) {
            int256 withRebate = int256(uint256(finalFeeBps)) + tier.makerRebateBps;
            finalFeeBps = withRebate >= 0 ? uint16(uint256(withRebate)) : 0;
        }

        routeType = 2;
    }
    // RETAIL: No discount, no tracking

    // Recalculate swap with final fee
    if (finalFeeBps != dynamicFeeBps) {
        (amountOut, /*...*/) = _computeSwapAmounts(
            amountIn,
            isBaseIn,
            result.midUsed,
            finalFeeBps,
            // ... other params
        );
    } else {
        amountOut = result.amountOut;
    }

    // ... existing transfer logic ...

    emit SwapExecuted(
        msg.sender,
        isBaseIn,
        amountIn,
        amountOut,
        result.midUsed,
        dynamicFeeBps,  // Original fee
        finalFeeBps,     // Applied fee
        routeType,       // 0=retail, 1=aggregator, 2=institution
        vol.currentTier  // Only meaningful if routeType == 2
    );
}
```

---

## Gas Impact by Route Type

### Aggregator Route (70% of volume):
```
Extra operations:
  - 1 SLOAD (isAggregatorRouter check): 2.1k gas
  - 1 subtraction + comparison: ~100 gas
Total: +2.2k gas

Total swap cost: 225k + 2.2k = 227.2k gas
```

### Direct Institution Route (25% of volume):
```
Extra operations:
  - Volume tracking: +15k gas (time-bucketed)
  - Tier calculation: ~500 gas
Total: +15.5k gas

Total swap cost: 225k + 15.5k = 240.5k gas
```

### Retail Route (5% of volume):
```
Extra operations: None
Total swap cost: 225k gas (baseline)
```

**Weighted Average Gas:**
```
227.2k × 0.70 + 240.5k × 0.25 + 225k × 0.05
= 159k + 60k + 11.2k
= 230.2k gas average (+2.3% vs baseline)
```

**Result: Only +2.3% gas increase** (vs +15k if ALL routes tracked volume)

---

## Recommended Implementation Order

### Phase 1: Aggregator Integration (Week 5-6)
1. Add `isAggregatorRouter` mapping
2. Add `AGGREGATOR_DISCOUNT_BPS` constant (3 bps)
3. Whitelist known aggregators (1inch, CoW, etc.)
4. Test with shadow mode
5. Launch aggregator routing

**Impact: 70% of volume immediately competitive**

### Phase 2: Institutional Tiers (Week 9-10)
1. Add volume tracking (time-bucketed)
2. Implement 5 conservative tiers
3. Build institutional onboarding portal
4. Pilot with 1-2 traders

**Impact: 25% of volume gets loyalty discounts**

---

## Summary: Why This is Better

| Aspect | Original Tiers | Corrected Tiers |
|--------|---------------|-----------------|
| **Aggregator Focus** | ❌ Ignored (70% of volume) | ✅ Dedicated tier (+2k gas) |
| **Discount Math** | ❌ 80 bps = bankruptcy | ✅ 12 bps max = sustainable |
| **Gas Efficiency** | ❌ +15k all routes | ✅ +2k for 70% of routes |
| **Revenue** | ❌ -$75k on Tier 5 | ✅ +$70k on Tier 4 |
| **Competitiveness** | ⚠️ Too generous | ✅ Just enough to win |
| **Sustainability** | ❌ Loses money | ✅ Profitable |

---

## Next Steps

1. **Update all three documents** (OPTIMIZED, FINAL, this one)
2. **Validate with aggregator partnerships** (reach out to 1inch, CoW)
3. **Model revenue projections** with realistic fee discounts
4. **Deploy to testnet** and measure actual gas costs
5. **Shadow mode testing** to validate aggregator routing

---

*Analysis Complete - Ready for Implementation*
