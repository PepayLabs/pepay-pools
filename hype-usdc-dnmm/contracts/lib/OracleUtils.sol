// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMath} from "./FixedPointMath.sol";

library OracleUtils {
    using FixedPointMath for uint256;

    struct OracleData {
        uint256 mid;
        uint256 bid;
        uint256 ask;
        uint256 spreadBps;
        uint256 ageSec;
        bool isValid;
        bool usedFallback;
    }

    function computeSpreadBps(uint256 bid, uint256 ask) internal pure returns (uint256) {
        if (bid == 0 || ask == 0 || ask <= bid) return 0;
        uint256 mid = (bid + ask) / 2;
        return FixedPointMath.toBps(ask - bid, mid);
    }

    function computeDivergenceBps(uint256 primaryMid, uint256 fallbackMid) internal pure returns (uint256) {
        if (primaryMid == 0 && fallbackMid == 0) {
            return 0;
        }
        if (primaryMid == 0 || fallbackMid == 0) {
            return type(uint256).max;
        }

        uint256 hi = FixedPointMath.max(primaryMid, fallbackMid);
        uint256 lo = FixedPointMath.min(primaryMid, fallbackMid);
        uint256 diff = hi - lo;
        return FixedPointMath.toBps(diff, hi);
    }
}
