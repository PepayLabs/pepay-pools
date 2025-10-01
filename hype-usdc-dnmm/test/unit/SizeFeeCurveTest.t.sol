// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract SizeFeeCurveTest is BaseTest {
    uint256 internal constant ONE = 1e18;

    function setUp() public {
        setUpBase();

        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        feeCfg.alphaConfNumerator = 0;
        feeCfg.alphaConfDenominator = 1;
        feeCfg.betaInvDevNumerator = 0;
        feeCfg.betaInvDevDenominator = 1;
        feeCfg.gammaSizeLinBps = 20;
        feeCfg.gammaSizeQuadBps = 10;
        feeCfg.sizeFeeCapBps = 60;

        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Fee, abi.encode(feeCfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableSizeFee = true;
        setFeatureFlags(flags);

        _setAlignedOracles();
    }

    function test_sizeFeeMonotonicInTradeSize() public {
        (uint128 s0Notional,,,) = pool.makerConfig();
        uint256 s0 = uint256(s0Notional);

        uint256[] memory tradeSizes = new uint256[](3);
        tradeSizes[0] = s0 / 2;
        tradeSizes[1] = s0;
        tradeSizes[2] = s0 * 2;

        uint16[] memory fees = new uint16[](tradeSizes.length);
        for (uint256 i = 0; i < tradeSizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            fees[i] = _quoteFee(tradeSizes[i]);
            vm.revertToState(snap);
        }

        require(fees[1] > fees[0], "S0 fee>0");
        require(fees[2] > fees[1], "2S0 fee> S0");
    }

    function test_sizeFeeRespectsCap() public {
        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        feeCfg.alphaConfNumerator = 0;
        feeCfg.alphaConfDenominator = 1;
        feeCfg.betaInvDevNumerator = 0;
        feeCfg.betaInvDevDenominator = 1;
        feeCfg.gammaSizeLinBps = 40;
        feeCfg.gammaSizeQuadBps = 30;
        feeCfg.sizeFeeCapBps = 50;

        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Fee, abi.encode(feeCfg));

        (uint128 s0Notional,,,) = pool.makerConfig();
        uint256 snap = vm.snapshotState();
        uint16 feeBps = _quoteFee(uint256(s0Notional) * 5);
        vm.revertToState(snap);

        uint16 baseline = defaultFeeConfig().baseBps;
        require(feeBps - baseline <= feeCfg.sizeFeeCapBps, "size fee cap respected");
    }

    function test_previewMatchesSwapAfterSizeFee() public {
        (uint128 s0Notional,,,) = pool.makerConfig();
        uint256 amount = (uint256(s0Notional) * 3) / 2; // 1.5x S0

        uint256 snap = vm.snapshotState();
        DnmPool.QuoteResult memory preview = quote(amount, true, IDnmPool.OracleMode.Spot);
        vm.revertToState(snap);

        approveAll(alice);

        vm.recordLogs();
        uint256 amountOut = swap(alice, amount, 0, true, IDnmPool.OracleMode.Spot, block.timestamp + 5);
        require(amountOut == preview.amountOut, "amount parity");
        EventRecorder.SwapEvent[] memory swaps = EventRecorder.decodeSwapEvents(vm.getRecordedLogs());
        require(swaps.length == 1, "swap event");
        assertEq(swaps[0].feeBps, preview.feeBpsUsed, "fee parity");
    }

    function _quoteFee(uint256 amountIn) internal returns (uint16) {
        DnmPool.QuoteResult memory res = quote(amountIn, true, IDnmPool.OracleMode.Spot);
        return uint16(res.feeBpsUsed);
    }

    function _setAlignedOracles() internal {
        updateSpot(ONE, 2, true);
        updateBidAsk(ONE - 1, ONE + 1, 0, true);
        updateEma(ONE, 1, true);
        updatePyth(ONE, ONE, 0, 0, 10, 10);
    }
}
