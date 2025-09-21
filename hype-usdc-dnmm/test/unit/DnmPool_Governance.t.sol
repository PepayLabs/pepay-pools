// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract DnmPoolGovernanceTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
    }

    function test_onlyGovernance_updates() public {
        vm.prank(alice);
        vm.expectRevert(bytes(Errors.NOT_GOVERNANCE));
        pool.updateParams(DnmPool.ParamKind.Fee, abi.encode(defaultFeeConfig()));
    }

    function test_pause_and_unpause() public {
        vm.prank(pauser);
        pool.pause();

        vm.prank(alice);
        vm.expectRevert(bytes(Errors.PAUSED));
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

        vm.expectRevert(bytes(Errors.ORACLE_STALE));
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
        vm.expectRevert(bytes(Errors.NOT_GOVERNANCE));
        pool.setTargetBaseXstar(targetBase - 1 ether);

        uint128 thresholdDelta = uint128((uint256(targetBase) * thresholdBps) / 10_000);
        uint128 nearTarget = targetBase - (thresholdDelta > 0 ? thresholdDelta - 1 : 0);

        vm.prank(gov);
        vm.expectRevert("THRESHOLD");
        pool.setTargetBaseXstar(nearTarget);

        uint128 farDelta = uint128((uint256(targetBase) * (thresholdBps + 100)) / 10_000);
        uint128 farTarget = targetBase > farDelta ? targetBase - farDelta : targetBase / 2;

        vm.prank(gov);
        pool.setTargetBaseXstar(farTarget);
    }
}
