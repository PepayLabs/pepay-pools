// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {OracleAdapterHC} from "../../contracts/oracle/OracleAdapterHC.sol";
import {IOracleAdapterHC} from "../../contracts/interfaces/IOracleAdapterHC.sol";
import {MockHyperCorePx, MockHyperCoreBbo} from "../utils/Mocks.sol";
import {HyperCoreConstants} from "../../contracts/oracle/HyperCoreConstants.sol";

contract OracleAdapterHCTest is Test {
    OracleAdapterHC internal adapter;
    bytes32 internal constant ASSET_BASE = bytes32("HYPE");
    bytes32 internal constant ASSET_QUOTE = bytes32("USDC");
    bytes32 internal constant MARKET = bytes32("HYPE");
    uint32 internal constant MARKET_KEY = uint32(bytes4(MARKET));

    function setUp() public {
        vm.warp(1000);
        _installPrecompile(address(new MockHyperCorePx()), HyperCoreConstants.ORACLE_PX_PRECOMPILE);
        _installPrecompile(address(new MockHyperCorePx()), HyperCoreConstants.MARK_PX_PRECOMPILE);
        _installPrecompile(address(new MockHyperCoreBbo()), HyperCoreConstants.BBO_PRECOMPILE);

        adapter = new OracleAdapterHC(
            HyperCoreConstants.ORACLE_PX_PRECOMPILE, ASSET_BASE, ASSET_QUOTE, MARKET
        );

        MockHyperCorePx(HyperCoreConstants.ORACLE_PX_PRECOMPILE).setResult(MARKET_KEY, 1e18, 995);
        MockHyperCorePx(HyperCoreConstants.MARK_PX_PRECOMPILE).setResult(MARKET_KEY, 1e18, 997);
        MockHyperCoreBbo(HyperCoreConstants.BBO_PRECOMPILE).setResult(
            MARKET_KEY, 1e18 - 2e15, 1e18 + 2e15
        );
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
        MockHyperCorePx(HyperCoreConstants.ORACLE_PX_PRECOMPILE).setResult(
            MARKET_KEY, 1e18, uint64(block.timestamp - 600)
        );
        IOracleAdapterHC.MidResult memory res = adapter.readMidAndAge();
        assertTrue(res.success, "mid success");
        assertEq(res.ageSec, 600, "age");
    }

    function test_spreadCap_rejects_when_bid_ask_bad() public {
        MockHyperCoreBbo(HyperCoreConstants.BBO_PRECOMPILE).setResult(
            MARKET_KEY, 900e14, 1200e14
        );
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
        MockHyperCoreBbo(HyperCoreConstants.BBO_PRECOMPILE).setResult(MARKET_KEY, bid, ask);
        IOracleAdapterHC.BidAskResult memory res = adapter.readBidAsk();
        assertTrue(res.success, "bidask success");
        assertEq(res.spreadBps, 20, "spread rounding");
    }

    function _installPrecompile(address impl, address target) internal {
        vm.etch(target, impl.code);
    }
}
