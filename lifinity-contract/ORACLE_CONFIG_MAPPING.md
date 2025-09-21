# Lifinity V2 Oracle Configuration Mapping

## Solana → EVM Configuration Translation

### Configuration Memory Layout (from `*unaff_R7` base pointer)

```
Solana Binary Offset → Purpose → EVM Implementation
```

## 1. Confidence Thresholds

### Solana Implementation
```c
// Two confidence caps with common denominator
cfg[0x310] / cfg[0x2B8] = spot confidence cap (normal trading)
cfg[0x300] / cfg[0x2B8] = strict confidence cap (fallback/EMA)
```

### EVM Translation
```solidity
struct ConfidenceConfig {
    uint64 confCapBpsSpot;      // = (cfg[0x310] * 10000) / cfg[0x2B8]
    uint64 confCapBpsStrict;    // = (cfg[0x300] * 10000) / cfg[0x2B8]
    uint64 denominator;          // = cfg[0x2B8] if storing raw values
}

// Example values from typical deployment:
// cfg[0x310] = 75, cfg[0x2B8] = 10000 → confCapBpsSpot = 75 bps
// cfg[0x300] = 50, cfg[0x2B8] = 10000 → confCapBpsStrict = 50 bps
```

## 2. Freshness Windows

### Solana Implementation
```c
// Two slot-based timing parameters
cfg[0x2F8] = allowed lag/margin in slots (additive)
cfg[0x318] = bound/window in slots (strict maximum)

// Usage pattern in validator:
if (current_slot - oracle_slot > cfg[0x2F8]) revert("Stale");
if (cfg[0x318] < current_slot - oracle_slot) revert("Too stale");
```

### EVM Translation
```solidity
struct FreshnessConfig {
    uint32 maxAgeSec;        // = floor(cfg[0x2F8] * 0.4) // 400ms per slot
    uint32 stallWindowSec;   // = floor(cfg[0x318] * 0.4)
}

// Solana slots to seconds conversion:
// 1 slot ≈ 400ms on Solana
// So 50 slots = 20 seconds

// Example:
// cfg[0x2F8] = 37 slots → maxAgeSec = 15 seconds
// cfg[0x318] = 12 slots → stallWindowSec = 5 seconds
```

## 3. Operating Mode

### Solana Implementation
```c
// Mode/strategy selector
cfg[0x288] = operating mode enum
// 0 = strict mode (no fallback)
// 1 = normal mode (allow previous price)
// 2 = relaxed mode (allow EMA fallback)
```

### EVM Translation
```solidity
enum OracleMode {
    STRICT,      // Only accept current price with tight bounds
    NORMAL,      // Allow previous price fallback
    RELAXED      // Allow EMA fallback with looser bounds
}

// Or as boolean flags:
struct ModeConfig {
    bool allowPreviousPrice;  // cfg[0x288] >= 1
    bool allowEmaFallback;    // cfg[0x288] >= 2
}
```

## 4. Complete Oracle Configuration

### Unified EVM Structure
```solidity
struct OracleConfig {
    // Confidence thresholds (basis points)
    uint64 confCapBpsSpot;       // Normal operation threshold
    uint64 confCapBpsStrict;     // Strict/fallback threshold

    // Freshness requirements (seconds)
    uint32 maxAgeSec;            // Maximum acceptable age
    uint32 stallWindowSec;       // Tighter bound for critical ops

    // Operating mode
    bool allowEmaFallback;       // Enable EMA price fallback
    bool allowPreviousPrice;     // Enable previous price fallback

    // Optional: Store raw values for precise math
    uint256 confNumeratorSpot;   // cfg[0x310]
    uint256 confNumeratorStrict; // cfg[0x300]
    uint256 confDenominator;     // cfg[0x2B8]
}
```

## 5. Configuration Examples

### Conservative (Mainnet Blue Chips)
```solidity
OracleConfig public MAINNET_MAJORS = OracleConfig({
    confCapBpsSpot: 50,        // 0.5% confidence cap
    confCapBpsStrict: 30,       // 0.3% for fallback
    maxAgeSec: 15,              // 15 seconds max staleness
    stallWindowSec: 5,          // 5 seconds critical bound
    allowEmaFallback: true,     // Use EMA if needed
    allowPreviousPrice: true,   // Use previous if needed
    confNumeratorSpot: 50,
    confNumeratorStrict: 30,
    confDenominator: 10000
});
```

### Moderate (Mainnet Mid-Caps)
```solidity
OracleConfig public MAINNET_MIDCAPS = OracleConfig({
    confCapBpsSpot: 100,        // 1.0% confidence cap
    confCapBpsStrict: 75,        // 0.75% for fallback
    maxAgeSec: 20,               // 20 seconds max staleness
    stallWindowSec: 10,          // 10 seconds critical bound
    allowEmaFallback: true,
    allowPreviousPrice: true,
    confNumeratorSpot: 100,
    confNumeratorStrict: 75,
    confDenominator: 10000
});
```

### Relaxed (Testnet/Long-Tail)
```solidity
OracleConfig public TESTNET_CONFIG = OracleConfig({
    confCapBpsSpot: 200,         // 2.0% confidence cap
    confCapBpsStrict: 150,       // 1.5% for fallback
    maxAgeSec: 60,               // 1 minute max staleness
    stallWindowSec: 0,           // No tight bound
    allowEmaFallback: true,
    allowPreviousPrice: true,
    confNumeratorSpot: 200,
    confNumeratorStrict: 150,
    confDenominator: 10000
});
```

## 6. Validation Logic Implementation

### Complete Validator Using Config
```solidity
library OracleValidator {
    function validatePrice(
        IPyth pyth,
        bytes32 priceId,
        OracleConfig memory cfg
    ) internal view returns (ValidatedPrice memory result) {
        // Try current price first
        IPyth.Price memory price = pyth.getPriceNoOlderThan(priceId, cfg.maxAgeSec);

        // Check stall window if configured
        if (cfg.stallWindowSec > 0) {
            require(
                price.publishTime + cfg.stallWindowSec >= block.timestamp,
                "Price stalled"
            );
        }

        // Calculate relative confidence
        uint256 absPrice = abs(price.price);
        uint256 relativeConf = (uint256(price.conf) * 10000) / absPrice;

        // Check against spot threshold
        if (relativeConf <= cfg.confCapBpsSpot) {
            // Price passes with spot threshold
            return _buildResult(price, false);
        }

        // Try fallback if allowed
        if (!cfg.allowEmaFallback) {
            revert("Confidence too high");
        }

        // Try EMA with strict threshold
        IPyth.Price memory ema = pyth.getEmaPriceNoOlderThan(priceId, cfg.maxAgeSec);
        uint256 emaRelConf = (uint256(ema.conf) * 10000) / abs(ema.price);

        require(emaRelConf <= cfg.confCapBpsStrict, "EMA confidence too high");

        return _buildResult(ema, true);
    }
}
```

## 7. Dynamic Configuration Updates

### Governance-Controlled Updates
```solidity
contract ConfigurableOracle {
    mapping(address => OracleConfig) public tokenConfigs;
    address public governance;

    event ConfigUpdated(address token, OracleConfig newConfig);

    function updateConfig(
        address token,
        OracleConfig calldata newConfig
    ) external onlyGovernance {
        // Validate config sanity
        require(newConfig.confCapBpsSpot <= 1000, "Spot cap too high");  // Max 10%
        require(newConfig.confCapBpsStrict <= newConfig.confCapBpsSpot, "Strict must be tighter");
        require(newConfig.maxAgeSec >= 5 && newConfig.maxAgeSec <= 300, "Age out of range");

        tokenConfigs[token] = newConfig;
        emit ConfigUpdated(token, newConfig);
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "Not governance");
        _;
    }
}
```

## 8. Chain-Specific Adjustments

### Ethereum Mainnet
```solidity
// 12-second blocks, high security
maxAgeSec = 15;  // Just over 1 block
stallWindowSec = 6;  // Half block
```

### Polygon
```solidity
// 2-second blocks, medium security
maxAgeSec = 10;  // 5 blocks
stallWindowSec = 4;  // 2 blocks
```

### Arbitrum
```solidity
// Sub-second blocks, different timing
maxAgeSec = 20;  // Account for sequencer
stallWindowSec = 5;
```

### BSC
```solidity
// 3-second blocks
maxAgeSec = 12;  // 4 blocks
stallWindowSec = 6;  // 2 blocks
```

## 9. Monitoring & Alerts

### Config Health Metrics
```solidity
event OracleHealthCheck(
    address token,
    uint256 priceAge,
    uint256 confidenceBps,
    bool usedFallback,
    bool passedStallCheck
);

function monitorOracleHealth() external view returns (HealthStatus memory) {
    // Check how often fallbacks are used
    // Track average confidence levels
    // Monitor price staleness distribution
    // Alert if config seems too tight/loose
}
```

## 10. Migration from Solana Values

### Direct Conversion Script
```javascript
// Input: Solana config values
const solanaConfig = {
    0x288: 2,      // Mode: relaxed
    0x2B8: 10000,  // Denominator
    0x2F8: 50,     // Lag slots
    0x300: 50,     // Strict numerator
    0x310: 75,     // Spot numerator
    0x318: 25      // Bound slots
};

// Output: EVM config
const evmConfig = {
    confCapBpsSpot: (solanaConfig[0x310] * 10000) / solanaConfig[0x2B8],
    confCapBpsStrict: (solanaConfig[0x300] * 10000) / solanaConfig[0x2B8],
    maxAgeSec: Math.floor(solanaConfig[0x2F8] * 0.4),
    stallWindowSec: Math.floor(solanaConfig[0x318] * 0.4),
    allowEmaFallback: solanaConfig[0x288] >= 2,
    allowPreviousPrice: solanaConfig[0x288] >= 1
};

console.log(evmConfig);
// {
//   confCapBpsSpot: 75,
//   confCapBpsStrict: 50,
//   maxAgeSec: 20,
//   stallWindowSec: 10,
//   allowEmaFallback: true,
//   allowPreviousPrice: true
// }
```

## Summary

The Lifinity V2 oracle configuration system provides:
1. **Dual confidence thresholds** - Normal and strict modes
2. **Dual freshness windows** - Standard and critical timing
3. **Flexible fallback options** - Previous price and EMA
4. **Mode-based operation** - Strict/Normal/Relaxed

For EVM implementation:
- Store configuration per token or per pool
- Allow governance updates with sanity checks
- Monitor configuration effectiveness
- Adjust for chain-specific characteristics

---

*This mapping provides exact translation from Solana binary offsets to EVM configuration*
*Use this as reference when deploying Lifinity V2 logic to EVM chains*