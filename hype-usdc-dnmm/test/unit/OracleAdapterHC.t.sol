// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {OracleAdapterHC} from "../../contracts/oracle/OracleAdapterHC.sol";
import {IOracleAdapterHC} from "../../contracts/interfaces/IOracleAdapterHC.sol";
import {MockHyperCore} from "../utils/Mocks.sol";

contract OracleAdapterHCTest is Test {
    OracleAdapterHC internal adapter;
    MockHyperCore internal hyperCore;

    bytes32 internal constant ASSET_BASE = keccak256("HYPE");
    bytes32 internal constant ASSET_QUOTE = keccak256("USDC");
    bytes32 internal constant MARKET = keccak256("HYPE/USDC");

    function setUp() public {
        vm.warp(1000);
        hyperCore = new MockHyperCore();
        adapter = new OracleAdapterHC(address(hyperCore), ASSET_BASE, ASSET_QUOTE, MARKET);

        uint64 ts = 995;
        hyperCore.setTOB(1e18 - 2e15, 1e18 + 2e15, 1e18, ts);
        uint64 emaTs = 997;
        hyperCore.setEMA(1e18, emaTs);
    }

    function test_readMidAndAge_ok() public {
        IOracleAdapterHC.MidResult memory res = adapter.readMidAndAge();
        assertTrue(res.success, "mid success");
        assertEq(res.mid, 1e18, "mid");
        assertEq(res.ageSec, 5, "age");
    }

    function test_spreadToConfBps_ok() public {
        IOracleAdapterHC.BidAskResult memory res = adapter.readBidAsk();
        assertTrue(res.success, "bidask success");
        assertEq(res.bid, 1e18 - 2e15, "bid");
        assertEq(res.ask, 1e18 + 2e15, "ask");
        // Spread is (ask - bid)/mid * 1e4 ≈ 40 bps
        assertEq(res.spreadBps, 40, "spread bps");
    }

    function test_stale_mid_returns_max_age() public {
        hyperCore.setTOB(9995e14, 10005e14, 1e18, uint64(block.timestamp - 600));
        IOracleAdapterHC.MidResult memory res = adapter.readMidAndAge();
        assertTrue(res.success, "mid success");
        assertEq(res.ageSec, 600, "age");
    }

    function test_spreadCap_rejects_when_bid_ask_bad() public {
        hyperCore.setTOB(0, 0, 0, uint64(block.timestamp));
        hyperCore.setEMA(0, uint64(block.timestamp));
        hyperCore.setTOB(900e14, 1200e14, 1e18, uint64(block.timestamp));
        IOracleAdapterHC.BidAskResult memory res = adapter.readBidAsk();
        assertTrue(res.success, "bidask success");
        assertGt(res.spreadBps, 2000, "large spread");
    }

    function test_emaFallback_ok() public {
        IOracleAdapterHC.MidResult memory res = adapter.readMidEmaFallback();
        assertTrue(res.success, "ema success");
        assertEq(res.mid, 1e18, "ema mid");
        assertEq(res.ageSec, 3, "ema age");
    }

    function test_decimals_scaling_rounds() public {
        uint256 mid = 50_000_000;
        uint256 diff = (mid * 2) / 1000; // 0.2%
        uint256 bid = mid - diff / 2;
        uint256 ask = mid + diff / 2;
        hyperCore.setTOB(bid, ask, mid, uint64(block.timestamp));
        IOracleAdapterHC.BidAskResult memory res = adapter.readBidAsk();
        assertTrue(res.success, "bidask success");
        assertEq(res.spreadBps, 20, "spread rounding");
    }
}
