// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";
import {Vm} from "forge-std/Vm.sol";

contract FirmLadderTIFHonoredTest is BaseTest {
    bytes32 private constant LADDER_SIG = keccak256("PreviewLadderServed(bytes32,uint8[],uint16[],uint32)");

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

        vm.recordLogs();
        pool.refreshPreviewSnapshot(IDnmPool.OracleMode.Spot, bytes(""));
    }

    function test_previewLadderParityAndTif() public {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawLadder;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != LADDER_SIG) continue;
            (, uint8[] memory rungs, uint16[] memory feeBps, uint32 ttlMs) =
                abi.decode(logs[i].data, (bytes32, uint8[], uint16[], uint32));
            sawLadder = true;
            assertEq(ttlMs, defaultMakerConfig().ttlMs, "ttl propagated");
            assertEq(rungs.length, 4, "rung count");
            assertEq(rungs[0], 1, "rung[0]");
            assertEq(rungs[1], 2, "rung[1]");
            assertEq(rungs[2], 5, "rung[2]");
            assertEq(rungs[3], 10, "rung[3]");
            assertEq(feeBps.length, 8, "fee vector zipped ask/bid");
        }
        assertTrue(sawLadder, "ladder event emitted");

        (uint256[] memory sizes, uint256[] memory askFees,, bool[] memory askClamped,, uint64 snapTs,) =
            pool.previewLadder(0);
        (, uint64 snapshotTimestamp) = pool.previewSnapshotAge();
        assertEq(snapTs, snapshotTimestamp, "timestamp round-trip");

        (,,,, uint256 baseScale,) = pool.tokenConfig();

        for (uint256 i = 0; i < sizes.length; ++i) {
            uint256 sizeBase = sizes[i];
            if (sizeBase == 0) continue;
            uint256 amountIn = FixedPointMath.mulDivDown(sizeBase, baseScale, 1e18);
            IDnmPool.QuoteResult memory quoteRes =
                pool.quoteSwapExactIn(amountIn, true, IDnmPool.OracleMode.Spot, bytes(""));
            assertEq(quoteRes.feeBpsUsed, askFees[i], "preview vs quote parity");
            if (askClamped[i]) {
                assertGt(quoteRes.partialFillAmountIn, 0, "clamped rung must signal partial");
            }
        }

        // Warp past freshness and ensure stale snapshot reverts
        vm.warp(block.timestamp + 2);
        vm.expectRevert(abi.encodeWithSelector(DnmPool.PreviewSnapshotStale.selector, uint256(2), uint256(1)));
        pool.previewLadder(0);
    }
}
