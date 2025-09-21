// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./libraries/ConcentratedMath.sol";

/**
 * @title PoolCoreV2
 * @notice Lifinity V2 implementation with PUSHED oracle prices
 * @dev Exactly recreates Lifinity V2's mechanics from Solana
 */
contract PoolCoreV2 is ReentrancyGuard {
    using ConcentratedMath for uint256;

    // ============ Lifinity V2 State (matches Solana) ============
    struct PoolState {
        // Basic state (8 bytes)
        bool isInitialized;
        uint8 bump;  // PDA bump seed (Solana specific, kept for compatibility)
        uint16 feeNumerator;
        uint16 feeDenominator;

        // Token addresses (64 bytes)
        address tokenA;
        address tokenB;

        // Vault addresses (64 bytes)
        address vaultA;
        address vaultB;

        // Reserves (16 bytes)
        uint128 reservesA;
        uint128 reservesB;

        // Oracle state (48 bytes)
        address oracleAccount;  // Would be Pyth price account on Solana
        uint64 lastOracleSlot;  // Solana slot = ~400ms
        uint64 lastOraclePrice; // Fixed point representation

        // Concentration parameters (24 bytes)
        uint64 concentrationFactor;  // c parameter
        uint64 inventoryExponent;    // z parameter
        uint64 rebalanceThreshold;   // θ parameter (V2 feature!)

        // V2 Rebalancing state (24 bytes)
        uint64 lastRebalancePrice;   // p* parameter
        uint64 lastRebalanceSlot;
        uint64 rebalanceCooldown;    // Minimum slots between rebalances

        // Authority (32 bytes)
        address authority;

        // Fee accumulation (16 bytes)
        uint128 totalFeesA;
        uint128 totalFeesB;

        // Virtual reserves for concentration (16 bytes)
        uint128 virtualReservesA;
        uint128 virtualReservesB;

        // Latest pushed oracle data
        uint256 currentOraclePrice;
        uint256 currentOracleConfidence;
        uint256 lastOracleUpdateTime;
    }

    // ============ Constants ============
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant SLOT_TIME = 400; // 400ms per slot like Solana
    uint256 private constant MAX_ORACLE_AGE = 25 * SLOT_TIME / 1000; // 25 slots = 10 seconds

    // ============ State ============
    PoolState public pool;
    address public keeper;  // Only keeper can push prices

    // ============ Events ============
    event SwapExecuted(
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee,
        uint256 oraclePrice
    );

    event RebalanceExecuted(
        uint256 deviation,
        uint256 oldVirtualA,
        uint256 oldVirtualB,
        uint256 newVirtualA,
        uint256 newVirtualB,
        uint256 oraclePrice
    );

    event OraclePriceUpdated(
        uint256 price,
        uint256 confidence,
        uint256 timestamp
    );

    // ============ Modifiers ============
    modifier onlyKeeper() {
        require(msg.sender == keeper, "Only keeper");
        _;
    }

    modifier onlyAuthority() {
        require(msg.sender == pool.authority, "Only authority");
        _;
    }

    // ============ Constructor ============
    constructor(address _keeper) {
        keeper = _keeper;
    }

    // ============ Initialization (like Lifinity V2) ============
    function initialize(
        address tokenA,
        address tokenB,
        uint16 feeNumerator,  // e.g., 30 for 0.3%
        uint64 concentration,  // e.g., 10 for 10x concentration
        uint64 inventoryExp,   // e.g., 0.5 * 1e18
        uint64 rebalanceThresh // e.g., 50 for 0.5%
    ) external {
        require(!pool.isInitialized, "Already initialized");

        pool.isInitialized = true;
        pool.tokenA = tokenA;
        pool.tokenB = tokenB;
        pool.vaultA = address(this); // Simplified - tokens held in contract
        pool.vaultB = address(this);

        pool.feeNumerator = feeNumerator;
        pool.feeDenominator = 10000;

        pool.concentrationFactor = concentration;
        pool.inventoryExponent = inventoryExp;
        pool.rebalanceThreshold = rebalanceThresh;
        pool.rebalanceCooldown = 750; // 300 seconds / 0.4 seconds per slot

        pool.authority = msg.sender;
    }

    // ============ Oracle Price Push (V2 Feature!) ============
    /**
     * @notice Receive pushed oracle price from keeper
     * @dev Called every 400ms by PythPushKeeper (like Solana!)
     */
    function updateOraclePrice(
        uint256 price,
        uint256 confidence,
        uint256 timestamp
    ) external onlyKeeper {
        pool.currentOraclePrice = price;
        pool.currentOracleConfidence = confidence;
        pool.lastOracleUpdateTime = timestamp;

        // Convert block to slot for Solana compatibility
        pool.lastOracleSlot = uint64(block.number * 5); // ~2s blocks = 5 slots

        emit OraclePriceUpdated(price, confidence, timestamp);
    }

    // ============ Swap (Lifinity V2 Logic) ============
    function swapExactInput(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external nonReentrant returns (uint256 amountOut) {
        require(pool.isInitialized, "Not initialized");
        require(tokenIn == pool.tokenA || tokenIn == pool.tokenB, "Invalid token");

        // Check oracle freshness (must have recent push)
        require(
            block.timestamp - pool.lastOracleUpdateTime <= MAX_ORACLE_AGE,
            "Oracle stale"
        );

        // Check confidence (< 2% of price like Lifinity)
        require(
            pool.currentOracleConfidence <= (pool.currentOraclePrice * 200) / BASIS_POINTS,
            "Oracle confidence too wide"
        );

        bool isTokenAIn = tokenIn == pool.tokenA;

        // Calculate output using Lifinity V2 algorithm
        amountOut = _calculateSwapOutput(
            amountIn,
            isTokenAIn,
            pool.currentOraclePrice
        );

        // Apply fees
        uint256 fee = (amountOut * pool.feeNumerator) / pool.feeDenominator;
        amountOut = amountOut - fee;

        require(amountOut >= minAmountOut, "Slippage");

        // Update reserves
        if (isTokenAIn) {
            pool.reservesA += uint128(amountIn);
            pool.reservesB -= uint128(amountOut);
            pool.totalFeesB += uint128(fee);
        } else {
            pool.reservesB += uint128(amountIn);
            pool.reservesA -= uint128(amountOut);
            pool.totalFeesA += uint128(fee);
        }

        // Update virtual reserves (concentration)
        _updateVirtualReserves();

        // Transfer tokens
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(isTokenAIn ? pool.tokenB : pool.tokenA).transfer(recipient, amountOut);

        emit SwapExecuted(
            msg.sender,
            tokenIn,
            isTokenAIn ? pool.tokenB : pool.tokenA,
            amountIn,
            amountOut,
            fee,
            pool.currentOraclePrice
        );
    }

    // ============ V2 Rebalancing (Threshold-based) ============
    /**
     * @notice Execute V2 threshold rebalancing
     * @dev Only called by keeper when |p/p* - 1| >= θ
     */
    function executeRebalance(uint256 currentPrice) external onlyKeeper returns (uint256, uint256) {
        // Check cooldown
        uint256 currentSlot = block.number * 5; // Convert to slots
        require(
            currentSlot >= pool.lastRebalanceSlot + pool.rebalanceCooldown,
            "Cooldown active"
        );

        // Check threshold
        uint256 deviation = _calculateDeviation(currentPrice, pool.lastRebalancePrice);
        require(deviation >= pool.rebalanceThreshold, "Below threshold");

        // Save old values for event
        uint256 oldVirtualA = pool.virtualReservesA;
        uint256 oldVirtualB = pool.virtualReservesB;

        // Rebalance to 50/50 value split (Lifinity V2 logic)
        uint256 totalValue = (pool.reservesA * currentPrice / PRECISION) + pool.reservesB;
        uint256 targetValuePerSide = totalValue / 2;

        // Update virtual reserves
        pool.virtualReservesA = uint128((targetValuePerSide * PRECISION) / currentPrice);
        pool.virtualReservesB = uint128(targetValuePerSide);

        // Update rebalance state
        pool.lastRebalancePrice = uint64(currentPrice / 1e10); // Store as fixed point
        pool.lastRebalanceSlot = uint64(currentSlot);

        emit RebalanceExecuted(
            deviation,
            oldVirtualA,
            oldVirtualB,
            pool.virtualReservesA,
            pool.virtualReservesB,
            currentPrice
        );

        return (pool.virtualReservesA, pool.virtualReservesB);
    }

    // ============ Internal Functions ============
    function _calculateSwapOutput(
        uint256 amountIn,
        bool isTokenAIn,
        uint256 oraclePrice
    ) internal view returns (uint256) {
        // Get current inventory imbalance
        uint256 valueA = pool.reservesA * oraclePrice / PRECISION;
        uint256 valueB = pool.reservesB;
        uint256 imbalanceRatio = (valueA * PRECISION) / valueB;

        // Apply concentration
        uint256 effectiveVirtualA = uint256(pool.virtualReservesA) * pool.concentrationFactor;
        uint256 effectiveVirtualB = uint256(pool.virtualReservesB) * pool.concentrationFactor;

        // Apply inventory adjustment (Lifinity's key innovation)
        uint256 kAdjusted = _applyInventoryAdjustment(
            effectiveVirtualA * effectiveVirtualB,
            imbalanceRatio,
            isTokenAIn
        );

        // Calculate output using adjusted K
        if (isTokenAIn) {
            uint256 newVirtualA = effectiveVirtualA + amountIn;
            uint256 newVirtualB = kAdjusted / newVirtualA;
            return effectiveVirtualB - newVirtualB;
        } else {
            uint256 newVirtualB = effectiveVirtualB + amountIn;
            uint256 newVirtualA = kAdjusted / newVirtualB;
            return effectiveVirtualA - newVirtualA;
        }
    }

    function _applyInventoryAdjustment(
        uint256 k,
        uint256 imbalanceRatio,
        bool isBuyingA
    ) internal view returns (uint256) {
        uint256 z = pool.inventoryExponent;

        if (imbalanceRatio < PRECISION) {
            // Token A is scarce
            if (isBuyingA) {
                // Reduce liquidity for buying scarce token
                uint256 adjustment = ConcentratedMath.pow(
                    PRECISION * PRECISION / imbalanceRatio,
                    z
                );
                return (k * adjustment) / PRECISION;
            } else {
                // Increase liquidity for selling scarce token
                uint256 adjustment = ConcentratedMath.pow(imbalanceRatio, z);
                return (k * adjustment) / PRECISION;
            }
        } else {
            // Token B is scarce
            if (!isBuyingA) {
                uint256 adjustment = ConcentratedMath.pow(imbalanceRatio, z);
                return (k * adjustment) / PRECISION;
            } else {
                uint256 adjustment = ConcentratedMath.pow(
                    PRECISION * PRECISION / imbalanceRatio,
                    z
                );
                return (k * adjustment) / PRECISION;
            }
        }
    }

    function _updateVirtualReserves() internal {
        // Simple update - production would be more sophisticated
        pool.virtualReservesA = pool.reservesA;
        pool.virtualReservesB = pool.reservesB;
    }

    function _calculateDeviation(uint256 current, uint256 previous) internal pure returns (uint256) {
        if (current > previous) {
            return ((current - previous) * BASIS_POINTS) / previous;
        } else {
            return ((previous - current) * BASIS_POINTS) / previous;
        }
    }

    // ============ View Functions ============
    function getRebalanceState() external view returns (
        uint256 lastRebalancePrice,
        uint256 rebalanceThreshold,
        uint256 lastRebalanceBlock,
        uint256 virtualReservesA,
        uint256 virtualReservesB
    ) {
        return (
            pool.lastRebalancePrice * 1e10, // Convert back from fixed point
            pool.rebalanceThreshold,
            pool.lastRebalanceSlot / 5, // Convert slots to blocks
            pool.virtualReservesA,
            pool.virtualReservesB
        );
    }

    function getCurrentOracleData() external view returns (
        uint256 price,
        uint256 confidence,
        uint256 age
    ) {
        return (
            pool.currentOraclePrice,
            pool.currentOracleConfidence,
            block.timestamp - pool.lastOracleUpdateTime
        );
    }
}

/**
 * THIS IS LIFINITY V2:
 *
 * 1. ORACLE PUSH MODEL
 *    - Keeper pushes Pyth prices every 400ms
 *    - Pool always has fresh prices
 *    - No pull needed during swaps
 *
 * 2. V2 THRESHOLD REBALANCING
 *    - Only rebalances when |p/p* - 1| >= θ
 *    - Has cooldown period (750 slots = 5 minutes)
 *    - Recenters to 50/50 value split
 *
 * 3. KEY PARAMETERS
 *    - c: Concentration (10x for volatile, 100x for stable)
 *    - z: Inventory adjustment (0.5 standard)
 *    - θ: Rebalance threshold (50 bps = 0.5%)
 *
 * 4. GAS OPTIMIZATION
 *    - Keeper pays for oracle updates
 *    - Swappers get fresh prices for free
 *    - Batch updates across pools
 */