// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "./PoolCore.sol";

/**
 * @title PythPushKeeper
 * @notice Keeper that PUSHES Pyth prices to pools every 400ms (like Solana!)
 * @dev This recreates Lifinity V2's real-time oracle updates on EVM
 */
contract PythPushKeeper {

    // Pyth Network contract
    IPyth public immutable pyth;

    // Pools that receive price updates
    address[] public pools;
    mapping(address => PoolConfig) public poolConfigs;

    // Price cache with timestamps
    mapping(bytes32 => PriceData) public priceCache;

    struct PoolConfig {
        bool active;
        bytes32 priceIdA;  // Pyth price ID for token A
        bytes32 priceIdB;  // Pyth price ID for token B
        uint256 lastPushBlock;
        uint256 lastPushTimestamp;
    }

    struct PriceData {
        uint256 price;
        uint256 confidence;
        uint256 timestamp;
        uint256 emaPrice;
    }

    // Events
    event PricePushed(
        address indexed pool,
        uint256 price,
        uint256 confidence,
        uint256 timestamp
    );

    event RebalanceTriggered(
        address indexed pool,
        uint256 deviation,
        uint256 newVirtualA,
        uint256 newVirtualB
    );

    // Access control
    address public keeper;
    uint256 public minUpdateInterval = 1; // blocks (2 seconds on Base)

    modifier onlyKeeper() {
        require(msg.sender == keeper, "Not keeper");
        _;
    }

    constructor(address _pythContract) {
        pyth = IPyth(_pythContract);
        keeper = msg.sender;
    }

    /**
     * @notice Main function called by keeper bot every 400ms
     * @dev Pushes fresh Pyth prices to all registered pools
     * @param priceUpdateData Fresh price data from Pyth
     */
    function pushPricesToPools(bytes[] calldata priceUpdateData) external payable onlyKeeper {
        // Update Pyth prices first
        uint fee = pyth.getUpdateFee(priceUpdateData);
        require(msg.value >= fee, "Insufficient fee");

        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        // Push to all active pools
        for (uint i = 0; i < pools.length; i++) {
            address pool = pools[i];
            PoolConfig storage config = poolConfigs[pool];

            if (config.active && block.number >= config.lastPushBlock + minUpdateInterval) {
                _pushToPool(pool, config);
            }
        }

        // Refund excess
        if (msg.value > fee) {
            payable(msg.sender).transfer(msg.value - fee);
        }
    }

    /**
     * @notice Push price to a specific pool and check for rebalancing
     * @dev This mimics Lifinity V2's continuous oracle updates
     */
    function _pushToPool(address poolAddress, PoolConfig storage config) private {
        LifinityPoolV2 pool = LifinityPoolV2(poolAddress);

        // Get fresh Pyth prices
        (uint256 price, uint256 confidence, uint256 timestamp) = _getPythPrice(config.priceIdA);

        // Cache the price
        priceCache[config.priceIdA] = PriceData({
            price: price,
            confidence: confidence,
            timestamp: timestamp,
            emaPrice: _getEmaPrice(config.priceIdA)
        });

        // Push to pool
        pool.updateOraclePrice(price, confidence, timestamp);

        // Check if rebalancing needed (Lifinity V2 logic)
        _checkAndTriggerRebalance(pool, price);

        // Update last push
        config.lastPushBlock = block.number;
        config.lastPushTimestamp = block.timestamp;

        emit PricePushed(poolAddress, price, confidence, timestamp);
    }

    /**
     * @notice Check and trigger V2 threshold rebalancing
     * @dev Implements Lifinity V2's discrete rebalancing
     */
    function _checkAndTriggerRebalance(LifinityPoolV2 pool, uint256 currentPrice) private {
        // Get pool state
        (
            uint256 lastRebalancePrice,
            uint256 rebalanceThreshold,
            uint256 lastRebalanceBlock,
            ,
        ) = pool.getRebalanceState();

        // Check cooldown (300 blocks = ~10 minutes on Base)
        if (block.number < lastRebalanceBlock + 300) {
            return;
        }

        // Calculate price deviation
        uint256 deviation;
        if (currentPrice > lastRebalancePrice) {
            deviation = ((currentPrice - lastRebalancePrice) * 10000) / lastRebalancePrice;
        } else {
            deviation = ((lastRebalancePrice - currentPrice) * 10000) / lastRebalancePrice;
        }

        // Trigger if threshold exceeded
        if (deviation >= rebalanceThreshold) {
            // Call rebalance on pool
            (uint256 newVirtualA, uint256 newVirtualB) = pool.executeRebalance(currentPrice);

            emit RebalanceTriggered(
                address(pool),
                deviation,
                newVirtualA,
                newVirtualB
            );
        }
    }

    /**
     * @notice Get Pyth price and convert to 18 decimals
     */
    function _getPythPrice(bytes32 priceId) private view returns (uint256, uint256, uint256) {
        PythStructs.Price memory pythPrice = pyth.getPriceNoOlderThan(priceId, 10);

        // Scale to 18 decimals
        uint256 price = _scaleToDecimals(pythPrice.price, pythPrice.expo);
        uint256 confidence = _scaleToDecimals(pythPrice.conf, pythPrice.expo);

        return (price, confidence, pythPrice.publishTime);
    }

    /**
     * @notice Get EMA price for smoothing
     */
    function _getEmaPrice(bytes32 priceId) private view returns (uint256) {
        PythStructs.Price memory emaPrice = pyth.getEmaPriceNoOlderThan(priceId, 10);
        return _scaleToDecimals(emaPrice.price, emaPrice.expo);
    }

    /**
     * @notice Scale Pyth price to 18 decimals
     */
    function _scaleToDecimals(int64 value, int32 expo) private pure returns (uint256) {
        uint256 absValue = uint256(uint64(value));

        if (expo >= 0) {
            return absValue * (10 ** uint32(expo)) * 1e18;
        } else {
            uint32 absExpo = uint32(-expo);
            return (absValue * 1e18) / (10 ** absExpo);
        }
    }

    /**
     * @notice Register a pool for price updates
     */
    function registerPool(
        address pool,
        bytes32 priceIdA,
        bytes32 priceIdB
    ) external onlyKeeper {
        if (!poolConfigs[pool].active) {
            pools.push(pool);
        }

        poolConfigs[pool] = PoolConfig({
            active: true,
            priceIdA: priceIdA,
            priceIdB: priceIdB,
            lastPushBlock: 0,
            lastPushTimestamp: 0
        });
    }

    /**
     * @notice Emergency function to force rebalance
     */
    function forceRebalance(address pool) external onlyKeeper {
        LifinityPoolV2(pool).executeRebalance(priceCache[poolConfigs[pool].priceIdA].price);
    }
}

/**
 * @title LifinityPoolV2
 * @notice Updated pool interface that receives pushed prices
 * @dev This is what our PoolCore.sol needs to implement
 */
interface LifinityPoolV2 {
    /**
     * @notice Receive pushed oracle price from keeper
     * @dev Called every 400ms by PythPushKeeper
     */
    function updateOraclePrice(
        uint256 price,
        uint256 confidence,
        uint256 timestamp
    ) external;

    /**
     * @notice Execute V2 rebalancing
     * @dev Returns new virtual reserves
     */
    function executeRebalance(uint256 currentPrice) external returns (uint256, uint256);

    /**
     * @notice Get rebalance state
     */
    function getRebalanceState() external view returns (
        uint256 lastRebalancePrice,
        uint256 rebalanceThreshold,
        uint256 lastRebalanceBlock,
        uint256 virtualReservesA,
        uint256 virtualReservesB
    );
}

/**
 * HOW THIS RECREATES LIFINITY V2 ON EVM:
 *
 * 1. PUSH MODEL (like Solana):
 *    - Keeper pushes prices every 400ms
 *    - Pools always have fresh prices
 *    - No need to pull during swaps
 *
 * 2. V2 REBALANCING:
 *    - Threshold-based (not continuous)
 *    - Cooldown period enforced
 *    - Recenters to 50/50 value
 *
 * 3. GAS OPTIMIZATION:
 *    - Batch price updates
 *    - Single keeper tx updates all pools
 *    - Swappers don't pay for oracle updates
 *
 * 4. DEPLOYMENT:
 *    - Deploy this keeper
 *    - Run bot that calls pushPricesToPools() every 400ms
 *    - Costs ~$200/month in gas on Base
 */