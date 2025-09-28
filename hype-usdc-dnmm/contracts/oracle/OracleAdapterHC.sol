// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapterHC} from "../interfaces/IOracleAdapterHC.sol";
import {OracleUtils} from "../lib/OracleUtils.sol";
import {HyperCoreConstants} from "./HyperCoreConstants.sol";

/// @notice Adapter for HyperCore order-book/oracle read precompiles.
contract OracleAdapterHC is IOracleAdapterHC {
    using OracleUtils for uint256;

    bytes32 internal immutable ASSET_ID_BASE_;
    bytes32 internal immutable ASSET_ID_QUOTE_;
    bytes32 internal immutable MARKET_ID_;
    uint32 internal immutable MARKET_KEY_;
    uint32 internal immutable BASE_ASSET_KEY_;
    uint32 internal immutable QUOTE_ASSET_KEY_;

    error HyperCoreAddressMismatch(address provided);
    error HyperCoreCallFailed(address target, bytes data);
    error HyperCoreInvalidResponse(address target, uint256 length);
    error PrecompileZero();
    error AssetIdZero();
    error MarketIdZero();

    constructor(address _precompile, bytes32 _assetIdBase, bytes32 _assetIdQuote, bytes32 _marketId) {
        if (_precompile == address(0)) revert PrecompileZero();
        if (_precompile != HyperCoreConstants.ORACLE_PX_PRECOMPILE) {
            // AUDIT:HCABI-001 enforce canonical oracle precompile wiring
            revert HyperCoreAddressMismatch(_precompile);
        }
        if (_assetIdBase == bytes32(0) || _assetIdQuote == bytes32(0)) revert AssetIdZero();
        if (_marketId == bytes32(0)) revert MarketIdZero();
        ASSET_ID_BASE_ = _assetIdBase;
        ASSET_ID_QUOTE_ = _assetIdQuote;
        MARKET_ID_ = _marketId;
        BASE_ASSET_KEY_ = _sliceToUint32(_assetIdBase);
        QUOTE_ASSET_KEY_ = _sliceToUint32(_assetIdQuote);
        MARKET_KEY_ = _sliceToUint32(_marketId);
        if (BASE_ASSET_KEY_ == 0 || QUOTE_ASSET_KEY_ == 0) revert AssetIdZero();
        if (MARKET_KEY_ == 0) revert MarketIdZero();
    }

    function hyperCorePrecompile() external view returns (address) {
        return HyperCoreConstants.ORACLE_PX_PRECOMPILE;
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
        bytes memory callData = abi.encode(MARKET_KEY_);
        // AUDIT:HCABI-001 canonical oraclePx precompile (raw 32-byte calldata)
        bytes memory data = _callHyperCore(HyperCoreConstants.ORACLE_PX_PRECOMPILE, callData, 64);

        (uint256 mid, uint64 timestamp) = abi.decode(data, (uint256, uint64));
        uint256 age = block.timestamp > timestamp ? block.timestamp - timestamp : 0;
        return MidResult(mid, age, true);
    }

    function readBidAsk() external view override returns (BidAskResult memory result) {
        bytes memory callData = abi.encode(MARKET_KEY_);
        // AUDIT:HCABI-001 canonical bbo precompile for bid/ask spread
        bytes memory data = _callHyperCore(HyperCoreConstants.BBO_PRECOMPILE, callData, 64);

        (uint256 bid, uint256 ask) = abi.decode(data, (uint256, uint256));
        uint256 spreadBps = OracleUtils.computeSpreadBps(bid, ask);
        return BidAskResult(bid, ask, spreadBps, true);
    }

    function readMidEmaFallback() external view override returns (MidResult memory result) {
        bytes memory callData = abi.encode(MARKET_KEY_);
        // AUDIT:HCABI-001 canonical markPx precompile used as EMA fallback
        bytes memory data = _callHyperCore(HyperCoreConstants.MARK_PX_PRECOMPILE, callData, 64);

        (uint256 emaMid, uint64 timestamp) = abi.decode(data, (uint256, uint64));
        uint256 age = block.timestamp > timestamp ? block.timestamp - timestamp : 0;
        return MidResult(emaMid, age, true);
    }

    function _callHyperCore(address target, bytes memory callData, uint256 minLength)
        private
        view
        returns (bytes memory data)
    {
        // AUDIT:HCABI-002 fail-closed on staticcall failure
        (bool ok, bytes memory raw) = target.staticcall(callData);
        if (!ok) revert HyperCoreCallFailed(target, raw);
        if (raw.length < minLength) revert HyperCoreInvalidResponse(target, raw.length);
        return raw;
    }

    function _sliceToUint32(bytes32 value) private pure returns (uint32 key) {
        key = uint32(bytes4(value));
    }
}
