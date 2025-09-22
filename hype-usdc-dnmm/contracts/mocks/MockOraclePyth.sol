// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapterPyth} from "../interfaces/IOracleAdapterPyth.sol";
import {FixedPointMath} from "../lib/FixedPointMath.sol";

contract MockOraclePyth is IOracleAdapterPyth {
    PythResult public result;

    function setResult(PythResult memory newResult) external {
        result = newResult;
    }

    function readPythUsdMid(bytes calldata) external payable override returns (PythResult memory) {
        return result;
    }

    function computePairMid(PythResult memory res)
        external
        pure
        override
        returns (uint256 mid, uint256 ageSec, uint256 confBps)
    {
        if (!res.success || res.usdcUsd == 0) {
            return (0, type(uint256).max, type(uint256).max);
        }
        mid = FixedPointMath.mulDivDown(res.hypeUsd, 1e18, res.usdcUsd);
        ageSec = res.ageSecHype > res.ageSecUsdc ? res.ageSecHype : res.ageSecUsdc;
        confBps = res.confBpsHype > res.confBpsUsdc ? res.confBpsHype : res.confBpsUsdc;
    }
}
