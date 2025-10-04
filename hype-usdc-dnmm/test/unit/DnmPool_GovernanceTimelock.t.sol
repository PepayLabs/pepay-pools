// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract DnmPoolGovernanceTimelockTest is BaseTest {
    uint32 internal constant DELAY = 1 hours;

    function setUp() public {
        setUpBase();
    }

    function test_queueExecuteAfterDelay() public {
        vm.prank(gov);
        pool.updateParams(
            IDnmPool.ParamKind.Governance, abi.encode(DnmPool.GovernanceConfig({timelockDelaySec: DELAY}))
        );

        FeePolicy.FeeConfig memory newCfg = defaultFeeConfig();
        newCfg.baseBps = 25;

        vm.prank(gov);
        vm.expectRevert(Errors.TimelockRequired.selector);
        pool.updateParams(IDnmPool.ParamKind.Fee, abi.encode(newCfg));

        vm.prank(gov);
        uint40 eta = pool.queueParams(IDnmPool.ParamKind.Fee, abi.encode(newCfg));
        assertGt(eta, 0, "eta set");

        vm.prank(gov);
        vm.expectRevert(abi.encodeWithSelector(Errors.TimelockNotElapsed.selector, eta));
        pool.executeParams(IDnmPool.ParamKind.Fee);

        warpTo(block.timestamp + DELAY + 1);

        vm.prank(gov);
        pool.executeParams(IDnmPool.ParamKind.Fee);

        (uint16 baseBps,,,,,,,,,,) = pool.feeConfig();
        assertEq(baseBps, newCfg.baseBps, "timelocked update applied");
    }

    function test_queueImmediateWhenDelayZero() public {
        FeePolicy.FeeConfig memory newCfg = defaultFeeConfig();
        newCfg.baseBps = 22;

        vm.prank(gov);
        uint40 eta = pool.queueParams(IDnmPool.ParamKind.Fee, abi.encode(newCfg));
        assertEq(eta, 0, "no timelock: eta zero");

        (uint16 baseBps,,,,,,,,,,) = pool.feeConfig();
        assertEq(baseBps, newCfg.baseBps, "update applied immediately");
    }

    function test_cancelClearsPending() public {
        vm.prank(gov);
        pool.updateParams(
            IDnmPool.ParamKind.Governance, abi.encode(DnmPool.GovernanceConfig({timelockDelaySec: DELAY}))
        );

        FeePolicy.FeeConfig memory newCfg = defaultFeeConfig();
        newCfg.baseBps = 28;

        vm.prank(gov);
        pool.queueParams(IDnmPool.ParamKind.Fee, abi.encode(newCfg));

        vm.prank(gov);
        pool.cancelParams(IDnmPool.ParamKind.Fee);

        warpTo(block.timestamp + DELAY + 1);

        vm.prank(gov);
        vm.expectRevert(Errors.ParamNotQueued.selector);
        pool.executeParams(IDnmPool.ParamKind.Fee);
    }
}
