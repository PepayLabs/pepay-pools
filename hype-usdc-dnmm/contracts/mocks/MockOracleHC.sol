// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapterHC} from "../interfaces/IOracleAdapterHC.sol";

contract MockOracleHC is IOracleAdapterHC {
    enum ReadKind {
        Spot,
        Book,
        Ema
    }

    enum ResponseMode {
        Normal,
        RevertCall,
        Empty,
        Garbage
    }

    MidResult public spot;
    BidAskResult public book;
    MidResult public ema;

    ResponseMode public spotMode;
    ResponseMode public bookMode;
    ResponseMode public emaMode;

    function setSpot(uint256 mid, uint256 ageSec, bool success) external {
        spot = MidResult({mid: mid, ageSec: ageSec, success: success});
    }

    function setBidAsk(uint256 bid, uint256 ask, uint256 spreadBps, bool success) external {
        book = BidAskResult({bid: bid, ask: ask, spreadBps: spreadBps, success: success});
    }

    function setEma(uint256 mid, uint256 ageSec, bool success) external {
        ema = MidResult({mid: mid, ageSec: ageSec, success: success});
    }

    function setResponseMode(ReadKind kind, ResponseMode mode) external {
        if (kind == ReadKind.Spot) {
            spotMode = mode;
        } else if (kind == ReadKind.Book) {
            bookMode = mode;
        } else {
            emaMode = mode;
        }
    }

    function clearResponseModes() external {
        spotMode = ResponseMode.Normal;
        bookMode = ResponseMode.Normal;
        emaMode = ResponseMode.Normal;
    }

    function readMidAndAge() external view override returns (MidResult memory) {
        ResponseMode mode = spotMode;
        if (mode == ResponseMode.RevertCall) {
            revert("MockOracleHC: spot revert");
        }
        if (mode == ResponseMode.Empty) {
            return MidResult({mid: 0, ageSec: 0, success: false});
        }
        if (mode == ResponseMode.Garbage) {
            return MidResult({mid: 0, ageSec: spot.ageSec, success: true});
        }
        return spot;
    }

    function readBidAsk() external view override returns (BidAskResult memory) {
        ResponseMode mode = bookMode;
        if (mode == ResponseMode.RevertCall) {
            revert("MockOracleHC: book revert");
        }
        if (mode == ResponseMode.Empty) {
            return BidAskResult({bid: 0, ask: 0, spreadBps: 0, success: false});
        }
        if (mode == ResponseMode.Garbage) {
            uint256 bid = book.bid == 0 ? 1e18 : book.bid;
            uint256 ask = bid > 1 ? bid - 1 : 0;
            return BidAskResult({bid: bid, ask: ask, spreadBps: 0, success: true});
        }
        return book;
    }

    function readMidEmaFallback() external view override returns (MidResult memory) {
        ResponseMode mode = emaMode;
        if (mode == ResponseMode.RevertCall) {
            revert("MockOracleHC: ema revert");
        }
        if (mode == ResponseMode.Empty) {
            return MidResult({mid: 0, ageSec: 0, success: false});
        }
        if (mode == ResponseMode.Garbage) {
            return MidResult({mid: 0, ageSec: ema.ageSec, success: true});
        }
        return ema;
    }
}
