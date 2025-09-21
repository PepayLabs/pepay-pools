// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapterHC} from "../interfaces/IOracleAdapterHC.sol";

contract MockOracleHC is IOracleAdapterHC {
    MidResult public spot;
    BidAskResult public book;
    MidResult public ema;

    function setSpot(uint256 mid, uint256 ageSec, bool success) external {
        spot = MidResult({mid: mid, ageSec: ageSec, success: success});
    }

    function setBidAsk(uint256 bid, uint256 ask, uint256 spreadBps, bool success) external {
        book = BidAskResult({bid: bid, ask: ask, spreadBps: spreadBps, success: success});
    }

    function setEma(uint256 mid, uint256 ageSec, bool success) external {
        ema = MidResult({mid: mid, ageSec: ageSec, success: success});
    }

    function readMidAndAge() external view override returns (MidResult memory) {
        return spot;
    }

    function readBidAsk() external view override returns (BidAskResult memory) {
        return book;
    }

    function readMidEmaFallback() external view override returns (MidResult memory) {
        return ema;
    }
}
