// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";

contract FeePolicyTest is Test {
    FeePolicy.FeeConfig internal cfg;
    FeePolicy.FeeState internal state;

    function setUp() public {
        cfg = FeePolicy.FeeConfig({
            baseBps: 15,
            alphaConfNumerator: 60,
            alphaConfDenominator: 100,
            betaInvDevNumerator: 10,
            betaInvDevDenominator: 100,
            capBps: 150,
            decayPctPerBlock: 20
        });
    }

    function testBaseFeeNoSignals() public {
        (uint16 feeBps, FeePolicy.FeeState memory newState) = FeePolicy.preview(state, cfg, 0, 0, block.number);
        assertEq(feeBps, 15);
        assertEq(newState.lastFeeBps, 15);
    }

    function testFeeCapsWithSignals() public {
        (uint16 feeBps,) = FeePolicy.preview(state, cfg, 500, 5000, block.number);
        assertEq(feeBps, 150, "should cap to max");
    }

    function testDecayTowardBase() public {
        state.lastBlock = uint64(block.number);
        state.lastFeeBps = 150;

        // advance two blocks
        (uint16 feeAfter,) = FeePolicy.preview(state, cfg, 0, 0, block.number + 2);
        assertLt(feeAfter, 150);
        assertGt(feeAfter, 15);
    }
}
