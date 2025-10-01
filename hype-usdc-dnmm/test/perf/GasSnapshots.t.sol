// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {QuoteRFQ} from "../../contracts/quotes/QuoteRFQ.sol";
import {IQuoteRFQ} from "../../contracts/interfaces/IQuoteRFQ.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";

import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";

contract GasSnapshotsTest is BaseTest {
    uint256 internal constant QUOTE_GAS_BUDGET = 130_000;
    uint256 internal constant SWAP_GAS_BUDGET = 320_000;
    uint256 internal constant PREVIEW_FEES_BUDGET = 80_000;
    uint256 internal constant PREVIEW_LADDER_BUDGET = 250_000;

    QuoteRFQ internal rfq;
    uint256 internal makerKey = 0xBADA55;

    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
        approveAll(carol);
        rfq = new QuoteRFQ(address(pool), vm.addr(makerKey));
        vm.prank(alice);
        hype.approve(address(rfq), type(uint256).max);
    }

    function test_gasProfiles() public {
        string[] memory labels = new string[](8);
        uint256[] memory gasUsed = new uint256[](8);

        labels[0] = "quote_hc";
        gasUsed[0] = _measureQuoteHC();

        labels[1] = "quote_ema";
        gasUsed[1] = _measureQuoteEMA();

        labels[2] = "quote_pyth";
        gasUsed[2] = _measureQuotePYTH();

        labels[3] = "swap_base_hc";
        gasUsed[3] = _measureSwapBaseHC();

        labels[4] = "swap_quote_hc";
        gasUsed[4] = _measureSwapQuoteHC();

        labels[5] = "rfq_verify_swap";
        gasUsed[5] = _measureRFQGas();

        labels[6] = "preview_fees";
        gasUsed[6] = _measurePreviewFeesGas();

        labels[7] = "preview_ladder";
        gasUsed[7] = _measurePreviewLadderGas();

        _assertGasWithin("quote_hc", gasUsed[0], QUOTE_GAS_BUDGET);
        _assertGasWithin("quote_ema", gasUsed[1], QUOTE_GAS_BUDGET);
        _assertGasWithin("quote_pyth", gasUsed[2], QUOTE_GAS_BUDGET);
        _assertGasWithin("swap_base_hc", gasUsed[3], SWAP_GAS_BUDGET);
        _assertGasWithin("swap_quote_hc", gasUsed[4], SWAP_GAS_BUDGET);
        _assertGasWithin("preview_fees", gasUsed[6], PREVIEW_FEES_BUDGET);
        _assertGasWithin("preview_ladder", gasUsed[7], PREVIEW_LADDER_BUDGET);

        string[] memory rows = new string[](labels.length);
        for (uint256 i = 0; i < labels.length; ++i) {
            rows[i] = string.concat(labels[i], ",", EventRecorder.uintToString(gasUsed[i]));
        }

        EventRecorder.writeCSV(vm, "metrics/gas_snapshots.csv", "operation,gas_used", rows);
        EventRecorder.writeCSV(vm, "gas-snapshots.txt", "operation,gas_used", rows);
    }

    function _measureQuoteHC() internal returns (uint256) {
        _resetScenario();
        uint256 gasBefore = gasleft();
        quote(10 ether, true, IDnmPool.OracleMode.Spot);
        return gasBefore - gasleft();
    }

    function _measureQuoteEMA() internal returns (uint256) {
        _resetScenario();
        updateSpot(WAD, 0, true);
        updateBidAsk(995e15, 1005e15, 600, true);
        updateEma(WAD, 1, true);
        uint256 gasBefore = gasleft();
        quote(10 ether, true, IDnmPool.OracleMode.Spot);
        return gasBefore - gasleft();
    }

    function _measureQuotePYTH() internal returns (uint256) {
        _resetScenario();
        updateSpot(WAD, defaultOracleConfig().maxAgeSec + 5, true);
        updateBidAsk(0, 0, 0, false);
        updateEma(WAD, defaultOracleConfig().maxAgeSec + 5, true);
        updatePyth(WAD, WAD, 1, 1, 20, 20);
        uint256 gasBefore = gasleft();
        quote(10 ether, true, IDnmPool.OracleMode.Spot);
        return gasBefore - gasleft();
    }

    function _measureSwapBaseHC() internal returns (uint256) {
        _resetScenario();
        uint256 gasBefore = gasleft();
        vm.prank(alice);
        pool.swapExactIn(15 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        return gasBefore - gasleft();
    }

    function _measureSwapQuoteHC() internal returns (uint256) {
        _resetScenario();
        deal(address(usdc), bob, 5_000_000000);
        uint256 gasBefore = gasleft();
        vm.prank(bob);
        pool.swapExactIn(5_000_000000, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        return gasBefore - gasleft();
    }

    function _measureRFQGas() internal returns (uint256) {
        _resetScenario();
        QuoteRFQ localRfq = rfq;
        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 12 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 60,
            salt: 999
        });
        bytes memory sig = _sign(localRfq, params);

        uint256 gasBefore = gasleft();
        vm.prank(alice);
        localRfq.verifyAndSwap(sig, params, bytes(""));
        return gasBefore - gasleft();
    }

    function _measurePreviewFeesGas() internal returns (uint256) {
        _resetScenario();
        DnmPool.PreviewConfig memory previewCfg = DnmPool.PreviewConfig({
            maxAgeSec: 30,
            snapshotCooldownSec: 0,
            revertOnStalePreview: true,
            enablePreviewFresh: false
        });
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Preview, abi.encode(previewCfg));
        pool.refreshPreviewSnapshot(IDnmPool.OracleMode.Spot, bytes(""));
        uint256[] memory sizes = new uint256[](1);
        sizes[0] = 1e18;
        uint256 gasBefore = gasleft();
        pool.previewFees(sizes);
        return gasBefore - gasleft();
    }

    function _measurePreviewLadderGas() internal returns (uint256) {
        _resetScenario();
        DnmPool.PreviewConfig memory previewCfg = DnmPool.PreviewConfig({
            maxAgeSec: 30,
            snapshotCooldownSec: 0,
            revertOnStalePreview: true,
            enablePreviewFresh: false
        });
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Preview, abi.encode(previewCfg));
        pool.refreshPreviewSnapshot(IDnmPool.OracleMode.Spot, bytes(""));
        uint256 gasBefore = gasleft();
        pool.previewLadder(0);
        return gasBefore - gasleft();
    }

    function _resetScenario() internal {
        DnmPool.InventoryConfig memory invCfg = defaultInventoryConfig();
        DnmPool.OracleConfig memory oracleCfg = defaultOracleConfig();
        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();

        redeployPool(invCfg, oracleCfg, feeCfg, makerCfg, defaultAomqConfig());
        pool.sync();
        seedPOL(
            DeployConfig({
                baseLiquidity: 100_000 ether,
                quoteLiquidity: 10_000_000000,
                floorBps: invCfg.floorBps,
                recenterPct: invCfg.recenterThresholdPct,
                divergenceBps: oracleCfg.divergenceBps,
                allowEmaFallback: oracleCfg.allowEmaFallback
            })
        );
        _setOracleDefaults();

        approveAll(alice);
        approveAll(bob);
        approveAll(carol);

        _seedUser(alice, 20_000 ether, 2_000_000000);
        _seedUser(bob, 15_000 ether, 1_500_000000);
        _seedUser(carol, 5_000 ether, 500_000000);

        rfq = new QuoteRFQ(address(pool), vm.addr(makerKey));
        vm.startPrank(alice);
        hype.approve(address(rfq), type(uint256).max);
        usdc.approve(address(rfq), type(uint256).max);
        vm.stopPrank();

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        if (flags.debugEmit) {
            flags.debugEmit = false;
            setFeatureFlags(flags);
        }
    }

    function _sign(QuoteRFQ target, IQuoteRFQ.QuoteParams memory params) internal view returns (bytes memory) {
        bytes32 digest = target.hashTypedDataV4(params);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _assertGasWithin(string memory label, uint256 gasUsed, uint256 maxGas) internal view {
        assertLe(gasUsed, maxGas, string.concat(label, ": gas budget exceeded"));
    }
}
