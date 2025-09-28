// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract ScenarioDivergenceTripwireTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
    }

    function test_divergence_blocks_and_resumes() public {
        updatePyth(12e17, 1e18, 0, 0, 20, 20);

        vm.expectRevert(Errors.OracleDiverged.selector);
        quote(1_000 ether, true, IDnmPool.OracleMode.Spot);

        updatePyth(1005e15, 1e18, 0, 0, 20, 20);

        DnmPool.QuoteResult memory res = quote(1_000 ether, true, IDnmPool.OracleMode.Spot);
        assertFalse(res.usedFallback, "no fallback");
    }
}
