// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";

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
        sizes[0] = 1e17;
        sizes[1] = 5e17;

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
}
