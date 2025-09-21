// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracleAdapterHC {
    struct MidResult {
        uint256 mid;
        uint256 ageSec;
        bool success;
    }

    struct BidAskResult {
        uint256 bid;
        uint256 ask;
        uint256 spreadBps;
        bool success;
    }

    function readMidAndAge() external view returns (MidResult memory);

    function readBidAsk() external view returns (BidAskResult memory);

    function readMidEmaFallback() external view returns (MidResult memory);
}
