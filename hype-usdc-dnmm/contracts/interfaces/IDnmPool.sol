// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IDnmPool {
    enum OracleMode {
        Spot,
        Strict
    }

    struct QuoteResult {
        uint256 amountOut;
        uint256 midUsed;
        uint256 feeBpsUsed;
        uint256 partialFillAmountIn;
        bool usedFallback;
        bytes32 reason;
    }

    function quoteSwapExactIn(uint256 amountIn, bool isBaseIn, OracleMode mode, bytes calldata oracleData)
        external
        returns (QuoteResult memory);

    function swapExactIn(
        uint256 amountIn,
        uint256 minAmountOut,
        bool isBaseIn,
        OracleMode mode,
        bytes calldata oracleData,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function getTopOfBookQuote(uint256 s0Notional)
        external
        view
        returns (uint256 bidPx, uint256 askPx, uint256 ttlMs, bytes32 quoteId);

    function refreshPreviewSnapshot(OracleMode mode, bytes calldata oracleData) external;

    function previewFees(uint256[] calldata sizesBaseWad)
        external
        view
        returns (uint256[] memory askFeeBps, uint256[] memory bidFeeBps);

    function previewFeesFresh(OracleMode mode, bytes calldata oracleData, uint256[] calldata sizesBaseWad)
        external
        view
        returns (uint256[] memory askFeeBps, uint256[] memory bidFeeBps);

    function previewLadder(uint256 s0BaseWad)
        external
        view
        returns (
            uint256[] memory sizesBaseWad,
            uint256[] memory askFeeBps,
            uint256[] memory bidFeeBps,
            bool[] memory askClamped,
            bool[] memory bidClamped,
            uint64 snapshotTimestamp,
            uint96 snapshotMid
        );

    function previewSnapshotAge() external view returns (uint256 ageSec, uint64 snapshotTimestamp);

    function previewConfig()
        external
        view
        returns (uint32 maxAgeSec, uint32 snapshotCooldownSec, bool revertOnStalePreview, bool enablePreviewFresh);

    function rebalanceTarget() external;

    function setRecenterCooldownSec(uint32 newCooldownSec) external;

    function tokens()
        external
        view
        returns (
            address baseToken,
            address quoteToken,
            uint8 baseDecimals,
            uint8 quoteDecimals,
            uint256 baseScale,
            uint256 quoteScale
        );

    function getSoftDivergenceState()
        external
        view
        returns (bool active, uint16 lastDeltaBps, uint8 healthyStreak);

    function baseTokenAddress() external view returns (address);

    function quoteTokenAddress() external view returns (address);

    function pause() external;

    function unpause() external;
}
