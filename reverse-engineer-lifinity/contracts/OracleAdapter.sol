// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./interfaces/IOracleAdapter.sol";

/**
 * @title OracleAdapter
 * @notice Chainlink oracle adapter for Lifinity pools
 */
contract OracleAdapter is IOracleAdapter {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant CHAINLINK_DECIMALS = 8;

    mapping(address => mapping(address => address)) public priceFeeds;
    mapping(address => uint256) public lastUpdateBlocks;

    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @notice Set price feed for a token pair
     */
    function setPriceFeed(
        address tokenA,
        address tokenB,
        address feed
    ) external onlyOwner {
        priceFeeds[tokenA][tokenB] = feed;
        priceFeeds[tokenB][tokenA] = feed; // Bidirectional
    }

    /**
     * @notice Get price from Chainlink oracle
     */
    function getPrice(
        address tokenA,
        address tokenB
    ) external view override returns (uint256 price, uint256 confidence) {
        address feed = priceFeeds[tokenA][tokenB];
        require(feed != address(0), "Price feed not set");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);

        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        require(answer > 0, "Invalid price");
        require(updatedAt > 0, "Round not complete");
        require(answeredInRound >= roundId, "Stale price");

        // Convert to 18 decimals
        price = uint256(answer) * 10**(18 - CHAINLINK_DECIMALS);

        // Chainlink doesn't provide confidence intervals
        // Use 0.5% as default confidence
        confidence = price / 200;

        return (price, confidence);
    }

    /**
     * @notice Get last update block
     */
    function lastUpdateBlock() external view override returns (uint256) {
        // In real implementation, track actual update blocks
        return block.number;
    }

    /**
     * @notice Check if oracle is active
     */
    function isActive() external pure override returns (bool) {
        return true;
    }
}