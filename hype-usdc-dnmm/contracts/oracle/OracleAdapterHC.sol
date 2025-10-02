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
    uint256 internal immutable PRICE_SCALE_DIVISOR_;
    bool internal immutable IS_SPOT_MARKET_;

    uint256 private constant AGE_UNKNOWN = type(uint256).max;
    uint256 private constant WAD = 1e18;
    uint256 private constant SPOT_SCALE_MULTIPLIER = 1e12; // Scale 10^6 → 10^18 WAD for spot

    error HyperCoreAddressMismatch(address provided);
    error HyperCoreCallFailed(address target, bytes data);
    error HyperCoreInvalidResponse(address target, uint256 length);
    error PrecompileZero();
    error AssetIdZero();
    error MarketIdZero();

    constructor(
        address _precompile,
        bytes32 _assetIdBase,
        bytes32 _assetIdQuote,
        bytes32 _marketId,
        bool _isSpot
    ) {
        if (_precompile == address(0)) revert PrecompileZero();

        // AUDIT:HCABI-001 enforce canonical oracle precompile wiring based on market type
        if (_isSpot) {
            if (_precompile != HyperCoreConstants.SPOT_PX_PRECOMPILE) {
                revert HyperCoreAddressMismatch(_precompile);
            }
        } else {
            if (_precompile != HyperCoreConstants.ORACLE_PX_PRECOMPILE) {
                revert HyperCoreAddressMismatch(_precompile);
            }
        }

        if (_assetIdBase == bytes32(0) || _assetIdQuote == bytes32(0)) revert AssetIdZero();
        if (_marketId == bytes32(0)) revert MarketIdZero();
        IS_SPOT_MARKET_ = _isSpot;
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
        return IS_SPOT_MARKET_
            ? HyperCoreConstants.SPOT_PX_PRECOMPILE
            : HyperCoreConstants.ORACLE_PX_PRECOMPILE;
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
        bytes memory callData = abi.encodePacked(MARKET_KEY_);
        // AUDIT:HCABI-001 canonical precompile selection: SPOT_PX (0x0808) for spot, ORACLE_PX (0x0807) for perp
        address precompile = IS_SPOT_MARKET_
            ? HyperCoreConstants.SPOT_PX_PRECOMPILE
            : HyperCoreConstants.ORACLE_PX_PRECOMPILE;

        bytes memory data = _callHyperCore(precompile, callData, 8);

        uint64 midWord;
        if (data.length == 8) {
            midWord = uint64(bytes8(data));
        } else if (data.length == 32) {
            midWord = abi.decode(data, (uint64));
        } else {
            revert HyperCoreInvalidResponse(precompile, data.length);
        }

        // Scale spot prices: HyperCore returns 10^6, contract expects 10^18 WAD
        uint256 scaledMid = IS_SPOT_MARKET_
            ? uint256(midWord) * SPOT_SCALE_MULTIPLIER
            : uint256(midWord);

        return MidResult(scaledMid, AGE_UNKNOWN, true);
    }

    function readBidAsk() external view override returns (BidAskResult memory result) {
        bytes memory callData = abi.encodePacked(MARKET_KEY_);
        // AUDIT:HCABI-001 canonical bbo precompile for bid/ask spread
        bytes memory data = _callHyperCore(HyperCoreConstants.BBO_PRECOMPILE, callData, 16);

        uint64 bidWord;
        uint64 askWord;
        if (data.length == 16) {
            assembly ("memory-safe") {
                let word := mload(add(data, 0x20))
                bidWord := shr(192, word)
                askWord := and(shr(128, word), 0xFFFFFFFFFFFFFFFF)
            }
        } else if (data.length == 64) {
            (bidWord, askWord) = abi.decode(data, (uint64, uint64));
        } else {
            revert HyperCoreInvalidResponse(HyperCoreConstants.BBO_PRECOMPILE, data.length);
        }

        // Scale spot prices: HyperCore returns 10^6, contract expects 10^18 WAD
        uint256 bid = IS_SPOT_MARKET_
            ? uint256(bidWord) * SPOT_SCALE_MULTIPLIER
            : uint256(bidWord);
        uint256 ask = IS_SPOT_MARKET_
            ? uint256(askWord) * SPOT_SCALE_MULTIPLIER
            : uint256(askWord);

        uint256 spreadBps = OracleUtils.computeSpreadBps(bid, ask);
        return BidAskResult(bid, ask, spreadBps, true);
    }

    function readMidEmaFallback() external view override returns (MidResult memory result) {
        // AUDIT:HCABI-001 EMA fallback (MARK_PX) only works for perp markets, not spot
        if (IS_SPOT_MARKET_) {
            return MidResult(0, 0, false);
        }

        bytes memory callData = abi.encodePacked(MARKET_KEY_);
        // AUDIT:HCABI-001 canonical markPx precompile used as EMA fallback for perp markets
        bytes memory data = _callHyperCore(HyperCoreConstants.MARK_PX_PRECOMPILE, callData, 8);

        uint64 emaMidWord;
        if (data.length == 8) {
            emaMidWord = uint64(bytes8(data));
        } else if (data.length == 32) {
            emaMidWord = abi.decode(data, (uint64));
        } else {
            revert HyperCoreInvalidResponse(HyperCoreConstants.MARK_PX_PRECOMPILE, data.length);
        }
        return MidResult(uint256(emaMidWord), AGE_UNKNOWN, true);
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
