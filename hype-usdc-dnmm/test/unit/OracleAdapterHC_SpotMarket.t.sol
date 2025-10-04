// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {OracleAdapterHC} from "../../contracts/oracle/OracleAdapterHC.sol";
import {IOracleAdapterHC} from "../../contracts/interfaces/IOracleAdapterHC.sol";
import {MockHyperCorePx, MockHyperCoreBbo} from "../utils/Mocks.sol";
import {HyperCoreConstants} from "../../contracts/oracle/HyperCoreConstants.sol";

/// @notice Test suite for OracleAdapterHC with spot market configuration
/// @dev Verifies SPOT_PX precompile usage, price scaling, and EMA fallback behavior for spot markets
contract OracleAdapterHCSpotMarketTest is Test {
    OracleAdapterHC internal adapter;
    bytes32 internal constant ASSET_BASE = bytes32("HYPE");
    bytes32 internal constant ASSET_QUOTE = bytes32("USDC");
    bytes32 internal constant MARKET = bytes32("HYPE_USDC");
    uint32 internal constant MARKET_KEY = uint32(bytes4(MARKET));

    function setUp() public {
        vm.warp(1000);

        // Install SPOT_PX precompile for spot markets
        _installPrecompile(address(new MockHyperCorePx()), HyperCoreConstants.SPOT_PX_PRECOMPILE);
        _installPrecompile(address(new MockHyperCorePx()), HyperCoreConstants.MARK_PX_PRECOMPILE);
        _installPrecompile(address(new MockHyperCoreBbo()), HyperCoreConstants.BBO_PRECOMPILE);

        // Create spot market adapter (isSpot = true)
        adapter = new OracleAdapterHC(HyperCoreConstants.SPOT_PX_PRECOMPILE, ASSET_BASE, ASSET_QUOTE, MARKET, true);

        // Simulate HyperCore spot prices (10^6 scale)
        // Real HYPE/USDC spot: 46,559,000 (= $46.559 after scaling)
        MockHyperCorePx(HyperCoreConstants.SPOT_PX_PRECOMPILE).setResult(MARKET_KEY, uint64(46_559_000));
        MockHyperCorePx(HyperCoreConstants.MARK_PX_PRECOMPILE).setResult(MARKET_KEY, uint64(27_723)); // Wrong value (perp-only)

        // BBO spread: bid=46,540,376 ask=46,577,624 (~8 bps spread)
        MockHyperCoreBbo(HyperCoreConstants.BBO_PRECOMPILE).setResult(
            MARKET_KEY, uint64(46_540_376), uint64(46_577_624)
        );
    }

    /// @notice Verify SPOT_PX returns scaled price (10^6 → 10^18 WAD)
    function test_spotPriceScaling() public {
        IOracleAdapterHC.MidResult memory res = adapter.readMidAndAge();
        assertTrue(res.success, "mid success");

        // 46,559,000 * 10^12 = 46,559,000,000,000,000,000
        assertEq(res.mid, 46_559_000 * 1e12, "mid scaled correctly");
        assertEq(res.ageSec, type(uint256).max, "age sentinel");
    }

    /// @notice Verify BBO spread calculation with scaled prices
    function test_spotBidAskScaling() public {
        IOracleAdapterHC.BidAskResult memory res = adapter.readBidAsk();
        assertTrue(res.success, "bidask success");

        // Verify scaling applied
        assertEq(res.bid, 46_540_376 * 1e12, "bid scaled");
        assertEq(res.ask, 46_577_624 * 1e12, "ask scaled");

        // Spread = (ask - bid) / mid * 10000 ≈ 8 bps
        assertApproxEqAbs(res.spreadBps, 8, 1, "spread bps");
    }

    /// @notice Verify EMA fallback returns invalid for spot markets
    function test_spotEmaFallbackDisabled() public {
        IOracleAdapterHC.MidResult memory res = adapter.readMidEmaFallback();
        assertFalse(res.success, "ema disabled for spot");
        assertEq(res.mid, 0, "ema mid zero");
        assertEq(res.ageSec, 0, "ema age zero");
    }

    /// @notice Verify hyperCorePrecompile() returns SPOT_PX
    function test_spotPrecompileGetter() public {
        assertEq(adapter.hyperCorePrecompile(), HyperCoreConstants.SPOT_PX_PRECOMPILE, "returns SPOT_PX");
    }

    /// @notice Verify constructor rejects wrong precompile for spot
    function test_revertsOnWrongPrecompileForSpot() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAdapterHC.HyperCoreAddressMismatch.selector, HyperCoreConstants.ORACLE_PX_PRECOMPILE
            )
        );
        new OracleAdapterHC(HyperCoreConstants.ORACLE_PX_PRECOMPILE, ASSET_BASE, ASSET_QUOTE, MARKET, true);
    }

    /// @notice Verify constructor rejects SPOT_PX for perp
    function test_revertsOnSpotPrecompileForPerp() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAdapterHC.HyperCoreAddressMismatch.selector, HyperCoreConstants.SPOT_PX_PRECOMPILE
            )
        );
        new OracleAdapterHC(HyperCoreConstants.SPOT_PX_PRECOMPILE, ASSET_BASE, ASSET_QUOTE, MARKET, false);
    }

    /// @notice Fuzz test: verify scaling invariant for random spot prices
    function testFuzz_spotScalingInvariant(uint64 rawPrice) public {
        vm.assume(rawPrice > 0);
        vm.assume(rawPrice < 1e12); // Reasonable price range

        MockHyperCorePx(HyperCoreConstants.SPOT_PX_PRECOMPILE).setResult(MARKET_KEY, rawPrice);

        IOracleAdapterHC.MidResult memory res = adapter.readMidAndAge();
        assertTrue(res.success, "success");
        assertEq(res.mid, uint256(rawPrice) * 1e12, "scaling invariant");
    }

    /// @notice Verify realistic HYPE/USDC price scenario
    function test_realisticHypeUsdcPrice() public {
        // Real HyperCore SPOT_PX reading: 46,559,000 (10^6 scale)
        MockHyperCorePx(HyperCoreConstants.SPOT_PX_PRECOMPILE).setResult(MARKET_KEY, uint64(46_559_000));

        IOracleAdapterHC.MidResult memory res = adapter.readMidAndAge();
        assertTrue(res.success, "success");

        // After scaling: 46,559,000,000,000,000,000 (10^18 WAD)
        // Represents $46.559
        uint256 expectedWad = 46_559_000 * 1e12;
        assertEq(res.mid, expectedWad, "realistic HYPE price");

        // Verify price is in reasonable range ($1 - $1000)
        assertGe(res.mid, 1 * 1e18, "price >= $1");
        assertLe(res.mid, 1000 * 1e18, "price <= $1000");
    }

    /// @notice Verify tight spread scenario (high liquidity)
    function test_spotTightSpread() public {
        // Mid: 46,559,000 (10^6)
        // For 2 bps: spread = 0.0002 * 46559000 = 9311.8
        // Bid: 46,559,000 - 4,656 = 46,554,344
        // Ask: 46,559,000 + 4,656 = 46,563,656
        MockHyperCoreBbo(HyperCoreConstants.BBO_PRECOMPILE).setResult(
            MARKET_KEY, uint64(46_554_344), uint64(46_563_656)
        );

        IOracleAdapterHC.BidAskResult memory res = adapter.readBidAsk();
        assertTrue(res.success, "success");

        // Spread ≈ 2 bps (very tight)
        assertApproxEqAbs(res.spreadBps, 2, 1, "tight spread");
    }

    /// @notice Verify wide spread scenario (low liquidity)
    function test_spotWideSpread() public {
        // Mid: 46,559,000
        // Bid: 46,000,000 (120 bps below)
        // Ask: 47,000,000 (95 bps above)
        MockHyperCoreBbo(HyperCoreConstants.BBO_PRECOMPILE).setResult(
            MARKET_KEY, uint64(46_000_000), uint64(47_000_000)
        );

        IOracleAdapterHC.BidAskResult memory res = adapter.readBidAsk();
        assertTrue(res.success, "success");

        // Spread ≈ 217 bps (wide)
        assertGt(res.spreadBps, 200, "wide spread");
    }

    function _installPrecompile(address impl, address target) internal {
        vm.etch(target, impl.code);
    }
}
