// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract FeeOrderClampOrderTest is BaseTest {
    uint16 internal constant MAX_REBATE_BPS = 3;
    address internal constant AGGREGATOR = address(0xA93);

    function setUp() public {
        setUpBase();

        // Configure fee config so LVR would saturate the cap without rebates.
        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        feeCfg.baseBps = 12;
        feeCfg.capBps = 40;
        feeCfg.gammaSizeLinBps = 0;
        feeCfg.gammaSizeQuadBps = 0;
        feeCfg.sizeFeeCapBps = 0;
        feeCfg.kappaLvrBps = 40;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Fee, abi.encode(feeCfg));

        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.betaFloorBps = 5;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Maker, abi.encode(makerCfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.blendOn = true;
        flags.enableLvrFee = true;
        flags.enableBboFloor = true;
        flags.enableRebates = true;
        setFeatureFlags(flags);

        vm.prank(gov);
        pool.setAggregatorRouter(AGGREGATOR, true);

        // Prime oracles so sigma and spread are non-zero.
        updateSpot(1e18, 2, true);
        updateBidAsk(995_000_000_000_000_000, 1_005_000_000_000_000_000, 100, true);
        updatePyth(1_003_000_000_000_000_000, 997_000_000_000_000_000, 1, 1, 40, 40);

        // Persist preview snapshot for determinism.
        pool.refreshPreviewSnapshot(IDnmPool.OracleMode.Spot, bytes(""));
    }

    function test_rebate_applies_after_floor_and_cap() public {
        uint256 amountIn = 10_000 ether;

        IDnmPool.QuoteResult memory baseQuote =
            pool.quoteSwapExactIn(amountIn, true, IDnmPool.OracleMode.Spot, bytes(""));
        // LVR should push the fee to the cap (40 bps) before rebates.
        assertEq(baseQuote.feeBpsUsed, 40, "base quote should hit cap");

        vm.prank(AGGREGATOR);
        IDnmPool.QuoteResult memory rebateQuote =
            pool.quoteSwapExactIn(amountIn, true, IDnmPool.OracleMode.Spot, bytes(""));

        // Rebate executes after the cap and floor clamps: expect exactly MAX_REBATE_BPS less
        // while still remaining above the configured floor.
        assertEq(baseQuote.feeBpsUsed - rebateQuote.feeBpsUsed, MAX_REBATE_BPS, "rebate delta");
        (, uint32 ttlMs,,) = pool.makerConfig();
        assertEq(ttlMs, defaultMakerConfig().ttlMs, "maker TTL unchanged");
        assertGe(rebateQuote.feeBpsUsed, defaultMakerConfig().betaFloorBps, "floor maintained");
    }
}
