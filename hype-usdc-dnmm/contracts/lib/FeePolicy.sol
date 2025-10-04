// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMath} from "./FixedPointMath.sol";

library FeePolicy {
    using FixedPointMath for uint256;

    error FeeCapTooHigh(uint16 capBps); // AUDIT:ORFQ-002 guard cap < 100%
    error FeeBaseAboveCap(uint16 baseBps, uint16 capBps); // AUDIT:ORFQ-002 base must not exceed cap

    uint256 private constant HUNDRED = 100;
    uint256 private constant DECAY_SCALE = 1e9;
    uint256 private constant MASK_16 = 0xFFFF;
    uint256 private constant MASK_32 = 0xFFFFFFFF;

    uint256 private constant OFFSET_ALPHA_CONF_NUM = 16;
    uint256 private constant OFFSET_ALPHA_CONF_DEN = 32;
    uint256 private constant OFFSET_BETA_INV_NUM = 48;
    uint256 private constant OFFSET_BETA_INV_DEN = 64;
    uint256 private constant OFFSET_CAP_BPS = 80;
    uint256 private constant OFFSET_DECAY_PCT = 96;
    uint256 private constant OFFSET_DECAY_FACTOR = 112;
    uint256 private constant OFFSET_GAMMA_SIZE_LIN = 144;
    uint256 private constant OFFSET_GAMMA_SIZE_QUAD = 160;
    uint256 private constant OFFSET_SIZE_FEE_CAP = 176;
    uint256 private constant OFFSET_KAPPA_LVR_BPS = 192;

    struct FeeConfig {
        uint16 baseBps;
        uint16 alphaConfNumerator;
        uint16 alphaConfDenominator;
        uint16 betaInvDevNumerator;
        uint16 betaInvDevDenominator;
        uint16 capBps;
        uint16 decayPctPerBlock; // expressed as 0-100
        uint16 gammaSizeLinBps;
        uint16 gammaSizeQuadBps;
        uint16 sizeFeeCapBps;
        uint16 kappaLvrBps;
    }

    struct FeeState {
        uint64 lastBlock;
        uint16 lastFeeBps;
    }

    function pack(FeeConfig memory cfg) internal pure returns (uint256 packed) {
        if (cfg.capBps >= 10_000) revert FeeCapTooHigh(cfg.capBps);
        if (cfg.baseBps > cfg.capBps) revert FeeBaseAboveCap(cfg.baseBps, cfg.capBps);
        if (cfg.sizeFeeCapBps >= 10_000) revert FeeCapTooHigh(cfg.sizeFeeCapBps);
        if (cfg.sizeFeeCapBps > cfg.capBps) {
            cfg.sizeFeeCapBps = cfg.capBps;
        }
        if (cfg.kappaLvrBps >= 10_000) revert FeeCapTooHigh(cfg.kappaLvrBps);

        packed = uint256(cfg.baseBps);
        packed |= uint256(cfg.alphaConfNumerator) << OFFSET_ALPHA_CONF_NUM;
        packed |= uint256(cfg.alphaConfDenominator) << OFFSET_ALPHA_CONF_DEN;
        packed |= uint256(cfg.betaInvDevNumerator) << OFFSET_BETA_INV_NUM;
        packed |= uint256(cfg.betaInvDevDenominator) << OFFSET_BETA_INV_DEN;
        packed |= uint256(cfg.capBps) << OFFSET_CAP_BPS;
        packed |= uint256(cfg.decayPctPerBlock) << OFFSET_DECAY_PCT;

        uint256 decayFactor = (DECAY_SCALE * (HUNDRED - cfg.decayPctPerBlock)) / HUNDRED;
        packed |= decayFactor << OFFSET_DECAY_FACTOR;
        packed |= uint256(cfg.gammaSizeLinBps) << OFFSET_GAMMA_SIZE_LIN;
        packed |= uint256(cfg.gammaSizeQuadBps) << OFFSET_GAMMA_SIZE_QUAD;
        packed |= uint256(cfg.sizeFeeCapBps) << OFFSET_SIZE_FEE_CAP;
        packed |= uint256(cfg.kappaLvrBps) << OFFSET_KAPPA_LVR_BPS;
    }

    function unpack(uint256 packed) internal pure returns (FeeConfig memory cfg) {
        (
            uint16 baseBps,
            uint16 alphaConfNumerator,
            uint16 alphaConfDenominator,
            uint16 betaInvDevNumerator,
            uint16 betaInvDevDenominator,
            uint16 capBps,
            uint16 decayPctPerBlock
        ) = decode(packed);
        (uint16 gammaSizeLinBps, uint16 gammaSizeQuadBps, uint16 sizeFeeCapBps) = decodeSizeFee(packed);

        cfg = FeeConfig({
            baseBps: baseBps,
            alphaConfNumerator: alphaConfNumerator,
            alphaConfDenominator: alphaConfDenominator,
            betaInvDevNumerator: betaInvDevNumerator,
            betaInvDevDenominator: betaInvDevDenominator,
            capBps: capBps,
            decayPctPerBlock: decayPctPerBlock,
            gammaSizeLinBps: gammaSizeLinBps,
            gammaSizeQuadBps: gammaSizeQuadBps,
            sizeFeeCapBps: sizeFeeCapBps,
            kappaLvrBps: uint16((packed >> OFFSET_KAPPA_LVR_BPS) & MASK_16)
        });
    }

    function decodeSizeFee(uint256 packed)
        internal
        pure
        returns (uint16 gammaSizeLinBps, uint16 gammaSizeQuadBps, uint16 sizeFeeCapBps)
    {
        gammaSizeLinBps = uint16((packed >> OFFSET_GAMMA_SIZE_LIN) & MASK_16);
        gammaSizeQuadBps = uint16((packed >> OFFSET_GAMMA_SIZE_QUAD) & MASK_16);
        sizeFeeCapBps = uint16((packed >> OFFSET_SIZE_FEE_CAP) & MASK_16);
    }

    function decode(uint256 packed)
        internal
        pure
        returns (
            uint16 baseBps,
            uint16 alphaConfNumerator,
            uint16 alphaConfDenominator,
            uint16 betaInvDevNumerator,
            uint16 betaInvDevDenominator,
            uint16 capBps,
            uint16 decayPctPerBlock
        )
    {
        baseBps = uint16(packed & MASK_16);
        alphaConfNumerator = uint16((packed >> OFFSET_ALPHA_CONF_NUM) & MASK_16);
        alphaConfDenominator = uint16((packed >> OFFSET_ALPHA_CONF_DEN) & MASK_16);
        betaInvDevNumerator = uint16((packed >> OFFSET_BETA_INV_NUM) & MASK_16);
        betaInvDevDenominator = uint16((packed >> OFFSET_BETA_INV_DEN) & MASK_16);
        capBps = uint16((packed >> OFFSET_CAP_BPS) & MASK_16);
        decayPctPerBlock = uint16((packed >> OFFSET_DECAY_PCT) & MASK_16);
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

    function settle(FeeState storage state, FeeConfig memory cfg, uint256 confBps, uint256 inventoryDeviationBps)
        internal
        returns (uint16)
    {
        (uint16 feeBps, FeeState memory newState) = preview(state, cfg, confBps, inventoryDeviationBps, block.number);
        _writeState(state, newState);
        return feeBps;
    }

    function previewPacked(
        FeeState memory state,
        uint256 packedCfg,
        uint256 confBps,
        uint256 inventoryDeviationBps,
        uint256 currentBlock
    ) internal pure returns (uint16 feeBps, FeeState memory newState) {
        newState = state;

        (
            uint16 baseBps,
            uint16 alphaConfNumerator,
            uint16 alphaConfDenominator,
            uint16 betaInvDevNumerator,
            uint16 betaInvDevDenominator,
            uint16 capBps,
            uint16 decayPctPerBlock
        ) = decode(packedCfg);
        uint256 decayFactor = (packedCfg >> OFFSET_DECAY_FACTOR) & MASK_32;

        if (newState.lastBlock == 0) {
            newState.lastBlock = uint64(currentBlock);
            newState.lastFeeBps = baseBps;
        }

        if (decayPctPerBlock > 0 && currentBlock > newState.lastBlock) {
            uint256 blocksElapsed = currentBlock - uint256(newState.lastBlock);
            if (newState.lastFeeBps > baseBps) {
                uint256 delta = newState.lastFeeBps - baseBps;
                uint256 scaledMultiplier = _powScaled(decayFactor, blocksElapsed, DECAY_SCALE);
                uint256 decayedDelta = FixedPointMath.mulDivDown(delta, scaledMultiplier, DECAY_SCALE);
                newState.lastFeeBps = uint16(baseBps + decayedDelta);
            } else {
                newState.lastFeeBps = baseBps;
            }
        }

        newState.lastBlock = uint64(currentBlock);

        uint256 confComponent =
            alphaConfDenominator == 0 ? 0 : FixedPointMath.mulDivDown(confBps, alphaConfNumerator, alphaConfDenominator);
        uint256 invComponent = betaInvDevDenominator == 0
            ? 0
            : FixedPointMath.mulDivDown(inventoryDeviationBps, betaInvDevNumerator, betaInvDevDenominator);

        uint256 fee = uint256(baseBps) + confComponent + invComponent;
        if (fee > capBps) {
            fee = capBps;
        }

        newState.lastFeeBps = uint16(fee);
        feeBps = uint16(fee);
    }

    function settlePacked(FeeState storage state, uint256 packedCfg, uint256 confBps, uint256 inventoryDeviationBps)
        internal
        returns (uint16)
    {
        (uint16 feeBps, FeeState memory newState) =
            previewPacked(state, packedCfg, confBps, inventoryDeviationBps, block.number);
        _writeState(state, newState);
        return feeBps;
    }

    function _writeState(FeeState storage state, FeeState memory newState) private {
        uint256 packed = (uint256(newState.lastFeeBps) << 64) | uint64(newState.lastBlock);
        assembly ("memory-safe") {
            sstore(state.slot, packed)
        }
    }

    function _powScaled(uint256 factor, uint256 exponent, uint256 scale) private pure returns (uint256 result) {
        result = scale;
        while (exponent > 0) {
            if ((exponent & 1) != 0) {
                result = FixedPointMath.mulDivDown(result, factor, scale);
            }
            factor = FixedPointMath.mulDivDown(factor, factor, scale);
            exponent >>= 1;
        }
    }
}
