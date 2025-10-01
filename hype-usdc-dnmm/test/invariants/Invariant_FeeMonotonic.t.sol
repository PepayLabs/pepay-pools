// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";

contract InvariantFeeMonotonic is StdInvariant {
    FeeHandler internal handler;

    function setUp() public {
        handler = new FeeHandler();
        targetContract(address(handler));
    }

    function invariant_fee_within_bounds() public view {
        (uint16 baseBps,,,,,) = handler.config();
        uint16 capBps = handler.cap();
        uint16 current = handler.lastFee();
        require(current >= baseBps, "fee below base");
        require(current <= capBps, "fee above cap");
    }
}

contract FeeHandler {
    using FeePolicy for FeePolicy.FeeState;

    FeePolicy.FeeConfig internal cfg;
    FeePolicy.FeeState internal state;
    uint256 internal lastConf;
    uint256 internal lastInv;
    uint16 internal lastFeeBps;

    constructor() {
        cfg = FeePolicy.FeeConfig({
            baseBps: 15,
            alphaConfNumerator: 80,
            alphaConfDenominator: 100,
            betaInvDevNumerator: 10,
            betaInvDevDenominator: 100,
            capBps: 250,
            decayPctPerBlock: 15,
            gammaSizeLinBps: 0,
            gammaSizeQuadBps: 0,
            sizeFeeCapBps: 0
        });
        lastConf = 0;
        lastInv = 0;
        lastFeeBps = cfg.baseBps;
    }

    function increaseConf(uint256 step) external {
        step = _bound(step, 1, 500);
        uint256 newConf = lastConf + step;
        (uint16 fee, FeePolicy.FeeState memory previewState) =
            FeePolicy.preview(state, cfg, newConf, lastInv, block.number);
        require(fee >= lastFeeBps, "fee should grow with conf");
        state = previewState;
        lastConf = newConf;
        lastFeeBps = fee;
    }

    function increaseInv(uint256 step) external {
        step = _bound(step, 1, 1000);
        uint256 newInv = lastInv + step;
        (uint16 fee, FeePolicy.FeeState memory previewState) =
            FeePolicy.preview(state, cfg, lastConf, newInv, block.number);
        require(fee >= lastFeeBps, "fee should grow with inv");
        state = previewState;
        lastInv = newInv;
        lastFeeBps = fee;
    }

    function decay(uint256 blocksForward) external {
        blocksForward = _bound(blocksForward, 1, 20);
        uint256 targetBlock = block.number + blocksForward;
        (uint16 fee, FeePolicy.FeeState memory previewState) =
            FeePolicy.preview(state, cfg, lastConf, lastInv, targetBlock);
        require(fee <= lastFeeBps, "decay should not increase fee");
        state = previewState;
        lastFeeBps = fee;
    }

    function config() external view returns (uint16 baseBps, uint16, uint16, uint16, uint16, uint16 capBps) {
        return (
            cfg.baseBps,
            cfg.alphaConfNumerator,
            cfg.alphaConfDenominator,
            cfg.betaInvDevNumerator,
            cfg.betaInvDevDenominator,
            cfg.capBps
        );
    }

    function cap() external view returns (uint16) {
        return cfg.capBps;
    }

    function lastFee() external view returns (uint16) {
        return lastFeeBps;
    }

    function _bound(uint256 value, uint256 minVal, uint256 maxVal) internal pure returns (uint256) {
        if (value < minVal) return minVal;
        if (value > maxVal) return maxVal;
        return value;
    }
}
