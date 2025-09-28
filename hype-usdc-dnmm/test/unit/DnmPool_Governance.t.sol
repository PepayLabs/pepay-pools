// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract DnmPoolGovernanceTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
    }

    function test_onlyGovernance_updates() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NotGovernance.selector);
        pool.updateParams(DnmPool.ParamKind.Fee, abi.encode(defaultFeeConfig()));
    }

    function test_pause_and_unpause() public {
        vm.prank(pauser);
        pool.pause();

        vm.prank(alice);
        vm.expectRevert(Errors.PoolPaused.selector);
        pool.swapExactIn(100 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        vm.prank(gov);
        pool.unpause();

        vm.prank(alice);
        pool.swapExactIn(100 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
    }

    function test_update_mode_strict_relaxed() public {
        // make HyperCore spread unacceptable while still fresh so EMA path is required
        updateSpot(1e18, 2, true);
        updateBidAsk(90e16, 110e16, 2_000, true);
        updateEma(1e18, 1, true);

        IOracleAdapterPyth.PythResult memory pythFail;
        pythFail.success = false;
        oraclePyth.setResult(pythFail);

        DnmPool.OracleConfig memory strictCfg = strictOracleConfig();
        strictCfg.allowEmaFallback = false;

        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Oracle, abi.encode(strictCfg));

        vm.expectRevert(Errors.OracleSpread.selector);
        quote(1_000 ether, true, IDnmPool.OracleMode.Spot);

        DnmPool.OracleConfig memory relaxed = strictCfg;
        relaxed.allowEmaFallback = true;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Oracle, abi.encode(relaxed));

        DnmPool.QuoteResult memory res = quote(1_000 ether, true, IDnmPool.OracleMode.Spot);
        assertTrue(res.usedFallback, "fallback used");
        assertEq(res.reason, bytes32("EMA"), "ema reason");
    }

    function test_setTargetBaseXstar_guarded() public {
        vm.prank(alice);
        pool.swapExactIn(100 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        (uint128 targetBase,, uint16 thresholdBps) = pool.inventoryConfig();

        vm.prank(alice);
        vm.expectRevert(Errors.NotGovernance.selector);
        pool.setTargetBaseXstar(targetBase - 1 ether);

        uint128 thresholdDelta = uint128((uint256(targetBase) * thresholdBps) / 10_000);
        uint128 nearTarget = targetBase - (thresholdDelta > 0 ? thresholdDelta - 1 : 0);

        vm.prank(gov);
        vm.expectRevert(Errors.RecenterThreshold.selector);
        pool.setTargetBaseXstar(nearTarget);

        uint128 farDelta = uint128((uint256(targetBase) * (thresholdBps + 100)) / 10_000);
        uint128 farTarget = targetBase > farDelta ? targetBase - farDelta : targetBase / 2;

        vm.prank(gov);
        pool.setTargetBaseXstar(farTarget);
    }

    function test_oracle_config_guard_enforced() public {
        DnmPool.OracleConfig memory cfg = defaultOracleConfig();
        cfg.confCapBpsStrict = cfg.confCapBpsSpot + 1;

        vm.prank(gov);
        vm.expectRevert(Errors.InvalidConfig.selector);
        pool.updateParams(DnmPool.ParamKind.Oracle, abi.encode(cfg));
    }

    function test_inventory_config_guard_enforced() public {
        DnmPool.InventoryConfig memory cfg = defaultInventoryConfig();
        cfg.floorBps = 6000;

        vm.prank(gov);
        vm.expectRevert(Errors.InvalidConfig.selector);
        pool.updateParams(DnmPool.ParamKind.Inventory, abi.encode(cfg));
    }

    function test_fee_config_guard_enforced() public {
        FeePolicy.FeeConfig memory cfg = defaultFeeConfig();
        cfg.capBps = cfg.baseBps - 1;

        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(FeePolicy.FeeBaseAboveCap.selector, cfg.baseBps, cfg.capBps));
        pool.updateParams(DnmPool.ParamKind.Fee, abi.encode(cfg));
    }

    function test_sequential_updates_leave_pool_operational() public {
        DnmPool.OracleConfig memory oracleCfg = defaultOracleConfig();
        oracleCfg.maxAgeSec = 30;

        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Oracle, abi.encode(oracleCfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.debugEmit = false;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Feature, abi.encode(flags));

        updateSpot(1e18, 10, true);
        updateBidAsk(999e15, 1_001e18, 30, true);
        updateEma(1e18, 5, true);

        DnmPool.QuoteResult memory res = quote(5 ether, true, IDnmPool.OracleMode.Spot);
        assertGt(res.amountOut, 0, "quote succeeds post updates");

        // restore debug flag to avoid surprising later tests
        flags.debugEmit = true;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Feature, abi.encode(flags));
    }
}
