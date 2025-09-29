# HyperLiquid Oracle Precompile Analysis for Spot Markets

## Executive Summary

**Critical Finding**: The `OracleAdapterHC.sol` contract is configured for **perp markets**, not **spot markets**. It uses `ORACLE_PX` (0x0807) which returns incorrect prices for spot pairs like HYPE/USDC.

**Impact**:
- Contract would return $0.027 instead of $46.50 for HYPE/USDC spot
- EMA fallback returns similarly wrong values
- All price-dependent logic (fees, inventory, divergence) would fail

---

## The Problem: Wrong Precompile for Spot Markets

### Contract Current Configuration

```solidity
// OracleAdapterHC.sol:67
bytes memory data = _callHyperCore(HyperCoreConstants.ORACLE_PX_PRECOMPILE, callData, 8);
// ↑ Uses 0x0807 (ORACLE_PX)

// OracleAdapterHC.sol:107
bytes memory data = _callHyperCore(HyperCoreConstants.MARK_PX_PRECOMPILE, callData, 8);
// ↑ EMA fallback uses 0x0806 (MARK_PX)
```

### Empirical Testing Results

Using HYPE/USDC spot (market ID = 107) at price ~$46.50:

| Precompile | Address | Key | Raw Response | Scaled | Status |
|------------|---------|-----|--------------|--------|--------|
| **ORACLE_PX** | 0x0807 | 107 | 27,737 | $0.027737 | ❌ WRONG |
| **SPOT_PX** | 0x0808 | 107 | 46,559,000 | $46.559 | ✅ CORRECT |
| **MARK_PX** | 0x0806 | 107 | 27,723 | $0.027723 | ❌ WRONG |
| **BBO** | 0x080e | 107 | 27,716/27,747 | $0.027 | ❌ WRONG |
| Pyth HYPE/USD | - | - | - | $46.571 | ✅ CORRECT |

### Why This Happens

HyperCore has **different precompiles for different market types**:

```
PERP markets:
- ORACLE_PX (0x0807) → Works for perp index
- Returns price in 10^(6-szDecimals) units

SPOT markets:
- SPOT_PX (0x0808) → Works for spot market ID
- Returns price in 10^(8-szDecimals) units

EMA/Mark:
- MARK_PX (0x0806) → Seems to work for perp only
- Returns wrong values for spot
```

---

## Root Cause Analysis

### 1. Contract Design Assumption

The contract was designed assuming `ORACLE_PX` works for all markets:

```solidity
// OracleAdapterHC.sol:32-35
if (_precompile != HyperCoreConstants.ORACLE_PX_PRECOMPILE) {
    revert HyperCoreAddressMismatch(_precompile);
}
```

This hardcodes the precompile to 0x0807, which is **perp-only**.

### 2. Missing Price Scaling

The contract returns **raw uint64** values without scaling:

```solidity
// OracleAdapterHC.sol:77
return MidResult(uint256(midWord), AGE_UNKNOWN, true);
// ↑ No scaling applied!
```

But it should be:
- Spot: `midWord * 10^12` (since spot returns 10^6 units, need 10^18 for WAD)
- The contract doesn't have any scaling logic

### 3. EMA Fallback Doesn't Work

```solidity
// OracleAdapterHC.sol:107
bytes memory data = _callHyperCore(HyperCoreConstants.MARK_PX_PRECOMPILE, callData, 8);
```

MARK_PX (0x0806) returns similarly wrong values for spot markets (~$0.027 instead of ~$46).

### 4. Age Checking Impossible

Contract always returns `AGE_UNKNOWN` (max uint256):

```solidity
// OracleAdapterHC.sol:77
return MidResult(uint256(midWord), AGE_UNKNOWN, true);
```

There's no age precompile call, so freshness can't be validated.

---

## Impact on DnmPool.sol

The DnmPool contract expects OracleAdapterHC to return:
1. ✅ **Mid price in raw units** (DnmPool doesn't scale either - assumes it's already scaled)
2. ❌ **Age for freshness check** (gets AGE_UNKNOWN, so `midFresh` check fails)
3. ❌ **EMA fallback** (MARK_PX returns wrong values)

Result: DnmPool would:
1. Get $0.027 as mid price → all calculations wrong
2. Consider HC stale (age = max uint256) → try EMA fallback
3. EMA returns $0.027 again → still wrong
4. Fall back to Pyth ($46.50) → correct, but defeats the point of HC oracle

---

## Why Shadow-Bot Diverged from Contract

### Original Shadow-Bot (matched broken contract)
```typescript
const ORACLE_PX = '0x0000000000000000000000000000000000000807'; // ORACLE_PX
const ORACLE_PRICE_KEY = 150; // HYPE token ID
```
Result: $0.150 (wrong, but matches what contract would return)

### Fixed Shadow-Bot (uses correct precompiles)
```typescript
const ORACLE_PX = '0x0000000000000000000000000000000000000808'; // SPOT_PX
const ORACLE_PRICE_KEY = 107; // HYPE/USDC market ID
```
Result: $46.56 (correct, matches Pyth)

---

## The Two Paths Forward

### Option A: Fix the Contract (Recommended)

**Change OracleAdapterHC.sol to support spot markets:**

```solidity
contract OracleAdapterHC is IOracleAdapterHC {
    bool internal immutable IS_SPOT_MARKET_;

    constructor(
        address _precompile,
        bytes32 _assetIdBase,
        bytes32 _assetIdQuote,
        bytes32 _marketId,
        bool _isSpot  // <-- NEW
    ) {
        IS_SPOT_MARKET_ = _isSpot;

        // Validate correct precompile for market type
        if (_isSpot) {
            require(_precompile == HyperCoreConstants.SPOT_PX_PRECOMPILE);
        } else {
            require(_precompile == HyperCoreConstants.ORACLE_PX_PRECOMPILE);
        }
        // ...
    }

    function readMidAndAge() external view override returns (MidResult memory result) {
        address precompile = IS_SPOT_MARKET_
            ? HyperCoreConstants.SPOT_PX_PRECOMPILE  // 0x0808
            : HyperCoreConstants.ORACLE_PX_PRECOMPILE; // 0x0807

        bytes memory callData = abi.encodePacked(MARKET_KEY_);
        bytes memory data = _callHyperCore(precompile, callData, 8);

        uint64 midWord = /* decode */;

        // Scale to WAD based on market type
        uint256 scaledMid = IS_SPOT_MARKET_
            ? uint256(midWord) * 1e12  // Spot: 10^6 → 10^18
            : uint256(midWord) * 1e14; // Perp: 10^4 → 10^18

        return MidResult(scaledMid, AGE_UNKNOWN, true);
    }

    function readMidEmaFallback() external view override returns (MidResult memory result) {
        // For spot markets, EMA doesn't work - should revert or return invalid
        if (IS_SPOT_MARKET_) {
            return MidResult(0, 0, false);
        }
        // ... perp EMA logic
    }
}
```

**Benefits:**
- ✅ Contract works correctly for spot markets
- ✅ Shadow-bot already matches this behavior
- ✅ Proper price scaling
- ✅ Clear separation of spot vs perp logic

**Tradeoffs:**
- ⚠️ Requires contract redeployment
- ⚠️ EMA fallback won't work for spot (must rely on Pyth)

### Option B: Revert Shadow-Bot (Not Recommended)

Make shadow-bot match the broken contract behavior.

**Result:**
- ❌ Shadow-bot reports $0.027 for HYPE
- ❌ All metrics are wrong
- ❌ Divergence checks fail (compares $0.027 vs $46.50 Pyth)
- ❌ Pointless because contract won't work on-chain either

---

## Recommended Solution

### Immediate Actions

1. **Fix OracleAdapterHC.sol** to use SPOT_PX (0x0808) for spot markets
2. **Add price scaling** (× 10^12 for spot)
3. **Disable EMA fallback** for spot (or find working precompile)
4. **Keep shadow-bot as-is** (already correct)

### Implementation Priority

```
Priority 1 (Critical): Fix precompile selection
Priority 2 (Important): Add price scaling
Priority 3 (Nice-to-have): Research if spot has working EMA precompile
```

### Testing Verification

After fix, both contract and shadow-bot should return:
- Mid: ~$46.50 ✅
- Pyth: ~$46.50 ✅
- Divergence: <10 bps ✅
- EMA: N/A or fallback to Pyth ✅

---

## Why EMA Fallback Doesn't Work

**Direct Answer to Your Question:**

EMA fallback doesn't work for HyperLiquid spot markets because:

1. **MARK_PX (0x0806) precompile** returns values in the wrong unit range
   - Returns: ~27,000 (should be ~46,000,000)
   - Off by factor of ~1,700x

2. **No documented spot EMA precompile** exists
   - HyperCore documentation only mentions perp oracle precompiles
   - Spot markets may not have EMA/mark price concept

3. **Age checking doesn't work**
   - Contract doesn't call any age precompile
   - Always returns AGE_UNKNOWN → HC appears stale
   - Forces fallback to EMA (which is also wrong)

**Bottom Line**: For HYPE/USDC spot, you MUST use:
- Primary: SPOT_PX (0x0808)
- Fallback: Pyth (not HyperCore EMA)

Shadow-bot is already configured this way. Contract needs to match.

---

## Appendix: Full Test Results

```bash
# Precompile Exhaustive Test Results

SPOT_PX (0x0808) + market ID 107:
  Raw: 46,559,000
  Scaled (÷10^6): $46.559 ✅ CORRECT

ORACLE_PX (0x0807) + market ID 107:
  Raw: 27,737
  Scaled (÷10^6): $0.027737 ❌ WRONG

MARK_PX (0x0806) + market ID 107:
  Raw: 27,723
  Scaled (÷10^6): $0.027723 ❌ WRONG

Pyth HYPE/USD ÷ USDC/USD:
  Result: $46.571 ✅ CORRECT

Divergence: SPOT_PX vs Pyth = 2 bps ✅
```
