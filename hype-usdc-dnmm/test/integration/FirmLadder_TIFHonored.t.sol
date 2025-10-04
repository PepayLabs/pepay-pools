// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";
import {Vm} from "forge-std/Vm.sol";

contract FirmLadderTIFHonoredTest is BaseTest {
    function setUp() public {
        setUpBase();

        DnmPool.PreviewConfig memory previewCfg = DnmPool.PreviewConfig({
            maxAgeSec: 1,
            snapshotCooldownSec: 0,
            revertOnStalePreview: true,
            enablePreviewFresh: false
        });
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Preview, abi.encode(previewCfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.debugEmit = true;
        setFeatureFlags(flags);

        updateSpot(1e18, 0, true);
        updateBidAsk(999e15, 1001e15, 20, true);
        updatePyth(1e18, 1e18, 0, 0, 20, 20);

        pool.refreshPreviewSnapshot(IDnmPool.OracleMode.Spot, bytes(""));
    }

    function test_previewLadderParityAndTif() public {
        (uint256[] memory sizes, uint256[] memory askFees,, bool[] memory askClamped,, uint64 snapTimestamp,) =
            pool.previewLadder(0);
        (, uint64 expectedTs) = pool.previewSnapshotAge();
        assertEq(snapTimestamp, expectedTs, "snapshot timestamp");

        (, uint32 makerTtlMs,,) = pool.makerConfig();
        assertEq(makerTtlMs, defaultMakerConfig().ttlMs, "ttl propagated to ladder");

        uint256[4] memory bufferBps = [uint256(5), uint256(15), uint256(15), uint256(30)];
        (,,,, uint256 baseScale,) = pool.tokens();

        for (uint256 i = 0; i < sizes.length; ++i) {
            uint256 sizeBaseWad = sizes[i];
            if (sizeBaseWad == 0) continue;

            uint256 amountIn = FixedPointMath.mulDivDown(sizeBaseWad, baseScale, 1e18);
            IDnmPool.QuoteResult memory quoteRes =
                pool.quoteSwapExactIn(amountIn, true, IDnmPool.OracleMode.Spot, bytes(""));

            assertEq(quoteRes.feeBpsUsed, askFees[i], "preview fee parity");

            uint256 previewOut = quoteRes.amountOut;
            uint256 bufferBpsValue = i < bufferBps.length ? bufferBps[i] : bufferBps[bufferBps.length - 1];
            uint256 bufferAmount = FixedPointMath.mulDivDown(previewOut, bufferBpsValue, 10_000);
            uint256 minOut = previewOut > bufferAmount ? previewOut - bufferAmount : 0;
            assertLt(minOut, previewOut, "minOut must be under preview amount");

            if (askClamped[i]) {
                assertGt(quoteRes.partialFillAmountIn, 0, "clamped rung must signal partial");
            }
        }

        vm.warp(block.timestamp + 2);
        vm.expectRevert(abi.encodeWithSelector(DnmPool.PreviewSnapshotStale.selector, uint256(2), uint256(1)));
        pool.previewLadder(0);
    }
}
