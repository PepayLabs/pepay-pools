// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DnmPool} from "../../contracts/DnmPool.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract RebatesFloorPreserveTest is BaseTest {
    uint16 private constant BASE_FEE_BPS = 40;
    uint16 private constant FLOOR_BPS = 35;

    function setUp() public {
        setUpBase();

        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        feeCfg.baseBps = BASE_FEE_BPS;
        feeCfg.capBps = 100;
        feeCfg.gammaSizeLinBps = 0;
        feeCfg.gammaSizeQuadBps = 0;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Fee, abi.encode(feeCfg));

        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.alphaBboBps = 0;
        makerCfg.betaFloorBps = FLOOR_BPS;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Maker, abi.encode(makerCfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableRebates = true;
        flags.enableBboFloor = true;
        setFeatureFlags(flags);
    }

    function test_governanceSetsDiscountAndEmits() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit DnmPool.AggregatorDiscountUpdated(alice, 3);
        vm.prank(gov);
        pool.setAggregatorRouter(alice, true);
        assertEq(pool.aggregatorDiscount(alice), 3, "rebate recorded");
    }

    function test_disableClearsDiscount() public {
        vm.startPrank(gov);
        pool.setAggregatorRouter(alice, true);
        pool.setAggregatorRouter(alice, false);
        vm.stopPrank();

        assertEq(pool.aggregatorDiscount(alice), 0, "discount cleared");
    }

    function test_discountAppliedButNotBelowFloor() public {
        vm.prank(gov);
        pool.setAggregatorRouter(alice, true);

        DnmPool.QuoteResult memory noRebate = _quoteFor(bob);
        DnmPool.QuoteResult memory withRebate = _quoteFor(alice);

        assertEq(noRebate.feeBpsUsed - withRebate.feeBpsUsed, 3, "discount delta");
        assertGe(withRebate.feeBpsUsed, FLOOR_BPS, "floor respected");
    }

    function test_floorClampsRebateWhenHigher() public {
        vm.prank(gov);
        pool.setAggregatorRouter(alice, true);

        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.alphaBboBps = 0;
        makerCfg.betaFloorBps = BASE_FEE_BPS + 10; // force clamp above discount-adjusted fee
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Maker, abi.encode(makerCfg));

        DnmPool.QuoteResult memory withRebate = _quoteFor(alice);
        assertEq(withRebate.feeBpsUsed, makerCfg.betaFloorBps, "floor clamps rebate");
    }

    function test_flagMustBeEnabled() public {
        vm.prank(gov);
        pool.setAggregatorRouter(alice, true);

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableRebates = false;
        setFeatureFlags(flags);

        DnmPool.QuoteResult memory baseline = _quoteFor(bob);
        DnmPool.QuoteResult memory withFlagOff = _quoteFor(alice);
        assertEq(withFlagOff.feeBpsUsed, baseline.feeBpsUsed, "no discount when disabled");
    }

    function _quoteFor(address caller) internal returns (DnmPool.QuoteResult memory) {
        vm.prank(caller);
        return pool.quoteSwapExactIn(10_000 ether, true, IDnmPool.OracleMode.Spot, bytes(""));
    }
}
