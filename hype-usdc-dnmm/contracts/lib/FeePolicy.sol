// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMath} from "./FixedPointMath.sol";

library FeePolicy {
    using FixedPointMath for uint256;

    uint256 private constant HUNDRED = 100;
    uint256 private constant DECAY_SCALE = 1e9;

    struct FeeConfig {
        uint16 baseBps;
        uint16 alphaConfNumerator;
        uint16 alphaConfDenominator;
        uint16 betaInvDevNumerator;
        uint16 betaInvDevDenominator;
        uint16 capBps;
        uint16 decayPctPerBlock; // expressed as 0-100
    }

    struct FeeState {
        uint64 lastBlock;
        uint16 lastFeeBps;
    }

    function preview(
        FeeState memory state,
        FeeConfig memory cfg,
        uint256 confBps,
        uint256 inventoryDeviationBps,
        uint256 currentBlock
    ) internal pure returns (uint16 feeBps, FeeState memory newState) {
        newState = state;

        if (newState.lastBlock == 0) {
            newState.lastBlock = uint64(currentBlock);
            newState.lastFeeBps = cfg.baseBps;
        }

        if (cfg.decayPctPerBlock > 0 && currentBlock > newState.lastBlock) {
            uint256 blocksElapsed = currentBlock - uint256(newState.lastBlock);
            if (newState.lastFeeBps > cfg.baseBps) {
                uint256 delta = newState.lastFeeBps - cfg.baseBps;
                uint256 factorNumerator = (DECAY_SCALE * (HUNDRED - cfg.decayPctPerBlock)) / HUNDRED;
                uint256 scaledMultiplier = _powScaled(factorNumerator, blocksElapsed, DECAY_SCALE);
                uint256 decayedDelta = FixedPointMath.mulDivDown(delta, scaledMultiplier, DECAY_SCALE);
                newState.lastFeeBps = uint16(cfg.baseBps + decayedDelta);
            } else {
                newState.lastFeeBps = cfg.baseBps;
            }
        }

        newState.lastBlock = uint64(currentBlock);

        uint256 confComponent = cfg.alphaConfDenominator == 0
            ? 0
            : FixedPointMath.mulDivDown(confBps, cfg.alphaConfNumerator, cfg.alphaConfDenominator);
        uint256 invComponent = cfg.betaInvDevDenominator == 0
            ? 0
            : FixedPointMath.mulDivDown(inventoryDeviationBps, cfg.betaInvDevNumerator, cfg.betaInvDevDenominator);

        uint256 fee = cfg.baseBps + confComponent + invComponent;
        if (fee > cfg.capBps) {
            fee = cfg.capBps;
        }

        newState.lastFeeBps = uint16(fee);
        feeBps = uint16(fee);
    }

    function settle(
        FeeState storage state,
        FeeConfig memory cfg,
        uint256 confBps,
        uint256 inventoryDeviationBps
    ) internal returns (uint16) {
        (uint16 feeBps, FeeState memory newState) = preview(state, cfg, confBps, inventoryDeviationBps, block.number);
        state.lastBlock = newState.lastBlock;
        state.lastFeeBps = newState.lastFeeBps;
        return feeBps;
    }

    function _powScaled(uint256 factor, uint256 exponent, uint256 scale) private pure returns (uint256 result) {
        result = scale;
        while (exponent > 0) {
            if (exponent & 1 == 1) {
                result = FixedPointMath.mulDivDown(result, factor, scale);
            }
            factor = FixedPointMath.mulDivDown(factor, factor, scale);
            exponent >>= 1;
        }
    }
}
