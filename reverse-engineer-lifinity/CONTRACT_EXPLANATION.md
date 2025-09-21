# Lifinity V2 EVM Contracts - Complete Explanation

## 🎯 Overview
The contracts implement Lifinity's oracle-anchored AMM with three key innovations:
1. **Oracle-anchored pricing** - Swap prices follow external oracle
2. **Concentrated liquidity** - Virtual reserves multiplied by factor `c`
3. **Inventory management** - Asymmetric liquidity based on pool balance

---

## 📊 PoolCore.sol - Main AMM Contract

### State Variables

```solidity
struct PoolState {
    bool isInitialized;           // Pool active flag
    uint16 feeNumerator;          // Fee in basis points (30 = 0.3%)

    address tokenA;               // First token address
    address tokenB;               // Second token address

    uint256 reservesA;            // Actual token A balance
    uint256 reservesB;            // Actual token B balance

    uint256 virtualReservesA;     // reservesA * concentration factor
    uint256 virtualReservesB;     // reservesB * concentration factor

    uint256 concentrationFactor;  // c parameter (10-1000x)
    uint256 inventoryExponent;    // z parameter (0.2-1.0)
    uint256 rebalanceThreshold;   // θ parameter (25-100 bps)

    uint256 lastRebalancePrice;   // p* - price at last rebalance
    uint256 lastRebalanceBlock;   // Block of last rebalance

    uint256 totalFeesA;           // Accumulated fees in token A
    uint256 totalFeesB;           // Accumulated fees in token B
}
```

### Core Swap Function

```solidity
function swapExactInput() {
    // Step 1: Get oracle price
    (uint256 oraclePrice, uint256 confidence) = oracle.getPrice(tokenA, tokenB);

    // Step 2: Validate oracle
    // - Check freshness (< 25 blocks old)
    // - Check confidence (< 2% of price)

    // Step 3: Check if rebalancing needed
    if (|currentPrice/lastRebalancePrice - 1| > threshold) {
        rebalance();
    }

    // Step 4: Calculate swap output
    // Uses concentrated constant product: K = c * x * y
    amountOut = calculateOutput(amountIn, oraclePrice);

    // Step 5: Apply inventory adjustment
    // If pool imbalanced, adjust K up or down
    amountOut = applyInventoryAdjustment(amountOut);

    // Step 6: Deduct fees
    fee = amountOut * feeNumerator / 10000;
    amountOut = amountOut - fee;

    // Step 7: Transfer tokens
}
```

### Concentrated Liquidity Math

```solidity
// Virtual reserves = actual reserves * concentration
virtualReservesA = reservesA * concentrationFactor;
virtualReservesB = reservesB * concentrationFactor;

// Higher concentration = deeper liquidity near oracle price
// c = 10: Normal liquidity
// c = 100: 100x deeper liquidity (less slippage)
// c = 1000: Ultra-concentrated (minimal slippage)
```

### Inventory Adjustment

```solidity
function _applyInventoryAdjustment() {
    // Calculate pool imbalance
    valueA = reservesA * oraclePrice;
    valueB = reservesB;
    imbalanceRatio = valueA / valueB;

    if (imbalanceRatio < 1) {
        // Token A is scarce (valuable)
        if (buying_A) {
            // Make it expensive to buy scarce token
            // Reduce effective liquidity → higher slippage
            K = K * (valueB/valueA)^z;
        } else {
            // Make it cheap to sell scarce token
            // Increase effective liquidity → lower slippage
            K = K * (valueA/valueB)^z;
        }
    }
}

// z = 0.5: Moderate adjustment
// z = 1.0: Strong adjustment
```

### V2 Rebalancing Logic

```solidity
function _checkAndRebalance() {
    // Only rebalance if:
    // 1. Cooldown passed (300 blocks)
    // 2. Price deviation > threshold

    deviation = abs(currentPrice/lastRebalancePrice - 1);

    if (deviation > threshold) {
        // Reset to 50/50 value split
        totalValue = reservesA * price + reservesB;
        targetValue = totalValue / 2;

        virtualReservesA = targetValue / price;
        virtualReservesB = targetValue;

        lastRebalancePrice = currentPrice;
    }
}

// θ = 50 bps: Rebalance when price moves 0.5%
// θ = 100 bps: Rebalance when price moves 1%
```

---

## 🔮 Why Pyth is Better for This Design

### Chainlink vs Pyth Comparison

| Feature | Chainlink | Pyth | Impact on Lifinity |
|---------|-----------|------|-------------------|
| Update Frequency | 0.5-2% deviation or 3600s | 400ms (every slot) | ✅ Pyth: Better for oracle-anchored AMM |
| Latency | 10-30 seconds | <1 second | ✅ Pyth: Tighter spreads possible |
| Confidence Intervals | No | Yes | ✅ Pyth: Native confidence for spread calculation |
| Price Model | Pull (onchain query) | Push (offchain data) | ✅ Pyth: More gas efficient |
| Cost | Free reads | ~0.001 ETH per update | ⚠️ Chainlink: No update costs |

### Why Pyth is Ideal for Lifinity

1. **Frequent Updates**: Oracle-anchored AMMs need fresh prices constantly
2. **Confidence Intervals**: Lifinity uses confidence for dynamic spreads
3. **Low Latency**: Enables tighter tracking of real market prices
4. **Cross-chain**: Same price on all chains (Solana, EVM, etc.)

---

## 📈 Parameter Effects on Pool Behavior

### Concentration Factor (c)

```
Low c (1-10):
├── Wide liquidity distribution
├── Higher slippage
└── Good for volatile pairs

Medium c (10-100):
├── Moderate concentration
├── Balanced slippage
└── Good for major pairs

High c (100-1000):
├── Ultra-concentrated
├── Minimal slippage
└── Good for stablecoins
```

### Inventory Exponent (z)

```
Low z (0.2-0.4):
├── Gentle rebalancing
├── Accepts imbalance
└── Lower IL protection

Medium z (0.4-0.7):
├── Moderate rebalancing
├── Balanced approach
└── Standard protection

High z (0.7-1.0):
├── Aggressive rebalancing
├── Fights imbalance
└── Maximum IL protection
```

### Rebalance Threshold (θ)

```
Tight θ (10-25 bps):
├── Frequent rebalancing
├── Tracks oracle closely
├── Higher gas costs
└── Best for stables

Medium θ (25-50 bps):
├── Balanced approach
├── Reasonable gas costs
└── Good for majors

Wide θ (50-100 bps):
├── Rare rebalancing
├── Lower gas costs
├── Accepts drift
└── Good for volatiles
```

---

## 🔧 Contract Flow Diagram

```
User calls swap()
    │
    ▼
Get Oracle Price ◄──── Pyth/Chainlink
    │
    ▼
Validate Freshness
    │
    ▼
Check Rebalance Need
    │
    ├─Yes─► Rebalance Virtual Reserves
    │              │
    ▼              ▼
Calculate Output Amount
    │
    ▼
Apply Inventory Adjustment
    │
    ▼
Deduct Fees
    │
    ▼
Transfer Tokens
```

---

## 🎯 Key Insights

### What Makes This Different

1. **NOT a standard AMM**: Doesn't use x*y=k alone
2. **Oracle First**: Price comes from oracle, not reserves
3. **Dynamic Liquidity**: K changes based on inventory
4. **Automated Rebalancing**: Recenters when price drifts

### Benefits

- **Reduced IL**: Oracle anchoring prevents adverse selection
- **Better Pricing**: Tracks real market prices
- **Capital Efficiency**: Concentration multiplies liquidity
- **MEV Resistant**: Oracle price limits sandwich attacks

### Challenges for EVM

- **Gas Costs**: Oracle updates + rebalancing expensive
- **Oracle Latency**: Pyth needs manual updates on EVM
- **Keeper Infrastructure**: Automated rebalancing required
- **State Storage**: 304 bytes of state costs more on EVM