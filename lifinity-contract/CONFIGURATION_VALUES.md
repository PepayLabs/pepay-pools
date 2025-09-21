# Lifinity V2 Configuration Values

## Actual Configuration Parameters

While the exact values aren't hardcoded in the binary (they're loaded from state), here are the typical/recommended values based on DeFi standards and the Lifinity model:

## 1. Confidence Thresholds

### Standard Configuration (Major Pairs)
```solidity
// Raw values (as stored in Solana state)
cfg[0x310] = 75;        // Spot confidence cap numerator
cfg[0x300] = 50;        // Strict/EMA confidence cap numerator
cfg[0x2B8] = 10000;     // Common denominator

// Calculated BPS values
confCapBpsSpot = 75;    // (75 * 10000) / 10000 = 75 bps = 0.75%
confCapBpsStrict = 50;  // (50 * 10000) / 10000 = 50 bps = 0.50%
```

### Conservative Configuration (Stablecoins)
```solidity
// Raw values
cfg[0x310] = 30;        // Spot confidence cap numerator
cfg[0x300] = 20;        // Strict confidence cap numerator
cfg[0x2B8] = 10000;     // Common denominator

// Calculated BPS
confCapBpsSpot = 30;    // 0.30% for stables
confCapBpsStrict = 20;  // 0.20% for EMA fallback
```

### Aggressive Configuration (Exotic Pairs)
```solidity
// Raw values
cfg[0x310] = 150;       // Spot confidence cap numerator
cfg[0x300] = 100;       // Strict confidence cap numerator
cfg[0x2B8] = 10000;     // Common denominator

// Calculated BPS
confCapBpsSpot = 150;   // 1.50% for volatile/exotic
confCapBpsStrict = 100; // 1.00% for fallback
```

## 2. Freshness Windows

### Standard Timing (Solana slots)
```solidity
// Raw values (in Solana slots)
cfg[0x2F8] = 50;        // Allowed lag (50 slots ≈ 20 seconds)
cfg[0x318] = 25;        // Strict bound (25 slots ≈ 10 seconds)

// Converted to seconds (1 slot ≈ 400ms on Solana)
maxAgeSec = 20;         // floor(50 * 0.4)
stallWindowSec = 10;    // floor(25 * 0.4)
```

### Fast Updates (High-Frequency Trading)
```solidity
// Raw values
cfg[0x2F8] = 12;        // 12 slots ≈ 5 seconds
cfg[0x318] = 6;         // 6 slots ≈ 2.4 seconds

// Converted to seconds
maxAgeSec = 5;
stallWindowSec = 2;
```

### Relaxed Timing (Low Activity Pairs)
```solidity
// Raw values
cfg[0x2F8] = 150;       // 150 slots ≈ 60 seconds
cfg[0x318] = 75;        // 75 slots ≈ 30 seconds

// Converted to seconds
maxAgeSec = 60;
stallWindowSec = 30;
```

## 3. Operating Mode

```solidity
cfg[0x288] = 2;         // Operating mode enum

// Mode interpretations:
// 0 = STRICT_MODE    - Only current price, no fallbacks
// 1 = NORMAL_MODE    - Allow previous price fallback
// 2 = RELAXED_MODE   - Allow EMA fallback (recommended)
```

## 4. Complete Configuration Examples

### Production Mainnet (BNB/USDT)
```javascript
const MAINNET_BNB_USDT = {
    // Confidence (in BPS)
    confCapBpsSpot: 75,        // 0.75% confidence cap
    confCapBpsStrict: 50,      // 0.50% for fallback

    // Freshness (in seconds)
    maxAgeSec: 15,              // 15 second maximum age
    stallWindowSec: 5,          // 5 second critical window

    // Mode
    allowEmaFallback: true,     // cfg[0x288] = 2
    allowPreviousPrice: true,

    // Raw Solana values
    raw: {
        0x310: 75,              // Spot numerator
        0x300: 50,              // Strict numerator
        0x2B8: 10000,           // Denominator
        0x2F8: 37,              // Lag slots (37 * 0.4 ≈ 15s)
        0x318: 12,              // Bound slots (12 * 0.4 ≈ 5s)
        0x288: 2                // Mode
    }
};
```

### Production Mainnet (USDT/USDC Stablecoin)
```javascript
const MAINNET_STABLE_PAIR = {
    // Confidence (tighter for stables)
    confCapBpsSpot: 25,         // 0.25% confidence cap
    confCapBpsStrict: 15,       // 0.15% for fallback

    // Freshness (can be slightly relaxed for stables)
    maxAgeSec: 20,              // 20 second maximum
    stallWindowSec: 10,         // 10 second critical

    // Mode
    allowEmaFallback: true,
    allowPreviousPrice: true,

    // Raw Solana values
    raw: {
        0x310: 25,
        0x300: 15,
        0x2B8: 10000,
        0x2F8: 50,              // 50 * 0.4 = 20s
        0x318: 25,              // 25 * 0.4 = 10s
        0x288: 2
    }
};
```

### Production Mainnet (FDUSD New Stablecoin)
```javascript
const MAINNET_FDUSD = {
    // Slightly looser for new stablecoin
    confCapBpsSpot: 40,         // 0.40% confidence
    confCapBpsStrict: 25,       // 0.25% fallback

    // Standard freshness
    maxAgeSec: 15,
    stallWindowSec: 5,

    // Mode
    allowEmaFallback: true,
    allowPreviousPrice: true,

    // Raw values
    raw: {
        0x310: 40,
        0x300: 25,
        0x2B8: 10000,
        0x2F8: 37,
        0x318: 12,
        0x288: 2
    }
};
```

## 5. Dynamic Fee Parameters (Inferred)

Based on the market analysis and typical AMM parameters:

```solidity
// Base fees (in basis points)
BASE_FEE_STABLE = 10;           // 0.10% for stablecoin pairs
BASE_FEE_MAJOR = 25;            // 0.25% for major pairs
BASE_FEE_EXOTIC = 100;          // 1.00% for exotic pairs

// Dynamic adjustments
VOLATILITY_FACTOR = 2;          // 2x multiplier per 100 bps confidence
INVENTORY_FACTOR = 1;           // 1x multiplier per 10% imbalance
MAX_FEE_BPS = 300;             // 3% maximum fee cap

// Inventory thresholds
TARGET_RATIO = 5000;            // 50% target inventory (in bps)
REBALANCE_THRESHOLD = 500;      // 5% deviation triggers rebalance
MAX_IMBALANCE = 2000;          // 20% maximum allowed imbalance
```

## 6. EVM Chain-Specific Adjustments

### Ethereum Mainnet
```solidity
OracleConfig memory ETH_CONFIG = OracleConfig({
    confCapBpsSpot: 50,         // Tighter due to higher gas costs
    confCapBpsStrict: 30,
    maxAgeSec: 15,              // Account for 12s blocks
    stallWindowSec: 6,          // Half block time
    allowEmaFallback: true
});
```

### BNB Smart Chain
```solidity
OracleConfig memory BSC_CONFIG = OracleConfig({
    confCapBpsSpot: 75,         // Standard config
    confCapBpsStrict: 50,
    maxAgeSec: 12,              // 3s blocks, so 4 blocks
    stallWindowSec: 6,          // 2 blocks
    allowEmaFallback: true
});
```

### Polygon
```solidity
OracleConfig memory POLYGON_CONFIG = OracleConfig({
    confCapBpsSpot: 100,        // Slightly looser for faster chain
    confCapBpsStrict: 75,
    maxAgeSec: 10,              // 2s blocks, so 5 blocks
    stallWindowSec: 4,          // 2 blocks
    allowEmaFallback: true
});
```

### Arbitrum
```solidity
OracleConfig memory ARBITRUM_CONFIG = OracleConfig({
    confCapBpsSpot: 60,         // Tighter for L2
    confCapBpsStrict: 40,
    maxAgeSec: 20,              // Account for sequencer
    stallWindowSec: 5,
    allowEmaFallback: true
});
```

## 7. Validation Formulas

### Confidence Check
```
conf/|price| ≤ threshold
// Where threshold = cfg[0x310]/cfg[0x2B8] for spot
//                 = cfg[0x300]/cfg[0x2B8] for strict
```

### Freshness Check
```
current_slot - oracle_valid_slot ≤ cfg[0x2F8]
// And optionally:
current_slot - oracle_valid_slot ≤ cfg[0x318]
```

### Mode Check
```
if (cfg[0x288] >= 2) allowEmaFallback = true
if (cfg[0x288] >= 1) allowPreviousPrice = true
```

## 8. Recommended Starting Values

For a new deployment on EVM, start with these conservative values:

```solidity
contract LifinityConfig {
    // Start conservative, can adjust via governance
    uint64 public constant CONF_CAP_BPS_SPOT = 100;      // 1%
    uint64 public constant CONF_CAP_BPS_STRICT = 75;     // 0.75%
    uint32 public constant MAX_AGE_SEC = 30;             // 30 seconds
    uint32 public constant STALL_WINDOW_SEC = 15;        // 15 seconds
    bool public constant ALLOW_EMA_FALLBACK = true;

    // Can be made updateable by admin
    mapping(address => uint64) public pairConfCapSpot;
    mapping(address => uint64) public pairConfCapStrict;
    mapping(address => uint32) public pairMaxAge;
}
```

## Notes

1. **These values are inferred** from typical DeFi parameters and Lifinity's design philosophy
2. **Actual production values** would be loaded from on-chain state accounts
3. **Values should be tuned** based on:
   - Asset volatility
   - Oracle quality
   - Chain characteristics
   - Risk tolerance
4. **Dynamic adjustment** recommended based on market conditions
5. **Monitor and iterate** - start conservative, optimize based on data

## Testing Recommendations

Before mainnet deployment, test these configurations:
1. Normal market conditions (75 bps confidence, 15s freshness)
2. High volatility (150+ bps confidence)
3. Oracle delays (30+ second staleness)
4. Rapid price movements (10%+ in seconds)
5. Stablecoin depegs (0.1%+ deviation)
6. Network congestion (delayed oracle updates)

---

*These values represent industry standards and best practices for oracle-based AMMs*
*Actual Lifinity values may differ and should be verified on-chain*