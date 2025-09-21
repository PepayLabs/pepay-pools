// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapterPyth} from "./interfaces/IOracleAdapterPyth.sol";
import {MathUtils} from "./libraries/MathUtils.sol";

interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint64 publishTime;
    }

    function updatePriceFeeds(bytes[] calldata data) external payable;

    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
}

/// @notice Adapter for Pyth price feeds used as fallback and divergence guard.
contract OracleAdapterPyth is IOracleAdapterPyth {
    uint256 private constant ONE = 1e18;

    IPyth public immutable pyth;
    bytes32 public immutable priceIdHypeUsd;
    bytes32 public immutable priceIdUsdcUsd;

    constructor(address _pyth, bytes32 _priceIdHypeUsd, bytes32 _priceIdUsdcUsd) {
        pyth = IPyth(_pyth);
        priceIdHypeUsd = _priceIdHypeUsd;
        priceIdUsdcUsd = _priceIdUsdcUsd;
    }

    function readPythUsdMid(bytes calldata updateData) external payable override returns (PythResult memory) {
        if (updateData.length > 0) {
            bytes[] memory updates = abi.decode(updateData, (bytes[]));
            pyth.updatePriceFeeds{value: msg.value}(updates);
        }

        IPyth.Price memory hype = pyth.getPriceUnsafe(priceIdHypeUsd);
        IPyth.Price memory usdc = pyth.getPriceUnsafe(priceIdUsdcUsd);

        bool success = hype.price > 0 && usdc.price > 0;
        return PythResult({
            hypeUsd: success ? _scaleToWad(hype.price, hype.expo) : 0,
            usdcUsd: success ? _scaleToWad(int64(usdc.price), usdc.expo) : 0,
            ageSecHype: block.timestamp > hype.publishTime ? block.timestamp - hype.publishTime : 0,
            ageSecUsdc: block.timestamp > usdc.publishTime ? block.timestamp - usdc.publishTime : 0,
            confBpsHype: success ? _confidenceToBps(hype) : 0,
            confBpsUsdc: success ? _confidenceToBps(usdc) : 0,
            success: success
        });
    }

    function computePairMid(PythResult memory result) external pure override returns (uint256 mid, uint256 ageSec, uint256 confBps) {
        if (!result.success || result.usdcUsd == 0) {
            return (0, type(uint256).max, type(uint256).max);
        }

        mid = MathUtils.mulDivDown(result.hypeUsd, ONE, result.usdcUsd);
        ageSec = result.ageSecHype > result.ageSecUsdc ? result.ageSecHype : result.ageSecUsdc;
        confBps = result.confBpsHype > result.confBpsUsdc ? result.confBpsHype : result.confBpsUsdc;
    }

    function _scaleToWad(int64 price, int32 expo) internal pure returns (uint256) {
        require(price > 0, "PYTH_NEG");
        uint256 magnitude = uint256(int256(price));
        if (expo == 0) {
            return magnitude * ONE;
        }
        if (expo > 0) {
            uint256 factor = 10 ** uint32(uint32(expo));
            return magnitude * factor * ONE;
        }
        uint256 factorDown = 10 ** uint32(uint32(-expo));
        return magnitude * ONE / factorDown;
    }

    function _confidenceToBps(IPyth.Price memory price) internal pure returns (uint256) {
        uint256 confValue = _scaleToWad(int64(uint64(price.conf)), price.expo);
        uint256 priceValue = _scaleToWad(price.price, price.expo);
        if (priceValue == 0) return type(uint256).max;
        return MathUtils.toBps(confValue, priceValue);
    }
}
