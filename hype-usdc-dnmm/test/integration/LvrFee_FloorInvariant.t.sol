// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract LvrFeeFloorInvariantTest is BaseTest {
    uint16 internal constant FLOOR_BPS = 45;

    function setUp() public {
        setUpBase();

        // Make floors aggressive so partial fills trigger easily
        DnmPool.InventoryConfig memory invCfg = defaultInventoryConfig();
        invCfg.floorBps = 9_000;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Inventory, abi.encode(invCfg));

        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.alphaBboBps = 0;
        makerCfg.betaFloorBps = FLOOR_BPS;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Maker, abi.encode(makerCfg));

        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        feeCfg.baseBps = 0;
        feeCfg.capBps = 90;
        feeCfg.gammaSizeLinBps = 0;
        feeCfg.gammaSizeQuadBps = 0;
        feeCfg.sizeFeeCapBps = 0;
        feeCfg.kappaLvrBps = 800;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Fee, abi.encode(feeCfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableBboFloor = true;
        flags.enableLvrFee = false;
        flags.enableSizeFee = false;
        flags.enableInvTilt = false;
        flags.enableAOMQ = false;
        setFeatureFlags(flags);

        // tighten liquidity so floor trips on large trades
        (, uint128 quoteRes) = pool.reserves();
        uint256 burn = (uint256(quoteRes) * 60) / 100;
        vm.prank(address(pool));
        usdc.transfer(address(0xdead), burn);
        pool.sync();

        updateSpot(1e18, 0, true);
        updateBidAsk(999e15, 1001e15, 20, true);
        updatePyth(1e18, 1e18, 0, 0, 20, 20);
    }

    function test_lvrFeeRespectsFloorAndPartialInvariant() public {
        IDnmPool.QuoteResult memory baseline =
            pool.quoteSwapExactIn(200_000 ether, true, IDnmPool.OracleMode.Spot, bytes(""));
        assertGt(baseline.partialFillAmountIn, 0, "expect partial under floor constraints");

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableLvrFee = true;
        setFeatureFlags(flags);

        // widen spread to activate LVR term
        updateBidAsk(950e15, 1050e15, 100, true);
        updatePyth(1e18, 1e18, 0, 0, 150, 150);
        rollBlocks(1);

        IDnmPool.QuoteResult memory withLvr =
            pool.quoteSwapExactIn(200_000 ether, true, IDnmPool.OracleMode.Spot, bytes(""));

        assertEq(withLvr.partialFillAmountIn, baseline.partialFillAmountIn, "solver partial fill must remain constant");
        assertGe(withLvr.feeBpsUsed, FLOOR_BPS, "fee should respect floor");
    }
}
