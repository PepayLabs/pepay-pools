// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

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

    function test_pack_unpack_round_trip() public {
        uint256 packed = FeePolicy.pack(cfg);
        FeePolicy.FeeConfig memory unpacked = FeePolicy.unpack(packed);

        assertEq(unpacked.baseBps, cfg.baseBps, "base");
        assertEq(unpacked.alphaConfNumerator, cfg.alphaConfNumerator, "alpha num");
        assertEq(unpacked.alphaConfDenominator, cfg.alphaConfDenominator, "alpha den");
        assertEq(unpacked.betaInvDevNumerator, cfg.betaInvDevNumerator, "beta num");
        assertEq(unpacked.betaInvDevDenominator, cfg.betaInvDevDenominator, "beta den");
        assertEq(unpacked.capBps, cfg.capBps, "cap");
        assertEq(unpacked.decayPctPerBlock, cfg.decayPctPerBlock, "decay");
    }

    function test_preview_packed_matches_struct() public {
        uint256 packed = FeePolicy.pack(cfg);
        (uint16 feePacked, FeePolicy.FeeState memory packedState) =
            FeePolicy.previewPacked(state, packed, 45, 123, block.number + 1);
        (uint16 feeStruct, FeePolicy.FeeState memory structState) =
            FeePolicy.preview(state, cfg, 45, 123, block.number + 1);

        assertEq(feePacked, feeStruct, "fee match");
        assertEq(packedState.lastFeeBps, structState.lastFeeBps, "state fee");
        assertEq(packedState.lastBlock, structState.lastBlock, "state block");
    }
}
