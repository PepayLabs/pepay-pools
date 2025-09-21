// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IOracleAdapter.sol";
import "./libraries/ConcentratedMath.sol";

/**
 * @title PoolCore
 * @notice Lifinity V2 core pool implementation for EVM
 * @dev Oracle-anchored AMM with concentrated liquidity and inventory management
 */
contract PoolCore is ReentrancyGuard, Ownable {
    using ConcentratedMath for uint256;

    // ============ Constants ============
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant MAX_ORACLE_AGE = 25; // blocks
    uint256 private constant REBALANCE_COOLDOWN = 300; // blocks (~1 hour on Base)

    // ============ State Variables ============
    struct PoolState {
        bool isInitialized;
        uint16 feeNumerator;    // Fee in basis points

        address tokenA;
        address tokenB;

        uint256 reservesA;
        uint256 reservesB;

        uint256 virtualReservesA;
        uint256 virtualReservesB;

        uint256 concentrationFactor;  // c parameter (scaled by PRECISION)
        uint256 inventoryExponent;    // z parameter (scaled by PRECISION)
        uint256 rebalanceThreshold;   // θ parameter in basis points

        uint256 lastRebalancePrice;   // p* parameter
        uint256 lastRebalanceBlock;

        uint256 totalFeesA;
        uint256 totalFeesB;
    }

    PoolState public pool;
    IOracleAdapter public oracle;
    address public feeRecipient;
    bool public paused;

    // ============ Events ============
    event Swap(
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );

    event LiquidityAdded(
        address indexed provider,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    event LiquidityRemoved(
        address indexed provider,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    event Rebalanced(
        uint256 newVirtualReservesA,
        uint256 newVirtualReservesB,
        uint256 oraclePrice
    );

    event FeesCollected(
        uint256 feesA,
        uint256 feesB
    );

    // ============ Modifiers ============
    modifier notPaused() {
        require(!paused, "Pool is paused");
        _;
    }

    modifier initialized() {
        require(pool.isInitialized, "Pool not initialized");
        _;
    }

    // ============ Constructor ============
    constructor(address _oracle, address _feeRecipient) {
        oracle = IOracleAdapter(_oracle);
        feeRecipient = _feeRecipient;
    }

    // ============ Initialization ============
    function initialize(
        address _tokenA,
        address _tokenB,
        uint16 _feeNumerator,
        uint256 _concentrationFactor,
        uint256 _inventoryExponent,
        uint256 _rebalanceThreshold
    ) external onlyOwner {
        require(!pool.isInitialized, "Already initialized");
        require(_tokenA != _tokenB, "Tokens must be different");
        require(_feeNumerator <= 100, "Fee too high"); // Max 1%

        pool.isInitialized = true;
        pool.tokenA = _tokenA;
        pool.tokenB = _tokenB;
        pool.feeNumerator = _feeNumerator;
        pool.concentrationFactor = _concentrationFactor;
        pool.inventoryExponent = _inventoryExponent;
        pool.rebalanceThreshold = _rebalanceThreshold;

        // Initialize rebalance price with current oracle price
        (uint256 price,) = oracle.getPrice(_tokenA, _tokenB);
        pool.lastRebalancePrice = price;
        pool.lastRebalanceBlock = block.number;
    }

    // ============ Swap Functions ============
    function swapExactInput(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external nonReentrant notPaused initialized returns (uint256 amountOut) {
        require(tokenIn == pool.tokenA || tokenIn == pool.tokenB, "Invalid token");
        require(amountIn > 0, "Amount must be positive");

        // Get oracle price and validate
        (uint256 oraclePrice, uint256 confidence) = oracle.getPrice(pool.tokenA, pool.tokenB);
        _validateOracle(oraclePrice, confidence);

        // Check for rebalancing opportunity
        _checkAndRebalance(oraclePrice);

        // Calculate output amount
        bool isTokenAIn = tokenIn == pool.tokenA;
        amountOut = _calculateOutput(
            amountIn,
            isTokenAIn,
            oraclePrice
        );

        // Apply fees
        uint256 fee = (amountOut * pool.feeNumerator) / BASIS_POINTS;
        amountOut = amountOut - fee;

        require(amountOut >= minAmountOut, "Slippage exceeded");

        // Update reserves
        if (isTokenAIn) {
            pool.reservesA += amountIn;
            pool.reservesB -= amountOut;
            pool.totalFeesB += fee;
        } else {
            pool.reservesB += amountIn;
            pool.reservesA -= amountOut;
            pool.totalFeesA += fee;
        }

        // Transfer tokens
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(isTokenAIn ? pool.tokenB : pool.tokenA).transfer(recipient, amountOut);

        emit Swap(msg.sender, tokenIn, isTokenAIn ? pool.tokenB : pool.tokenA, amountIn, amountOut, fee);
    }

    // ============ Liquidity Functions ============
    function addLiquidity(
        uint256 amountA,
        uint256 amountB,
        address recipient
    ) external nonReentrant notPaused initialized returns (uint256 liquidity) {
        require(amountA > 0 && amountB > 0, "Amounts must be positive");

        // Calculate liquidity tokens (simplified)
        if (pool.reservesA == 0 && pool.reservesB == 0) {
            liquidity = ConcentratedMath.sqrt(amountA * amountB);
        } else {
            uint256 liquidityA = (amountA * getTotalLiquidity()) / pool.reservesA;
            uint256 liquidityB = (amountB * getTotalLiquidity()) / pool.reservesB;
            liquidity = liquidityA < liquidityB ? liquidityA : liquidityB;
        }

        // Update reserves
        pool.reservesA += amountA;
        pool.reservesB += amountB;

        // Update virtual reserves proportionally
        pool.virtualReservesA = pool.reservesA * pool.concentrationFactor / PRECISION;
        pool.virtualReservesB = pool.reservesB * pool.concentrationFactor / PRECISION;

        // Transfer tokens
        IERC20(pool.tokenA).transferFrom(msg.sender, address(this), amountA);
        IERC20(pool.tokenB).transferFrom(msg.sender, address(this), amountB);

        emit LiquidityAdded(recipient, amountA, amountB, liquidity);
    }

    // ============ Internal Functions ============
    function _calculateOutput(
        uint256 amountIn,
        bool isTokenAIn,
        uint256 oraclePrice
    ) internal view returns (uint256) {
        // Calculate inventory imbalance
        uint256 valueA = pool.reservesA * oraclePrice / PRECISION;
        uint256 valueB = pool.reservesB;
        uint256 imbalanceRatio = (valueA * PRECISION) / valueB;

        // Get virtual reserves with concentration
        uint256 virtualA = pool.virtualReservesA;
        uint256 virtualB = pool.virtualReservesB;

        // Apply inventory adjustment
        uint256 kAdjusted = _applyInventoryAdjustment(
            virtualA * virtualB,
            imbalanceRatio,
            isTokenAIn
        );

        // Calculate output using adjusted K
        if (isTokenAIn) {
            uint256 newVirtualA = virtualA + amountIn;
            uint256 newVirtualB = kAdjusted / newVirtualA;
            return virtualB - newVirtualB;
        } else {
            uint256 newVirtualB = virtualB + amountIn;
            uint256 newVirtualA = kAdjusted / newVirtualB;
            return virtualA - newVirtualA;
        }
    }

    function _applyInventoryAdjustment(
        uint256 k,
        uint256 imbalanceRatio,
        bool isBuyingA
    ) internal view returns (uint256) {
        if (imbalanceRatio < PRECISION) {
            // Token A is scarce
            if (isBuyingA) {
                // Reduce liquidity (higher slippage)
                uint256 adjustment = ConcentratedMath.pow(
                    PRECISION * PRECISION / imbalanceRatio,
                    pool.inventoryExponent
                ) / PRECISION;
                return k * adjustment / PRECISION;
            } else {
                // Increase liquidity (lower slippage)
                uint256 adjustment = ConcentratedMath.pow(
                    imbalanceRatio,
                    pool.inventoryExponent
                ) / PRECISION;
                return k * adjustment / PRECISION;
            }
        } else {
            // Token B is scarce - inverse logic
            if (!isBuyingA) {
                uint256 adjustment = ConcentratedMath.pow(
                    imbalanceRatio,
                    pool.inventoryExponent
                ) / PRECISION;
                return k * adjustment / PRECISION;
            } else {
                uint256 adjustment = ConcentratedMath.pow(
                    PRECISION * PRECISION / imbalanceRatio,
                    pool.inventoryExponent
                ) / PRECISION;
                return k * adjustment / PRECISION;
            }
        }
    }

    function _checkAndRebalance(uint256 currentPrice) internal {
        // Check cooldown
        if (block.number - pool.lastRebalanceBlock < REBALANCE_COOLDOWN) {
            return;
        }

        // Check threshold
        uint256 priceDeviation = currentPrice > pool.lastRebalancePrice
            ? ((currentPrice - pool.lastRebalancePrice) * BASIS_POINTS) / pool.lastRebalancePrice
            : ((pool.lastRebalancePrice - currentPrice) * BASIS_POINTS) / pool.lastRebalancePrice;

        if (priceDeviation >= pool.rebalanceThreshold) {
            // Rebalance to 50/50 value split
            uint256 totalValue = (pool.reservesA * currentPrice / PRECISION) + pool.reservesB;
            uint256 targetValuePerSide = totalValue / 2;

            pool.virtualReservesA = (targetValuePerSide * PRECISION) / currentPrice;
            pool.virtualReservesB = targetValuePerSide;

            pool.lastRebalancePrice = currentPrice;
            pool.lastRebalanceBlock = block.number;

            emit Rebalanced(pool.virtualReservesA, pool.virtualReservesB, currentPrice);
        }
    }

    function _validateOracle(uint256 price, uint256 confidence) internal view {
        require(price > 0, "Invalid oracle price");

        // Check confidence (max 2% of price)
        require(confidence <= (price * 200) / BASIS_POINTS, "Oracle confidence too wide");

        // Check freshness
        uint256 lastUpdate = oracle.lastUpdateBlock();
        require(block.number - lastUpdate <= MAX_ORACLE_AGE, "Oracle price stale");
    }

    // ============ Admin Functions ============
    function updateParameters(
        uint256 _concentrationFactor,
        uint256 _inventoryExponent,
        uint256 _rebalanceThreshold
    ) external onlyOwner {
        pool.concentrationFactor = _concentrationFactor;
        pool.inventoryExponent = _inventoryExponent;
        pool.rebalanceThreshold = _rebalanceThreshold;
    }

    function collectFees() external {
        require(msg.sender == feeRecipient, "Not fee recipient");

        uint256 protocolFeesA = pool.totalFeesA / 5; // 20% protocol share
        uint256 protocolFeesB = pool.totalFeesB / 5;

        pool.totalFeesA -= protocolFeesA;
        pool.totalFeesB -= protocolFeesB;

        if (protocolFeesA > 0) {
            IERC20(pool.tokenA).transfer(feeRecipient, protocolFeesA);
        }
        if (protocolFeesB > 0) {
            IERC20(pool.tokenB).transfer(feeRecipient, protocolFeesB);
        }

        emit FeesCollected(protocolFeesA, protocolFeesB);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    // ============ View Functions ============
    function getReserves() external view returns (uint256, uint256) {
        return (pool.reservesA, pool.reservesB);
    }

    function getVirtualReserves() external view returns (uint256, uint256) {
        return (pool.virtualReservesA, pool.virtualReservesB);
    }

    function getTotalLiquidity() public view returns (uint256) {
        return ConcentratedMath.sqrt(pool.reservesA * pool.reservesB);
    }

    function quoteSwap(
        address tokenIn,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 fee) {
        require(tokenIn == pool.tokenA || tokenIn == pool.tokenB, "Invalid token");

        (uint256 oraclePrice,) = oracle.getPrice(pool.tokenA, pool.tokenB);

        bool isTokenAIn = tokenIn == pool.tokenA;
        amountOut = _calculateOutput(amountIn, isTokenAIn, oraclePrice);
        fee = (amountOut * pool.feeNumerator) / BASIS_POINTS;
        amountOut = amountOut - fee;
    }
}