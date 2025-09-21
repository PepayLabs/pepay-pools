// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";
import "./PoolCore.sol";

/**
 * @title RebalanceKeeper
 * @notice Automated keeper for threshold-based rebalancing
 * @dev Compatible with Chainlink Automation
 */
contract RebalanceKeeper is AutomationCompatibleInterface {
    // Pool registry
    mapping(address => bool) public registeredPools;
    address[] public pools;

    address public owner;
    uint256 public maxGasForRebalance = 200000;

    event PoolRegistered(address pool);
    event PoolUnregistered(address pool);
    event RebalanceTriggered(address pool, uint256 deviation);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @notice Register a pool for automated rebalancing
     */
    function registerPool(address pool) external onlyOwner {
        require(!registeredPools[pool], "Already registered");

        registeredPools[pool] = true;
        pools.push(pool);

        emit PoolRegistered(pool);
    }

    /**
     * @notice Unregister a pool
     */
    function unregisterPool(address pool) external onlyOwner {
        require(registeredPools[pool], "Not registered");

        registeredPools[pool] = false;

        // Remove from array
        for (uint i = 0; i < pools.length; i++) {
            if (pools[i] == pool) {
                pools[i] = pools[pools.length - 1];
                pools.pop();
                break;
            }
        }

        emit PoolUnregistered(pool);
    }

    /**
     * @notice Check if any pool needs rebalancing
     * @dev Called by Chainlink Automation
     */
    function checkUpkeep(
        bytes calldata /* checkData */
    ) external view override returns (bool upkeepNeeded, bytes memory performData) {
        for (uint i = 0; i < pools.length; i++) {
            if (registeredPools[pools[i]]) {
                try this.needsRebalance(pools[i]) returns (bool needs, uint256 deviation) {
                    if (needs) {
                        return (true, abi.encode(pools[i], deviation));
                    }
                } catch {
                    // Skip pools with errors
                    continue;
                }
            }
        }

        return (false, "");
    }

    /**
     * @notice Perform the rebalancing
     * @dev Called by Chainlink Automation
     */
    function performUpkeep(bytes calldata performData) external override {
        (address pool, uint256 deviation) = abi.decode(performData, (address, uint256));

        require(registeredPools[pool], "Pool not registered");

        // Verify the pool still needs rebalancing
        (bool needs,) = needsRebalance(pool);
        require(needs, "Rebalance no longer needed");

        // Trigger rebalance on the pool
        // Note: The pool contract handles the actual rebalancing logic
        try PoolCore(pool).swapExactInput(
            PoolCore(pool).pool().tokenA(),
            0, // Zero amount triggers rebalance check
            0,
            address(this)
        ) {
            emit RebalanceTriggered(pool, deviation);
        } catch {
            // Rebalance might have been triggered by another tx
            revert("Rebalance failed");
        }
    }

    /**
     * @notice Check if a specific pool needs rebalancing
     */
    function needsRebalance(address poolAddress) public view returns (bool, uint256) {
        PoolCore pool = PoolCore(poolAddress);

        // Get pool state
        (uint256 reservesA, uint256 reservesB) = pool.getReserves();

        if (reservesA == 0 || reservesB == 0) {
            return (false, 0);
        }

        // Get current oracle price
        IOracleAdapter oracle = pool.oracle();
        (uint256 currentPrice,) = oracle.getPrice(
            pool.pool().tokenA(),
            pool.pool().tokenB()
        );

        // Get last rebalance price
        uint256 lastRebalancePrice = pool.pool().lastRebalancePrice();

        // Calculate deviation
        uint256 deviation = currentPrice > lastRebalancePrice
            ? ((currentPrice - lastRebalancePrice) * 10000) / lastRebalancePrice
            : ((lastRebalancePrice - currentPrice) * 10000) / lastRebalancePrice;

        // Check if deviation exceeds threshold
        uint256 threshold = pool.pool().rebalanceThreshold();

        // Check cooldown
        uint256 blocksSinceRebalance = block.number - pool.pool().lastRebalanceBlock();
        uint256 cooldown = 300; // Same as PoolCore.REBALANCE_COOLDOWN

        if (deviation >= threshold && blocksSinceRebalance >= cooldown) {
            return (true, deviation);
        }

        return (false, deviation);
    }

    /**
     * @notice Get all registered pools
     */
    function getRegisteredPools() external view returns (address[] memory) {
        uint count = 0;
        for (uint i = 0; i < pools.length; i++) {
            if (registeredPools[pools[i]]) {
                count++;
            }
        }

        address[] memory active = new address[](count);
        uint index = 0;
        for (uint i = 0; i < pools.length; i++) {
            if (registeredPools[pools[i]]) {
                active[index] = pools[i];
                index++;
            }
        }

        return active;
    }

    /**
     * @notice Update gas limit for rebalancing
     */
    function setMaxGasForRebalance(uint256 _maxGas) external onlyOwner {
        maxGasForRebalance = _maxGas;
    }
}