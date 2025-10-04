// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {MockOraclePyth} from "../../contracts/mocks/MockOraclePyth.sol";

contract PreviewViewPurityTest is BaseTest {
    function setUp() public {
        setUpBase();
        DnmPool.PreviewConfig memory cfg = defaultPreviewConfig();
        cfg.enablePreviewFresh = true;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Preview, abi.encode(cfg));
        vm.prank(alice);
        pool.refreshPreviewSnapshot(IDnmPool.OracleMode.Spot, bytes(""));
    }

    function test_previewFunctionsDoNotWrite() public {
        uint256[] memory sizes = new uint256[](2);
        sizes[0] = 100_000_000_000_000_000;
        sizes[1] = 500_000_000_000_000_000;

        vm.record();
        pool.previewFees(sizes);
        (, bytes32[] memory writes) = vm.accesses(address(pool));
        assertEq(writes.length, 0, "previewFees should be view-only");

        vm.record();
        pool.previewFeesFresh(IDnmPool.OracleMode.Spot, bytes(""), sizes);
        (, writes) = vm.accesses(address(pool));
        assertEq(writes.length, 0, "previewFeesFresh should be view-only");

        vm.record();
        pool.previewLadder(0);
        (, writes) = vm.accesses(address(pool));
        assertEq(writes.length, 0, "previewLadder should be view-only");
    }

    function test_previewFreshSkipsPythWhenHealthy() public {
        oraclePyth.setForcePeekRevert(true);

        uint256[] memory sizes = new uint256[](1);
        sizes[0] = 2e17;
        pool.previewFeesFresh(IDnmPool.OracleMode.Spot, bytes(""), sizes);

        oraclePyth.setForcePeekRevert(false);
    }

    function test_previewFreshRequiresPythWhenFallback() public {
        oraclePyth.setForcePeekRevert(true);
        updateSpot(0, 0, false);
        updateEma(0, 0, false);

        uint256[] memory sizes = new uint256[](1);
        sizes[0] = 3e17;
        vm.expectRevert(MockOraclePyth.ForcedPeek.selector);
        pool.previewFeesFresh(IDnmPool.OracleMode.Spot, bytes(""), sizes);

        oraclePyth.setForcePeekRevert(false);
    }
}
