// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";

contract FeePolicyTest is Test {
    FeePolicy.FeeConfig internal cfg;
    FeePolicy.FeeState internal state;

    function setUp() public {
        cfg = FeePolicy.FeeConfig({
            baseBps: 25,
            alphaConfNumerator: 60,
            alphaConfDenominator: 100,
            betaInvDevNumerator: 12,
            betaInvDevDenominator: 100,
            capBps: 250,
            decayPctPerBlock: 20
        });
    }

    function test_fee_base_only_calm() public {
        (uint16 feeBps, FeePolicy.FeeState memory newState) = FeePolicy.preview(state, cfg, 0, 0, block.number);
        assertEq(feeBps, cfg.baseBps, "base fee");
        assertEq(newState.lastFeeBps, cfg.baseBps, "state last fee");
    }

    function test_fee_slopes_monotonic_conf() public {
        (uint16 feeLow,) = FeePolicy.preview(state, cfg, 10, 0, block.number);
        (uint16 feeHigh,) = FeePolicy.preview(state, cfg, 100, 0, block.number);
        assertGt(feeHigh, feeLow, "fee should increase with conf");
    }

    function test_fee_slopes_monotonic_inventory() public {
        (uint16 feeLow,) = FeePolicy.preview(state, cfg, 0, 100, block.number);
        (uint16 feeHigh,) = FeePolicy.preview(state, cfg, 0, 1000, block.number);
        assertGt(feeHigh, feeLow, "fee should increase with inventory deviation");
    }

    function test_fee_cap_enforced() public {
        (uint16 feeHigh,) = FeePolicy.preview(state, cfg, 30_000, 40_000, block.number);
        assertEq(feeHigh, cfg.capBps, "fee capped");
    }

    function test_fee_decay_over_blocks() public {
        state.lastBlock = uint64(block.number);
        state.lastFeeBps = 200;

        // After 3 blocks with zero signals we should decay toward base
        (uint16 feeNext,) = FeePolicy.preview(state, cfg, 0, 0, block.number + 3);
        assertLt(feeNext, 200, "decayed");
        assertGe(feeNext, cfg.baseBps, "not below base");
    }

    function test_settle_updates_state() public {
        uint16 fee = FeePolicy.settle(state, cfg, 200, 300);
        assertEq(state.lastFeeBps, fee, "state updated");
        assertEq(state.lastBlock, uint64(block.number), "block updated");
    }
}
