// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapterHC} from "../interfaces/IOracleAdapterHC.sol";
import {OracleUtils} from "../lib/OracleUtils.sol";
import {HyperCoreConstants} from "./HyperCoreConstants.sol";

/// @notice Adapter for HyperCore order-book/oracle read precompiles.
contract OracleAdapterHC is IOracleAdapterHC {
    using OracleUtils for uint256;

    address internal immutable HYPER_CORE_PRECOMPILE_;
    bytes32 internal immutable ASSET_ID_BASE_;
    bytes32 internal immutable ASSET_ID_QUOTE_;
    bytes32 internal immutable MARKET_ID_;

    error HyperCoreCallFailed(bytes4 selector, bytes data);
    error HyperCoreInvalidResponse(bytes4 selector, uint256 length);
    error PrecompileZero();
    error AssetIdZero();
    error MarketIdZero();

    constructor(address _precompile, bytes32 _assetIdBase, bytes32 _assetIdQuote, bytes32 _marketId) {
        if (_precompile == address(0)) revert PrecompileZero();
        if (_assetIdBase == bytes32(0) || _assetIdQuote == bytes32(0)) revert AssetIdZero();
        if (_marketId == bytes32(0)) revert MarketIdZero();
        HYPER_CORE_PRECOMPILE_ = _precompile;
        ASSET_ID_BASE_ = _assetIdBase;
        ASSET_ID_QUOTE_ = _assetIdQuote;
        MARKET_ID_ = _marketId;
    }

    function hyperCorePrecompile() external view returns (address) {
        return HYPER_CORE_PRECOMPILE_;
    }

    function assetIdBase() external view returns (bytes32) {
        return ASSET_ID_BASE_;
    }

    function assetIdQuote() external view returns (bytes32) {
        return ASSET_ID_QUOTE_;
    }

    function marketId() external view returns (bytes32) {
        return MARKET_ID_;
    }

    function readMidAndAge() external view override returns (MidResult memory result) {
        bytes memory callData = abi.encodeWithSelector(
            HyperCoreConstants.SEL_GET_SPOT_ORACLE_PRICE, ASSET_ID_BASE_, ASSET_ID_QUOTE_
        );
        bytes memory data = _callHyperCore(callData, HyperCoreConstants.SEL_GET_SPOT_ORACLE_PRICE, 64);

        (uint256 mid, uint64 timestamp) = abi.decode(data, (uint256, uint64));
        uint256 age = block.timestamp > timestamp ? block.timestamp - timestamp : 0;
        return MidResult(mid, age, true);
    }

    function readBidAsk() external view override returns (BidAskResult memory result) {
        bytes memory callData = abi.encodeWithSelector(HyperCoreConstants.SEL_GET_TOP_OF_BOOK, MARKET_ID_);
        bytes memory data = _callHyperCore(callData, HyperCoreConstants.SEL_GET_TOP_OF_BOOK, 64);

        (uint256 bid, uint256 ask) = abi.decode(data, (uint256, uint256));
        uint256 spreadBps = OracleUtils.computeSpreadBps(bid, ask);
        return BidAskResult(bid, ask, spreadBps, true);
    }

    function readMidEmaFallback() external view override returns (MidResult memory result) {
        bytes memory callData = abi.encodeWithSelector(
            HyperCoreConstants.SEL_GET_EMA_ORACLE_PRICE, ASSET_ID_BASE_, ASSET_ID_QUOTE_
        );
        bytes memory data = _callHyperCore(callData, HyperCoreConstants.SEL_GET_EMA_ORACLE_PRICE, 64);

        (uint256 emaMid, uint64 timestamp) = abi.decode(data, (uint256, uint64));
        uint256 age = block.timestamp > timestamp ? block.timestamp - timestamp : 0;
        return MidResult(emaMid, age, true);
    }

    function _callHyperCore(bytes memory callData, bytes4 selector, uint256 minLength)
        private
        view
        returns (bytes memory data)
    {
        // AUDIT:HCABI-002 fail-closed on staticcall failure
        (bool ok, bytes memory raw) = HYPER_CORE_PRECOMPILE_.staticcall(callData);
        if (!ok) revert HyperCoreCallFailed(selector, raw);
        if (raw.length < minLength) revert HyperCoreInvalidResponse(selector, raw.length);
        return raw;
    }
}
