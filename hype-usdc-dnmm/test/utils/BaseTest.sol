// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DnmPool} from "../../contracts/DnmPool.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {MockOracleHC} from "../../contracts/mocks/MockOracleHC.sol";
import {MockOraclePyth} from "../../contracts/mocks/MockOraclePyth.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {MathAsserts} from "./MathAsserts.sol";
import {EventRecorder} from "./EventRecorder.sol";

abstract contract BaseTest is MathAsserts {
    uint256 internal constant WAD = 1e18;

    MockERC20 internal hype;
    MockERC20 internal usdc;
    MockOracleHC internal oracleHC;
    MockOraclePyth internal oraclePyth;
    DnmPool internal pool;

    address internal gov = address(0xA11CE);
    address internal pauser = address(0xBEEF);
    address internal maker = address(0xFEE1);
    address internal alice = address(0xA11CE1);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA301);

    struct DeployConfig {
        uint256 baseLiquidity;
        uint256 quoteLiquidity;
        uint16 floorBps;
        uint16 recenterPct;
        uint16 divergenceBps;
        bool allowEmaFallback;
    }

    function setUpBase() public virtual {
        vm.warp(1_000_000);
        vm.roll(1_000);
        hype = new MockERC20("HYPE", "HYPE", 18, 2_000_000 ether, address(this));
        usdc = new MockERC20("USDC", "USDC", 6, 2_000_000_000000, address(this));

        oracleHC = new MockOracleHC();
        oraclePyth = new MockOraclePyth();

        _setOracleDefaults();

        pool = _deployPool(
            defaultInventoryConfig(),
            defaultOracleConfig(),
            defaultFeeConfig(),
            defaultMakerConfig(),
            defaultAomqConfig()
        );
        vm.prank(gov);
        pool.setRecenterCooldownSec(0);
        seedPOL(
            DeployConfig({
                baseLiquidity: 100_000 ether,
                quoteLiquidity: 10_000_000000,
                floorBps: defaultInventoryConfig().floorBps,
                recenterPct: defaultInventoryConfig().recenterThresholdPct,
                divergenceBps: defaultOracleConfig().divergenceBps,
                allowEmaFallback: defaultOracleConfig().allowEmaFallback
            })
        );

        _seedUser(alice, 20_000 ether, 2_000_000000);
        _seedUser(bob, 15_000 ether, 1_500_000000);
        _seedUser(carol, 5_000 ether, 500_000000);
    }

    function _seedUser(address user, uint256 baseAmount, uint256 quoteAmount) internal {
        hype.transfer(user, baseAmount);
        usdc.transfer(user, quoteAmount);
    }

    function _deployPool(
        DnmPool.InventoryConfig memory inventoryCfg,
        DnmPool.OracleConfig memory oracleCfg,
        FeePolicy.FeeConfig memory feeCfg,
        DnmPool.MakerConfig memory makerCfg,
        DnmPool.AomqConfig memory aomqCfg
    ) internal returns (DnmPool) {
        DnmPool.Guardians memory guardians = DnmPool.Guardians({governance: gov, pauser: pauser});
        DnmPool newPool = new DnmPool(
            address(hype),
            address(usdc),
            hype.decimals(),
            usdc.decimals(),
            address(oracleHC),
            address(oraclePyth),
            inventoryCfg,
            oracleCfg,
            feeCfg,
            makerCfg,
            aomqCfg,
            defaultFeatureFlags(),
            guardians
        );
        return newPool;
    }

    function redeployPool(
        DnmPool.InventoryConfig memory inventoryCfg,
        DnmPool.OracleConfig memory oracleCfg,
        FeePolicy.FeeConfig memory feeCfg,
        DnmPool.MakerConfig memory makerCfg,
        DnmPool.AomqConfig memory aomqCfg
    ) internal {
        pool = _deployPool(inventoryCfg, oracleCfg, feeCfg, makerCfg, aomqCfg);
    }

    function defaultInventoryConfig() internal pure returns (DnmPool.InventoryConfig memory) {
        return DnmPool.InventoryConfig({
            targetBaseXstar: 50_000 ether,
            floorBps: 300,
            recenterThresholdPct: 750,
            invTiltBpsPer1pct: 0,
            invTiltMaxBps: 0,
            tiltConfWeightBps: 0,
            tiltSpreadWeightBps: 0
        });
    }

    function defaultOracleConfig() internal pure returns (DnmPool.OracleConfig memory) {
        return DnmPool.OracleConfig({
            maxAgeSec: 60,
            stallWindowSec: 15,
            confCapBpsSpot: 80,
            confCapBpsStrict: 50,
            divergenceBps: 75,
            allowEmaFallback: true,
            confWeightSpreadBps: 10_000,
            confWeightSigmaBps: 10_000,
            confWeightPythBps: 10_000,
            sigmaEwmaLambdaBps: 9000,
            divergenceAcceptBps: 30,
            divergenceSoftBps: 60,
            divergenceHardBps: 75,
            haircutMinBps: 3,
            haircutSlopeBps: 1
        });
    }

    function strictOracleConfig() internal pure returns (DnmPool.OracleConfig memory) {
        return DnmPool.OracleConfig({
            maxAgeSec: 10,
            stallWindowSec: 5,
            confCapBpsSpot: 40,
            confCapBpsStrict: 30,
            divergenceBps: 25,
            allowEmaFallback: true,
            confWeightSpreadBps: 10_000,
            confWeightSigmaBps: 10_000,
            confWeightPythBps: 10_000,
            sigmaEwmaLambdaBps: 9000,
            divergenceAcceptBps: 15,
            divergenceSoftBps: 20,
            divergenceHardBps: 25,
            haircutMinBps: 2,
            haircutSlopeBps: 1
        });
    }

    function defaultFeeConfig() internal pure returns (FeePolicy.FeeConfig memory) {
        return FeePolicy.FeeConfig({
            baseBps: 15,
            alphaConfNumerator: 60,
            alphaConfDenominator: 100,
            betaInvDevNumerator: 12,
            betaInvDevDenominator: 100,
            capBps: 150,
            decayPctPerBlock: 20,
            gammaSizeLinBps: 0,
            gammaSizeQuadBps: 0,
            sizeFeeCapBps: 0
        });
    }

    function conservativeFeeConfig() internal pure returns (FeePolicy.FeeConfig memory) {
        return FeePolicy.FeeConfig({
            baseBps: 10,
            alphaConfNumerator: 40,
            alphaConfDenominator: 100,
            betaInvDevNumerator: 8,
            betaInvDevDenominator: 100,
            capBps: 120,
            decayPctPerBlock: 10,
            gammaSizeLinBps: 0,
            gammaSizeQuadBps: 0,
            sizeFeeCapBps: 0
        });
    }

    function defaultMakerConfig() internal pure returns (DnmPool.MakerConfig memory) {
        return DnmPool.MakerConfig({
            s0Notional: 5_000 ether,
            ttlMs: 300,
            alphaBboBps: 0,
            betaFloorBps: 0
        });
    }

    function defaultAomqConfig() internal pure returns (DnmPool.AomqConfig memory) {
        return DnmPool.AomqConfig({minQuoteNotional: 0, emergencySpreadBps: 0, floorEpsilonBps: 0});
    }

    function defaultFeatureFlags() internal pure returns (DnmPool.FeatureFlags memory) {
        return DnmPool.FeatureFlags({
            blendOn: false,
            parityCiOn: false,
            debugEmit: false,
            enableSoftDivergence: false,
            enableSizeFee: false,
            enableBboFloor: false,
            enableInvTilt: false,
            enableAOMQ: false,
            enableRebates: false,
            enableAutoRecenter: false
        });
    }

    function getFeatureFlags() internal view returns (DnmPool.FeatureFlags memory flags) {
        (
            bool blendOn,
            bool parityCiOn,
            bool debugEmit,
            bool enableSoftDivergence,
            bool enableSizeFee,
            bool enableBboFloor,
            bool enableInvTilt,
            bool enableAOMQ,
            bool enableRebates,
            bool enableAutoRecenter
        ) = pool.featureFlags();

        flags = DnmPool.FeatureFlags({
            blendOn: blendOn,
            parityCiOn: parityCiOn,
            debugEmit: debugEmit,
            enableSoftDivergence: enableSoftDivergence,
            enableSizeFee: enableSizeFee,
            enableBboFloor: enableBboFloor,
            enableInvTilt: enableInvTilt,
            enableAOMQ: enableAOMQ,
            enableRebates: enableRebates,
            enableAutoRecenter: enableAutoRecenter
        });
    }

    function setFeatureFlags(DnmPool.FeatureFlags memory flags) internal {
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Feature, abi.encode(flags));
    }

    function enableBlend() internal {
        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.blendOn = true;
        setFeatureFlags(flags);
    }

    function seedPOL(DeployConfig memory cfg) internal {
        hype.transfer(address(pool), cfg.baseLiquidity);
        usdc.transfer(address(pool), cfg.quoteLiquidity);
        pool.sync();

        vm.prank(gov);
        pool.updateParams(
            DnmPool.ParamKind.Inventory,
            abi.encode(
                DnmPool.InventoryConfig({
                    targetBaseXstar: uint128(cfg.baseLiquidity),
                    floorBps: cfg.floorBps,
                    recenterThresholdPct: cfg.recenterPct,
                    invTiltBpsPer1pct: 0,
                    invTiltMaxBps: 0,
                    tiltConfWeightBps: 0,
                    tiltSpreadWeightBps: 0
                })
            )
        );
    }

    function approveAll(address user) internal {
        vm.startPrank(user);
        hype.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _setOracleDefaults() internal {
        oracleHC.setSpot(1e18, 0, true);
        oracleHC.setBidAsk(9995e14, 10005e14, 20, true);
        oracleHC.setEma(1e18, 0, true);

        IOracleAdapterPyth.PythResult memory result = IOracleAdapterPyth.PythResult({
            hypeUsd: 1e18,
            usdcUsd: 1e18,
            ageSecHype: 0,
            ageSecUsdc: 0,
            confBpsHype: 20,
            confBpsUsdc: 20,
            success: true
        });
        oraclePyth.setResult(result);
    }

    function updateSpot(uint256 mid, uint256 ageSec, bool success) internal {
        oracleHC.setSpot(mid, ageSec, success);
    }

    function updateBidAsk(uint256 bid, uint256 ask, uint256 spreadBps, bool success) internal {
        oracleHC.setBidAsk(bid, ask, spreadBps, success);
    }

    function updateEma(uint256 mid, uint256 ageSec, bool success) internal {
        oracleHC.setEma(mid, ageSec, success);
    }

    function updatePyth(
        uint256 hypeUsd,
        uint256 usdcUsd,
        uint64 ageHype,
        uint64 ageUsdc,
        uint64 confHype,
        uint64 confUsdc
    ) internal {
        IOracleAdapterPyth.PythResult memory result = IOracleAdapterPyth.PythResult({
            hypeUsd: hypeUsd,
            usdcUsd: usdcUsd,
            ageSecHype: ageHype,
            ageSecUsdc: ageUsdc,
            confBpsHype: confHype,
            confBpsUsdc: confUsdc,
            success: true
        });
        oraclePyth.setResult(result);
    }

    function warpTo(uint256 timestamp) internal {
        vm.warp(timestamp);
    }

    function rollBlocks(uint256 blocks_) internal {
        for (uint256 i = 0; i < blocks_; ++i) {
            vm.roll(block.number + 1);
        }
    }

    function quote(uint256 amountIn, bool isBaseIn, IDnmPool.OracleMode mode)
        internal
        returns (DnmPool.QuoteResult memory)
    {
        return pool.quoteSwapExactIn(amountIn, isBaseIn, mode, bytes(""));
    }

    function swap(
        address caller,
        uint256 amountIn,
        uint256 minOut,
        bool isBaseIn,
        IDnmPool.OracleMode mode,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        vm.prank(caller);
        return pool.swapExactIn(amountIn, minOut, isBaseIn, mode, bytes(""), deadline);
    }

    function recordLogs() internal {
        vm.recordLogs();
    }

    function drainLogsToSwapEvents() internal returns (EventRecorder.SwapEvent[] memory events) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        return EventRecorder.decodeSwapEvents(logs);
    }

    function drainLogsToQuoteEvents() internal returns (EventRecorder.QuoteServedEvent[] memory events) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        return EventRecorder.decodeQuoteServedEvents(logs);
    }

    function currentInventory() internal view returns (uint256 baseBal, uint256 quoteBal) {
        baseBal = hype.balanceOf(address(pool));
        quoteBal = usdc.balanceOf(address(pool));
    }
}
