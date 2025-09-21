// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapterPyth} from "../interfaces/IOracleAdapterPyth.sol";

contract MockOraclePyth is IOracleAdapterPyth {
    PythResult public result;
    uint256 public computedMid;
    uint256 public computedAge;
    uint256 public computedConf;

    function setResult(PythResult memory newResult, uint256 mid, uint256 age, uint256 conf) external {
        result = newResult;
        computedMid = mid;
        computedAge = age;
        computedConf = conf;
    }

    function readPythUsdMid(bytes calldata) external payable override returns (PythResult memory) {
        return result;
    }

    function computePairMid(PythResult memory) external view override returns (uint256 mid, uint256 ageSec, uint256 confBps) {
        return (computedMid, computedAge, computedConf);
    }
}
