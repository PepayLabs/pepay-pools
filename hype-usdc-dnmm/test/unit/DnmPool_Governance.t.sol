// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
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
        // make HyperCore stale to force fallback
        updateSpot(1e18, 1_000, true);
        updateEma(1e18, 5, true);

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

        vm.prank(alice);
        vm.expectRevert(bytes(Errors.NOT_GOVERNANCE));
        pool.setTargetBaseXstar(40_000 ether);

        vm.prank(gov);
        vm.expectRevert("THRESHOLD");
        pool.setTargetBaseXstar(49_000 ether);

        vm.prank(gov);
        pool.setTargetBaseXstar(40_000 ether);
    }
}
