# Lifinity V2 Complete Research Documentation

## Table of Contents
1. [Oracle Architecture](#oracle-architecture)
2. [Configuration Parameters](#configuration-parameters)
3. [Swap Processing Flow](#swap-processing-flow)
4. [Mathematical Operations](#mathematical-operations)
5. [Missing Components for EVM](#missing-components-for-evm)
6. [Implementation Roadmap](#implementation-roadmap)

---

## Oracle Architecture

### 1. Three-Layer Oracle Validation System

#### Layer 1: Header Authentication (`parse_pyth_header @ 0x4a2f0`)
```c
// Validates Pyth v2 price account structure
Magic Number: 0xA1B2C3D4 (Pyth v2 signature)
Version: 2 (must match exactly)
Account Type: 3 (PRICE account only)
```

#### Layer 2: Market State Validation
```c
// Trading status check
status = *(u32*)(oracle + 0xE0);
if (status != 1) {  // 1 = TRADING
    // Fallback to previous price at +0xB8
    // Or reject trade entirely
}
```

#### Layer 3: Data Quality Gates
- **Freshness Gate**: Price must be within acceptable slot lag
- **Confidence Gate**: Relative confidence must be below threshold
- **Zero Price Check**: Prevents division by zero

### 2. Pyth Price Account Memory Layout
```
Offset    Field                    Type      Description
----------------------------------------------------------------------
+0x00     Header/Magic            bytes4    Pyth signature
+0x04     Version                 u32       Must be 2
+0x08     Type                    u32       Must be 3 (PRICE)
+0x14     Exponent                i32       Decimal scaling factor
+0x28     Valid Slot              u64       Last update slot
+0xB8     Previous Price          i64       Fallback aggregate price
+0xD0     Current Agg Price       i64       Primary price value
+0xD8     Confidence Interval     u64       Price uncertainty
+0xE0     Trading Status          u32       1=TRADING, others=halted
```

### 3. Oracle Validation Flow (`FUN_ram_0001ec88`)

**Complete validation sequence:**
1. Parse Pyth header → Verify magic/version/type
2. Check trading status → Ensure market is active
3. Validate freshness → Compare valid_slot vs Clock.slot
4. Check confidence band → Ensure conf/|price| ≤ threshold
5. Select price source → Current (0xD0) or Previous (0xB8)

---

## Configuration Parameters

### Memory Map (from `*unaff_R7` base pointer)

| Offset | Purpose | EVM Mapping |
|--------|---------|-------------|
| `+0x288` | Mode/Strategy Toggle | `allowEmaFallback` boolean |
| `+0x2B8` | Common Denominator | Base for BPS calculations |
| `+0x2F8` | Age Allowance (slots) | `maxAgeSec` (slots × 0.4) |
| `+0x300` | Strict Conf Cap Numerator | `confCapBpsStrict` |
| `+0x310` | Spot Conf Cap Numerator | `confCapBpsSpot` |
| `+0x318` | Stall Window (slots) | `stallWindowSec` (optional) |

### Threshold Calculations

**Confidence Caps (in basis points):**
```
confCapBpsSpot = (cfg[0x310] * 10_000) / cfg[0x2B8]
confCapBpsStrict = (cfg[0x300] * 10_000) / cfg[0x2B8]
```

**Freshness Windows (convert slots to seconds):**
```
maxAgeSec = floor(cfg[0x2F8] * 0.4)       // Primary freshness
stallWindowSec = floor(cfg[0x318] * 0.4)  // Tighter bound
```

**Mode Settings:**
```
allowEmaFallback = (cfg[0x288] != 0)  // Enable fallback logic
```

---

## Swap Processing Flow

### 1. Entry Point Chain
```
entrypoint (0x30320)
    ↓ [dispatch by instruction discriminant]
instruction_dispatcher (0x10f10)
    ↓ [route to swap handler]
swap_handler (0x16910)
    ↓ [prepare swap context]
oracle_pre_setup (0x1e910)
    ↓ [validate oracle data]
oracle_validator (0x1ec88)
    ↓ [execute swap logic]
process_swap_accounts (0x30880)
```

### 2. Core Swap Function (`process_swap_accounts @ 0x30880`)

**Key Operations:**
1. **Account Validation** - Verify all accounts (pool, user tokens, oracles)
2. **Oracle Price Fetch** - Get validated prices for both tokens
3. **Swap Calculation** - Compute output amounts using oracle prices
4. **Slippage Check** - Ensure execution within acceptable bounds
5. **Token Transfer** - Execute the actual token movements
6. **State Update** - Update pool reserves and fee accumulation

### 3. Key Mathematical Functions Identified

| Function Address | Purpose | Parameters |
|-----------------|---------|------------|
| `FUN_ram_00070160` | Division with remainder | (numerator, divisor) → quotient |
| `FUN_ram_00072340` | Multiplication (u128) | (a, b) → product |
| `FUN_ram_000726b8` | To big integer | (value) → bigint |
| `FUN_ram_00072960` | Absolute value | (signed) → unsigned |
| `FUN_ram_0006ce80` | Ratio calculation | (num, denom) → ratio |
| `FUN_ram_000725a8` | Compare ratios | (ratio1, ratio2) → comparison |

---

## Mathematical Operations

### 1. Oracle Price Calculation
```python
# Convert oracle price to execution price
oracle_rate = price_A / price_B * (10^(expo_A - expo_B))

# Apply confidence-based slippage
slippage = (conf_A / |price_A|) + (conf_B / |price_B|)
execution_price = oracle_rate * (1 ± slippage * fee_multiplier)
```

### 2. Swap Amount Calculation
```python
# Oracle-guided swap (not x*y=k)
def calculate_swap_output(amount_in, oracle_price, fee_bps, reserves):
    # Base calculation
    output_before_fee = amount_in * oracle_price

    # Apply dynamic fee
    fee = output_before_fee * fee_bps / 10000
    output_after_fee = output_before_fee - fee

    # Check reserves sufficiency
    if output_after_fee > reserves_out:
        revert("Insufficient liquidity")

    return output_after_fee
```

### 3. Dynamic Fee Adjustment (Inferred)
```python
def calculate_dynamic_fee(base_fee_bps, volatility, inventory_ratio):
    # Volatility adjustment from oracle confidence
    vol_multiplier = 1 + (confidence / price) * VOL_FACTOR

    # Inventory imbalance adjustment
    imbalance = abs(0.5 - inventory_ratio)
    inv_multiplier = 1 + imbalance * INV_FACTOR

    # Final fee
    return base_fee_bps * vol_multiplier * inv_multiplier
```

### 4. Liquidity Concentration
Instead of providing liquidity across entire range (Uniswap V2) or ticks (V3), Lifinity:
- **Centers all liquidity at oracle price**
- **No need for tick math or range positions**
- **Instant rebalancing as oracle moves**

---

## Missing Components for EVM

### 1. Core Infrastructure Gaps

| Component | Solana Implementation | EVM Requirement |
|-----------|---------------------|-----------------|
| **Clock Sysvar** | Native Solana sysvar | `block.timestamp` |
| **Slot-based timing** | Solana slots (400ms) | Block time (12s ETH, varies) |
| **Program Derived Addresses** | PDA for deterministic addresses | CREATE2 or registry pattern |
| **Account Data Layout** | Borsh serialization | Struct packing + storage slots |
| **Instruction Data** | Discriminant + packed data | Function selector + ABI encoding |

### 2. Oracle Integration Differences

| Aspect | Solana (Pyth) | EVM (Pyth) |
|--------|--------------|------------|
| **Account Model** | Separate account per price | Contract with price IDs |
| **Data Access** | Direct memory read | Contract calls |
| **Update Model** | Oracle updates account | Push or pull updates |
| **Freshness** | Slot-based | Timestamp-based |

### 3. Mathematical Library Requirements

**Need to implement:**
```solidity
library LifinityMath {
    // Unsigned 128-bit multiplication
    function mulU128(uint128 a, uint128 b) returns (uint256);

    // Division with remainder
    function divmod(uint256 num, uint256 denom) returns (uint256 quotient, uint256 remainder);

    // Safe ratio comparison (avoids overflow)
    function compareRatios(uint256 num1, uint256 denom1, uint256 num2, uint256 denom2) returns (int8);

    // Absolute value for signed integers
    function abs(int256 value) returns (uint256);

    // Scale by exponent difference
    function scaleByExponent(uint256 value, int32 fromExpo, int32 toExpo) returns (uint256);
}
```

### 4. State Management Patterns

**Solana Pattern:**
```rust
// Accounts passed as parameters
pub struct SwapAccounts<'info> {
    pool: Account<'info, Pool>,
    oracle_a: Account<'info, PriceAccount>,
    oracle_b: Account<'info, PriceAccount>,
    user_token_a: Account<'info, TokenAccount>,
    // ... etc
}
```

**EVM Equivalent:**
```solidity
// State stored in contract
struct Pool {
    address tokenA;
    address tokenB;
    bytes32 oracleIdA;
    bytes32 oracleIdB;
    uint256 reserveA;
    uint256 reserveB;
    OracleConfig config;
}

mapping(bytes32 => Pool) public pools;
```

### 5. Security Considerations

| Risk | Mitigation Strategy |
|------|-------------------|
| **Oracle Manipulation** | Multi-oracle aggregation, confidence bands |
| **MEV Attacks** | Commit-reveal, time-weighted prices |
| **Reentrancy** | Checks-effects-interactions, reentrancy guards |
| **Integer Overflow** | Safe math libraries, Solidity 0.8+ |
| **Access Control** | Role-based permissions, timelocks |

---

## Implementation Roadmap

### Phase 1: Core Oracle Integration ✅
```solidity
library PythValidator {
    struct OracleConfig {
        uint64 confCapBpsSpot;      // Primary confidence cap
        uint64 confCapBpsStrict;    // Fallback confidence cap
        uint32 maxAgeSec;           // Maximum price age
        uint32 stallWindowSec;      // Tighter freshness bound
        bool allowEmaFallback;      // Enable EMA fallback
    }

    function readAndValidate(
        IPyth pyth,
        bytes32 priceId,
        OracleConfig memory cfg
    ) returns (ValidatedPrice memory);
}
```

### Phase 2: AMM Core Logic 🔄
```solidity
contract LifinityV2Pool {
    // Oracle-guided swap calculation
    function calculateSwapOutput(
        uint256 amountIn,
        ValidatedPrice memory priceIn,
        ValidatedPrice memory priceOut,
        PoolState memory state
    ) returns (uint256 amountOut, uint256 fee);

    // Dynamic fee adjustment
    function calculateDynamicFee(
        uint256 baseFee,
        uint256 confidence,
        uint256 inventoryRatio
    ) returns (uint256);
}
```

### Phase 3: Liquidity Management 📊
```solidity
interface ILifinityLiquidity {
    // Add liquidity centered at oracle price
    function addLiquidity(
        uint256 amountA,
        uint256 amountB,
        uint256 minLP
    ) returns (uint256 lpTokens);

    // Remove with oracle-based valuation
    function removeLiquidity(
        uint256 lpTokens,
        uint256 minA,
        uint256 minB
    ) returns (uint256 amountA, uint256 amountB);
}
```

### Phase 4: Risk Management 🛡️
```solidity
contract RiskManager {
    // Circuit breakers
    function checkVolatilityBounds(uint256 confidence) returns (bool);
    function checkInventoryLimits(uint256 ratio) returns (bool);
    function emergencyPause() external onlyOwner;

    // MEV protection
    function commitSwap(bytes32 commitment) external;
    function revealSwap(uint256 nonce, SwapParams memory params) external;
}
```

### Phase 5: Optimization & Gas Efficiency ⚡
- Pack structs efficiently
- Use assembly for hot paths
- Implement multicall patterns
- Cache oracle prices within block

---

## Testing Requirements

### 1. Unit Tests
- [ ] Oracle validation with edge cases
- [ ] Math library precision tests
- [ ] Fee calculation scenarios
- [ ] Slippage protection boundaries

### 2. Integration Tests
- [ ] End-to-end swap flows
- [ ] Multi-hop routing
- [ ] Liquidity operations
- [ ] Oracle failure handling

### 3. Invariant Tests
- [ ] No token creation/destruction
- [ ] Fee accumulation correctness
- [ ] LP token valuation consistency
- [ ] Reserve balance integrity

### 4. Security Audits
- [ ] Formal verification of math
- [ ] Economic attack simulations
- [ ] Oracle manipulation attempts
- [ ] MEV resistance validation

---

## Configuration Recommendations

### Mainnet (Conservative)
```solidity
OracleConfig mainnetConfig = OracleConfig({
    confCapBpsSpot: 50,        // 0.5% for majors
    confCapBpsStrict: 30,       // 0.3% for fallback
    maxAgeSec: 20,              // 20 seconds max age
    stallWindowSec: 10,         // 10 seconds tight bound
    allowEmaFallback: true      // Enable EMA fallback
});
```

### Testnet (Relaxed)
```solidity
OracleConfig testnetConfig = OracleConfig({
    confCapBpsSpot: 200,        // 2% for testing
    confCapBpsStrict: 150,      // 1.5% for fallback
    maxAgeSec: 60,              // 1 minute max age
    stallWindowSec: 0,          // No tight bound
    allowEmaFallback: true      // Enable EMA fallback
});
```

---

## Appendix: Function Address Reference

| Address | Function | Purpose |
|---------|----------|---------|
| `0x00030320` | entrypoint | Solana BPF entry point |
| `0x00010f10` | instruction_dispatcher | Routes instructions |
| `0x00016910` | swap_handler | Main swap logic |
| `0x0001e910` | oracle_pre_setup | Pre-oracle validation |
| `0x0001ec88` | oracle_validator | Core oracle validation |
| `0x00030880` | process_swap_accounts | Execute swap |
| `0x0004a2f0` | parse_pyth_header | Pyth header validation |
| `0x00070160` | div_with_remainder | Division operation |
| `0x00072340` | mul_u128 | 128-bit multiplication |
| `0x000726b8` | to_bigint | Convert to big integer |
| `0x00072960` | abs_value | Absolute value |
| `0x0006ce80` | calc_ratio | Ratio calculation |
| `0x000725a8` | compare_ratios | Ratio comparison |

---

## Next Steps

1. **Immediate**: Implement PythValidator library with both confidence caps
2. **Week 1**: Build core swap math with oracle integration
3. **Week 2**: Add liquidity management and LP tokens
4. **Week 3**: Implement risk controls and circuit breakers
5. **Week 4**: Comprehensive testing suite
6. **Month 2**: Audit preparation and optimizations

---

## Notes for Implementation Team

- The Solana version uses big integer math extensively - ensure precision in EVM
- Oracle freshness is critical - never accept stale prices
- The confidence band mechanism is the key to risk management
- Consider using a factory pattern for pool deployment
- Implement comprehensive event logging for debugging
- Plan for upgradability with proxy patterns or immutable deployments

---

*Document Version: 1.0*
*Last Updated: Based on Lifinity V2 decompiled analysis*
*Status: Research Complete - Ready for Implementation Planning*