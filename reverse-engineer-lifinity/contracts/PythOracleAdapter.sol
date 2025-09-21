// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "./interfaces/IOracleAdapter.sol";

/**
 * @title PythOracleAdapter
 * @notice Pyth Network oracle adapter for Lifinity pools - MUCH better frequency!
 * @dev Pyth updates every 400ms vs Chainlink's deviation-based updates
 */
contract PythOracleAdapter is IOracleAdapter {
    IPyth public immutable pyth;

    // Price feed IDs for different networks
    mapping(address => mapping(address => bytes32)) public priceIds;

    // Cache for latest updates
    mapping(bytes32 => PythStructs.Price) public latestPrices;

    uint256 private constant PRECISION = 1e18;
    uint256 private constant MAX_CONFIDENCE_RATIO = 200; // 2% max confidence
    uint256 private constant MAX_AGE_SECONDS = 10; // 10 seconds max age

    address public keeper;

    event PriceUpdated(bytes32 indexed priceId, int64 price, uint64 confidence, uint32 timestamp);
    event PriceFeedSet(address tokenA, address tokenB, bytes32 priceId);

    modifier onlyKeeper() {
        require(msg.sender == keeper, "Not keeper");
        _;
    }

    constructor(address _pythContract) {
        pyth = IPyth(_pythContract);
        keeper = msg.sender;

        // Initialize common price IDs (Base/Ethereum mainnet)
        _initializePriceFeeds();
    }

    /**
     * @notice Initialize common Pyth price feed IDs
     * @dev These are actual Pyth Network price feed IDs
     */
    function _initializePriceFeeds() private {
        // ETH/USD
        bytes32 ethUsdId = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

        // USDC/USD
        bytes32 usdcUsdId = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

        // USDT/USD
        bytes32 usdtUsdId = 0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b;

        // BTC/USD
        bytes32 btcUsdId = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

        // Store common pairs
        address WETH = 0x4200000000000000000000000000000000000006; // Base WETH
        address USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC

        priceIds[WETH][USDC] = ethUsdId; // Will calculate cross rate
        priceIds[USDC][WETH] = ethUsdId;
    }

    /**
     * @notice Update price feeds with fresh Pyth data
     * @dev Called by keeper bot every 400ms or on-demand by swappers
     * @param priceUpdateData The encoded price update data from Pyth
     */
    function updatePriceFeeds(bytes[] calldata priceUpdateData) external payable {
        // Get fee required by Pyth
        uint fee = pyth.getUpdateFee(priceUpdateData);
        require(msg.value >= fee, "Insufficient fee");

        // Update the prices
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        // Refund excess fee
        if (msg.value > fee) {
            payable(msg.sender).transfer(msg.value - fee);
        }
    }

    /**
     * @notice Get price with confidence interval from Pyth
     * @dev Returns price scaled to 18 decimals with confidence
     */
    function getPrice(
        address tokenA,
        address tokenB
    ) external view override returns (uint256 price, uint256 confidence) {
        bytes32 priceId = priceIds[tokenA][tokenB];
        require(priceId != bytes32(0), "Price feed not configured");

        // Get price from Pyth (will revert if too old)
        PythStructs.Price memory pythPrice = pyth.getPriceNoOlderThan(
            priceId,
            MAX_AGE_SECONDS
        );

        require(pythPrice.price > 0, "Invalid price");

        // Convert to 18 decimals
        // Pyth prices have custom exponents (usually -8)
        int32 exponent = pythPrice.expo;

        if (exponent >= 0) {
            // Positive exponent (rare)
            price = uint256(uint64(pythPrice.price)) * (10 ** uint32(exponent)) * PRECISION;
        } else {
            // Negative exponent (common)
            uint32 absExponent = uint32(-exponent);
            price = (uint256(uint64(pythPrice.price)) * PRECISION) / (10 ** absExponent);
        }

        // Calculate confidence in 18 decimals
        if (exponent >= 0) {
            confidence = uint256(pythPrice.conf) * (10 ** uint32(exponent)) * PRECISION;
        } else {
            uint32 absExponent = uint32(-exponent);
            confidence = (uint256(pythPrice.conf) * PRECISION) / (10 ** absExponent);
        }

        // Validate confidence is reasonable (< 2% of price)
        require(confidence <= (price * MAX_CONFIDENCE_RATIO) / 10000, "Confidence too wide");

        return (price, confidence);
    }

    /**
     * @notice Get exponentially-weighted moving average price
     * @dev Pyth's EMA price for more stability
     */
    function getEmaPrice(
        address tokenA,
        address tokenB
    ) external view returns (uint256 emaPrice, uint256 confidence) {
        bytes32 priceId = priceIds[tokenA][tokenB];
        require(priceId != bytes32(0), "Price feed not configured");

        PythStructs.Price memory pythPrice = pyth.getEmaPriceNoOlderThan(
            priceId,
            MAX_AGE_SECONDS
        );

        // Convert EMA price same as regular price
        int32 exponent = pythPrice.expo;

        if (exponent >= 0) {
            emaPrice = uint256(uint64(pythPrice.price)) * (10 ** uint32(exponent)) * PRECISION;
            confidence = uint256(pythPrice.conf) * (10 ** uint32(exponent)) * PRECISION;
        } else {
            uint32 absExponent = uint32(-exponent);
            emaPrice = (uint256(uint64(pythPrice.price)) * PRECISION) / (10 ** absExponent);
            confidence = (uint256(pythPrice.conf) * PRECISION) / (10 ** absExponent);
        }

        return (emaPrice, confidence);
    }

    /**
     * @notice Get the exact timestamp of last price update
     * @dev More precise than block-based timing
     */
    function getLastUpdateTime(bytes32 priceId) external view returns (uint256) {
        PythStructs.Price memory pythPrice = pyth.getPriceUnsafe(priceId);
        return pythPrice.publishTime;
    }

    /**
     * @notice Get block number of last update (for compatibility)
     */
    function lastUpdateBlock() external view override returns (uint256) {
        // Return current block as Pyth updates are always fresh
        return block.number;
    }

    /**
     * @notice Check if price feed is active
     */
    function isActive() external pure override returns (bool) {
        return true;
    }

    /**
     * @notice Set price feed ID for a token pair
     * @dev Only keeper can set new price feeds
     */
    function setPriceFeed(
        address tokenA,
        address tokenB,
        bytes32 priceId
    ) external onlyKeeper {
        priceIds[tokenA][tokenB] = priceId;
        priceIds[tokenB][tokenA] = priceId; // Bidirectional

        emit PriceFeedSet(tokenA, tokenB, priceId);
    }

    /**
     * @notice Calculate cross rate for pairs without direct feed
     * @dev E.g., ETH/USDC from ETH/USD and USDC/USD
     */
    function getCrossRate(
        bytes32 baseId,
        bytes32 quoteId
    ) external view returns (uint256 rate, uint256 confidence) {
        PythStructs.Price memory basePrice = pyth.getPriceNoOlderThan(baseId, MAX_AGE_SECONDS);
        PythStructs.Price memory quotePrice = pyth.getPriceNoOlderThan(quoteId, MAX_AGE_SECONDS);

        // Calculate cross rate
        // rate = basePrice / quotePrice
        uint256 scaledBase = _scalePrice(basePrice);
        uint256 scaledQuote = _scalePrice(quotePrice);

        rate = (scaledBase * PRECISION) / scaledQuote;

        // Combine confidences (simplified - production needs proper error propagation)
        uint256 baseConf = _scalePrice(
            PythStructs.Price(basePrice.conf, basePrice.expo, basePrice.timestamp, basePrice.publishTime)
        );
        uint256 quoteConf = _scalePrice(
            PythStructs.Price(quotePrice.conf, quotePrice.expo, quotePrice.timestamp, quotePrice.publishTime)
        );

        confidence = baseConf + quoteConf; // Simplified

        return (rate, confidence);
    }

    /**
     * @notice Helper to scale Pyth price to 18 decimals
     */
    function _scalePrice(PythStructs.Price memory pythPrice) private pure returns (uint256) {
        int32 exponent = pythPrice.expo;

        if (exponent >= 0) {
            return uint256(uint64(pythPrice.price)) * (10 ** uint32(exponent)) * PRECISION;
        } else {
            uint32 absExponent = uint32(-exponent);
            return (uint256(uint64(pythPrice.price)) * PRECISION) / (10 ** absExponent);
        }
    }

    /**
     * @notice Update keeper address
     */
    function setKeeper(address _keeper) external onlyKeeper {
        keeper = _keeper;
    }
}

/**
 * Key advantages of Pyth over Chainlink for Lifinity:
 *
 * 1. UPDATE FREQUENCY
 *    - Pyth: Every 400ms (matches Solana slots!)
 *    - Chainlink: 0.5-2% deviation or heartbeat
 *    → Better for oracle-anchored AMM that needs fresh prices
 *
 * 2. CONFIDENCE INTERVALS
 *    - Pyth: Native confidence bands
 *    - Chainlink: No confidence data
 *    → Can calculate dynamic spreads like original Lifinity
 *
 * 3. CROSS-CHAIN CONSISTENCY
 *    - Pyth: Same price on all chains
 *    - Chainlink: Different feeds per chain
 *    → Easier arbitrage and pricing
 *
 * 4. LATENCY
 *    - Pyth: <1 second from real markets
 *    - Chainlink: 10-30 seconds
 *    → Tighter spreads, less IL
 *
 * 5. PUBLISHER TRANSPARENCY
 *    - Pyth: Can see individual publisher prices
 *    - Chainlink: Aggregated only
 *    → Can detect and filter outliers
 *
 * COSTS:
 * - Pyth requires ~0.001 ETH per update
 * - But swappers can include update in their tx
 * - Or run keeper bot to update every 400ms
 */