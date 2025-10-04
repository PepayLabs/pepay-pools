// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DnmPool} from "../../contracts/DnmPool.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {Inventory} from "../../contracts/lib/Inventory.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {MockOracleHC} from "../../contracts/mocks/MockOracleHC.sol";
import {MockOraclePyth} from "../../contracts/mocks/MockOraclePyth.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";

contract TupleSweepTest is Test {
    bytes32 internal constant FLOOR = bytes32("FLOOR");

    function test_matrixG_decimal_sweep() public {
        uint8[] memory baseOptions = new uint8[](3);
        baseOptions[0] = 6;
        baseOptions[1] = 9;
        baseOptions[2] = 18;

        uint8[] memory quoteOptions = new uint8[](3);
        quoteOptions[0] = 6;
        quoteOptions[1] = 8;
        quoteOptions[2] = 12;

        string[] memory rows = new string[](baseOptions.length * quoteOptions.length);
        uint256 idx;

        for (uint256 i = 0; i < baseOptions.length; ++i) {
            for (uint256 j = 0; j < quoteOptions.length; ++j) {
                rows[idx++] = _runScenario(baseOptions[i], quoteOptions[j]);
            }
        }

        EventRecorder.writeCSV(
            vm,
            "metrics/tuple_decimal_sweep.csv",
            "base_decimals,quote_decimals,avg_fee_bps,partial_hit,mid_floor_bps",
            rows
        );
    }

    function _runScenario(uint8 baseDecimals, uint8 quoteDecimals) internal returns (string memory row) {
        uint256 baseScale = 10 ** baseDecimals;
        uint256 quoteScale = 10 ** quoteDecimals;

        MockERC20 baseToken = new MockERC20("BASE", "BASE", baseDecimals, 500_000 * baseScale, address(this));
        MockERC20 quoteToken = new MockERC20("QUOTE", "QUOTE", quoteDecimals, 500_000 * quoteScale, address(this));
        MockOracleHC oracleHC = new MockOracleHC();
        MockOraclePyth oraclePyth = new MockOraclePyth();

        oracleHC.setSpot(1e18, 0, true);
        oracleHC.setBidAsk(9995e14, 10005e14, 20, true);
        oracleHC.setEma(1e18, 0, true);
        IOracleAdapterPyth.PythResult memory pythResult = IOracleAdapterPyth.PythResult({
            hypeUsd: 1e18,
            usdcUsd: 1e18,
            ageSecHype: 0,
            ageSecUsdc: 0,
            confBpsHype: 20,
            confBpsUsdc: 20,
            success: true
        });
        oraclePyth.setResult(pythResult);

        DnmPool.InventoryConfig memory invCfg = DnmPool.InventoryConfig({
            targetBaseXstar: uint128(50_000 * baseScale),
            floorBps: 300,
            recenterThresholdPct: 750,
            invTiltBpsPer1pct: 0,
            invTiltMaxBps: 0,
            tiltConfWeightBps: 0,
            tiltSpreadWeightBps: 0
        });
        DnmPool.OracleConfig memory oracleCfg = DnmPool.OracleConfig({
            maxAgeSec: 60,
            stallWindowSec: 15,
            confCapBpsSpot: 80,
            confCapBpsStrict: 50,
            divergenceBps: 90,
            allowEmaFallback: true,
            confWeightSpreadBps: 10_000,
            confWeightSigmaBps: 10_000,
            confWeightPythBps: 10_000,
            sigmaEwmaLambdaBps: 9000,
            divergenceAcceptBps: 30,
            divergenceSoftBps: 70,
            divergenceHardBps: 90,
            haircutMinBps: 3,
            haircutSlopeBps: 1
        });
        FeePolicy.FeeConfig memory feeCfg = FeePolicy.FeeConfig({
            baseBps: 12,
            alphaConfNumerator: 60,
            alphaConfDenominator: 100,
            betaInvDevNumerator: 10,
            betaInvDevDenominator: 100,
            capBps: 220,
            decayPctPerBlock: 20,
            gammaSizeLinBps: 0,
            gammaSizeQuadBps: 0,
            sizeFeeCapBps: 0,
            kappaLvrBps: 0
        });
        DnmPool.MakerConfig memory makerCfg =
            DnmPool.MakerConfig({s0Notional: uint128(1_000 * baseScale), ttlMs: 200, alphaBboBps: 0, betaFloorBps: 0});
        DnmPool.AomqConfig memory aomqCfg =
            DnmPool.AomqConfig({minQuoteNotional: 0, emergencySpreadBps: 0, floorEpsilonBps: 0});
        DnmPool.PreviewConfig memory previewCfg = DnmPool.PreviewConfig({
            maxAgeSec: 30,
            snapshotCooldownSec: 10,
            revertOnStalePreview: true,
            enablePreviewFresh: false
        });
        DnmPool.Guardians memory guardians = DnmPool.Guardians({governance: address(this), pauser: address(this)});

        DnmPool pool = new DnmPool(
            address(baseToken),
            address(quoteToken),
            baseDecimals,
            quoteDecimals,
            address(oracleHC),
            address(oraclePyth),
            invCfg,
            oracleCfg,
            feeCfg,
            makerCfg,
            aomqCfg,
            previewCfg,
            DnmPool.FeatureFlags({
                blendOn: true,
                parityCiOn: true,
                debugEmit: true,
                enableSoftDivergence: false,
                enableSizeFee: false,
                enableBboFloor: false,
                enableInvTilt: false,
                enableAOMQ: false,
                enableRebates: false,
                enableAutoRecenter: false,
                enableLvrFee: false
            }),
            guardians
        );

        require(baseToken.transfer(address(pool), 80_000 * baseScale), "ERC20: transfer failed");
        require(quoteToken.transfer(address(pool), 80_000 * quoteScale), "ERC20: transfer failed");
        pool.sync();

        baseToken.approve(address(pool), type(uint256).max);
        quoteToken.approve(address(pool), type(uint256).max);

        vm.recordLogs();
        uint256 cumulativeFee;
        uint256 swaps;
        bool sawPartial;
        uint256 floorBps;

        for (uint256 step = 1; step <= 5; ++step) {
            uint256 baseTrade = (step * baseScale) / 20;
            pool.swapExactIn(baseTrade, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 60);
            uint256 quoteTrade = (step * quoteScale) / 25;
            pool.swapExactIn(quoteTrade, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 60);
        }

        Vm.Log[] memory entries = vm.getRecordedLogs();
        EventRecorder.SwapEvent[] memory events = EventRecorder.decodeSwapEvents(entries);
        swaps = events.length;
        for (uint256 i = 0; i < events.length; ++i) {
            cumulativeFee += events[i].feeBps;
            if (events[i].isPartial) sawPartial = true;
            if (events[i].reason == FLOOR) {
                floorBps = 1;
            }
        }

        (
            ,
            ,
            uint8 returnedBaseDecimals,
            uint8 returnedQuoteDecimals,
            uint256 returnedBaseScale,
            uint256 returnedQuoteScale
        ) = pool.tokenConfig();
        assertEq(returnedBaseDecimals, baseDecimals, "base decimals mismatch");
        assertEq(returnedQuoteDecimals, quoteDecimals, "quote decimals mismatch");
        assertEq(returnedBaseScale, baseScale, "base scale mismatch");
        assertEq(returnedQuoteScale, quoteScale, "quote scale mismatch");

        (uint128 targetBase,,,,,,) = pool.inventoryConfig();
        uint256 floorAmount = Inventory.floorAmount(uint256(targetBase), invCfg.floorBps);
        assertLt(floorAmount, uint256(type(uint128).max), "floor overflow");

        uint256 avgFee = swaps == 0 ? 0 : cumulativeFee / swaps;
        row = string.concat(
            EventRecorder.uintToString(baseDecimals),
            ",",
            EventRecorder.uintToString(quoteDecimals),
            ",",
            EventRecorder.uintToString(avgFee),
            ",",
            sawPartial ? "true" : "false",
            ",",
            EventRecorder.uintToString(floorBps)
        );
    }
}
