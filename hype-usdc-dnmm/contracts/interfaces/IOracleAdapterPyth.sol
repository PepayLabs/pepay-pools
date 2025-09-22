// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracleAdapterPyth {
    struct PythResult {
        uint256 hypeUsd;
        uint256 usdcUsd;
        uint256 ageSecHype;
        uint256 ageSecUsdc;
        uint256 confBpsHype;
        uint256 confBpsUsdc;
        bool success;
    }

    function readPythUsdMid(bytes calldata updateData) external payable returns (PythResult memory);

    function computePairMid(PythResult memory result)
        external
        pure
        returns (uint256 mid, uint256 ageSec, uint256 confBps);
}
