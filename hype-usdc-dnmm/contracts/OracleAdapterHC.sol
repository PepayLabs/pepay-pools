// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapterHC} from "./interfaces/IOracleAdapterHC.sol";
import {OracleUtils} from "./libraries/OracleUtils.sol";

/// @notice Adapter for HyperCore order-book/oracle read precompiles.
contract OracleAdapterHC is IOracleAdapterHC {
    using OracleUtils for uint256;

    address public immutable hyperCorePrecompile;
    bytes32 public immutable assetIdBase;
    bytes32 public immutable assetIdQuote;
    bytes32 public immutable marketId;

    error PrecompileCallFailed();

    constructor(address _precompile, bytes32 _assetIdBase, bytes32 _assetIdQuote, bytes32 _marketId) {
        hyperCorePrecompile = _precompile;
        assetIdBase = _assetIdBase;
        assetIdQuote = _assetIdQuote;
        marketId = _marketId;
    }

    // Hypothetical function selectors for demonstration; replace with canonical ones when confirmed.
    bytes4 private constant SELECTOR_SPOT = 0x6a627842; // getSpotOraclePrice(bytes32)
    bytes4 private constant SELECTOR_ORDERBOOK = 0x3f5d0c52; // getOrderbookTopOfBook(bytes32)
    bytes4 private constant SELECTOR_EMA = 0x0e349d01; // getEmaOraclePrice(bytes32)

    function readMidAndAge() external view override returns (MidResult memory result) {
        bytes memory callData = abi.encodeWithSelector(SELECTOR_SPOT, assetIdBase, assetIdQuote);
        (bool ok, bytes memory data) = hyperCorePrecompile.staticcall(callData);
        if (!ok || data.length < 64) {
            return MidResult(0, type(uint256).max, false);
        }

        (uint256 mid, uint64 timestamp) = abi.decode(data, (uint256, uint64));
        uint256 age = block.timestamp > timestamp ? block.timestamp - timestamp : 0;
        return MidResult(mid, age, true);
    }

    function readBidAsk() external view override returns (BidAskResult memory result) {
        bytes memory callData = abi.encodeWithSelector(SELECTOR_ORDERBOOK, marketId);
        (bool ok, bytes memory data) = hyperCorePrecompile.staticcall(callData);
        if (!ok || data.length < 64) {
            return BidAskResult(0, 0, type(uint256).max, false);
        }

        (uint256 bid, uint256 ask) = abi.decode(data, (uint256, uint256));
        uint256 spreadBps = OracleUtils.computeSpreadBps(bid, ask);
        return BidAskResult(bid, ask, spreadBps, true);
    }

    function readMidEmaFallback() external view override returns (MidResult memory result) {
        bytes memory callData = abi.encodeWithSelector(SELECTOR_EMA, assetIdBase, assetIdQuote);
        (bool ok, bytes memory data) = hyperCorePrecompile.staticcall(callData);
        if (!ok || data.length < 64) {
            return MidResult(0, type(uint256).max, false);
        }

        (uint256 emaMid, uint64 timestamp) = abi.decode(data, (uint256, uint64));
        uint256 age = block.timestamp > timestamp ? block.timestamp - timestamp : 0;
        return MidResult(emaMid, age, true);
    }
}
