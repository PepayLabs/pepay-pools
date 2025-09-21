// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IOracleAdapter
 * @notice Interface for oracle price feeds
 */
interface IOracleAdapter {
    /**
     * @notice Get the latest price and confidence interval
     * @param tokenA Base token address
     * @param tokenB Quote token address
     * @return price Price scaled to 1e18
     * @return confidence Confidence interval scaled to 1e18
     */
    function getPrice(
        address tokenA,
        address tokenB
    ) external view returns (uint256 price, uint256 confidence);

    /**
     * @notice Get the block number of the last oracle update
     * @return Block number
     */
    function lastUpdateBlock() external view returns (uint256);

    /**
     * @notice Check if the price feed is active
     * @return True if active
     */
    function isActive() external view returns (bool);
}