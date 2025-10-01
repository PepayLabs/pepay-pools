// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {DnmPool} from "../../contracts/DnmPool.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {MockOracleHC} from "../../contracts/mocks/MockOracleHC.sol";
import {MockOraclePyth} from "../../contracts/mocks/MockOraclePyth.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";

contract DivergencePolicyTest is Test {
    MockERC20 internal baseToken;
    MockERC20 internal quoteToken;
    MockOracleHC internal oracleHc;
    MockOraclePyth internal oraclePyth;
    DnmPool internal pool;

    DnmPool.OracleConfig internal oracleCfg;
    DnmPool.InventoryConfig internal inventoryCfg;

    address internal constant GOV = address(0xA11CE);
    address internal constant PAUSER = address(0xBEEF);

    bytes internal constant EMPTY_ORACLE_DATA = bytes("");

    function setUp() public {
        baseToken = new MockERC20("HYPE", "HYPE", 18, 1_000_000 ether, address(this));
        quoteToken = new MockERC20("USDC", "USDC", 6, 1_000_000_000000, address(this));
        oracleHc = new MockOracleHC();
        oraclePyth = new MockOraclePyth();

        inventoryCfg = DnmPool.InventoryConfig({
            targetBaseXstar: 50_000 ether,
            floorBps: 300,
            recenterThresholdPct: 750,
            invTiltBpsPer1pct: 0,
            invTiltMaxBps: 0,
            tiltConfWeightBps: 0,
            tiltSpreadWeightBps: 0
        });
        oracleCfg = DnmPool.OracleConfig({
            maxAgeSec: 60,
            stallWindowSec: 15,
            confCapBpsSpot: 80,
            confCapBpsStrict: 50,
            divergenceBps: 50,
            allowEmaFallback: false,
            confWeightSpreadBps: 10_000,
            confWeightSigmaBps: 10_000,
            confWeightPythBps: 10_000,
            sigmaEwmaLambdaBps: 9_000,
            divergenceAcceptBps: 25,
            divergenceSoftBps: 40,
            divergenceHardBps: 50,
            haircutMinBps: 3,
            haircutSlopeBps: 1
        });
        FeePolicy.FeeConfig memory feeCfg = FeePolicy.FeeConfig({
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
        DnmPool.MakerConfig memory makerCfg = DnmPool.MakerConfig({
            s0Notional: 5_000 ether,
            ttlMs: 300,
            alphaBboBps: 0,
            betaFloorBps: 0
        });
        DnmPool.AomqConfig memory aomqCfg =
            DnmPool.AomqConfig({minQuoteNotional: 0, emergencySpreadBps: 0, floorEpsilonBps: 0});
        DnmPool.PreviewConfig memory previewCfg = DnmPool.PreviewConfig({
            maxAgeSec: 30,
            snapshotCooldownSec: 10,
            revertOnStalePreview: true,
            enablePreviewFresh: false
        });
        DnmPool.FeatureFlags memory flags = DnmPool.FeatureFlags({
            blendOn: true,
            parityCiOn: true,
            debugEmit: true,
            enableSoftDivergence: false,
            enableSizeFee: false,
            enableBboFloor: false,
            enableInvTilt: false,
            enableAOMQ: false,
            enableRebates: false,
            enableAutoRecenter: false
        });

        pool = new DnmPool(
            address(baseToken),
            address(quoteToken),
            18,
            6,
            address(oracleHc),
            address(oraclePyth),
            inventoryCfg,
            oracleCfg,
            feeCfg,
            makerCfg,
            aomqCfg,
            previewCfg,
            flags,
            DnmPool.Guardians({governance: GOV, pauser: PAUSER})
        );

        baseToken.transfer(address(pool), 100_000 ether);
        quoteToken.transfer(address(pool), 10_000_000000);
        pool.sync();

        _primeHyperCore(1e18, 5, 900e15, 1_100e15, 25);
        _primePyth(1e18, 1, 1, 5, 5, true);
    }

    function test_revertsWhenDivergenceExceedsCap() public {
        uint256 pythMid = 1e18;
        uint256 hcMid = 1_060_000_000_000_000_000; // +6%
        _primeHyperCore(hcMid, 5, 1_059_000_000_000_000_000, 1_061_000_000_000_000_000, 20);

        uint256 expectedDeltaBps = 566; // floor((|HC-Pyth| / max) * 10_000)

        vm.expectEmit(true, true, true, true, address(pool));
        emit DnmPool.OracleDivergenceChecked(pythMid, hcMid, expectedDeltaBps, oracleCfg.divergenceBps);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.OracleDiverged.selector, expectedDeltaBps, oracleCfg.divergenceBps)
        );
        pool.quoteSwapExactIn(5 ether, true, IDnmPool.OracleMode.Spot, EMPTY_ORACLE_DATA);
    }

    function test_allowsWithinCap() public {
        _primeHyperCore(1_003_000_000_000_000_000, 5, 1_002_000_000_000_000_000, 1_004_000_000_000_000_000, 15);

        IDnmPool.QuoteResult memory quote =
            pool.quoteSwapExactIn(10 ether, true, IDnmPool.OracleMode.Spot, EMPTY_ORACLE_DATA);
        assertGt(quote.amountOut, 0, "quote should succeed");
        assertEq(quote.reason, bytes32(0), "no floor reason");
    }

    function test_skipsCheckWhenPythStale() public {
        _primePyth(1e18, 90, 90, 5, 5, true); // aged beyond maxAgeSec
        _primeHyperCore(1_080_000_000_000_000_000, 5, 1_079_000_000_000_000_000, 1_081_000_000_000_000_000, 20);

        IDnmPool.QuoteResult memory quote =
            pool.quoteSwapExactIn(2 ether, true, IDnmPool.OracleMode.Spot, EMPTY_ORACLE_DATA);
        assertGt(quote.amountOut, 0, "quote should succeed even when HC diverges if Pyth stale");
    }

    function test_noDebugEventWhenFlagOff() public {
        DnmPool.FeatureFlags memory flags = DnmPool.FeatureFlags({
            blendOn: true,
            parityCiOn: true,
            debugEmit: false,
            enableSoftDivergence: false,
            enableSizeFee: false,
            enableBboFloor: false,
            enableInvTilt: false,
            enableAOMQ: false,
            enableRebates: false,
            enableAutoRecenter: false
        });
        vm.prank(GOV);
        pool.updateParams(IDnmPool.ParamKind.Feature, abi.encode(flags));

        _primeHyperCore(1_070_000_000_000_000_000, 5, 1_069_000_000_000_000_000, 1_071_000_000_000_000_000, 20);
        uint256 expectedDeltaBps = 654;

        vm.expectRevert(
            abi.encodeWithSelector(Errors.OracleDiverged.selector, expectedDeltaBps, oracleCfg.divergenceBps)
        );
        pool.quoteSwapExactIn(7 ether, true, IDnmPool.OracleMode.Spot, EMPTY_ORACLE_DATA);
    }

    function _primeHyperCore(uint256 mid, uint256 ageSec, uint256 bid, uint256 ask, uint256 spreadBps) internal {
        oracleHc.setSpot(mid, ageSec, true);
        oracleHc.setBidAsk(bid, ask, spreadBps, true);
    }

    function _primePyth(
        uint256 hypeUsd,
        uint64 ageSecHype,
        uint64 ageSecUsdc,
        uint64 confBpsHype,
        uint64 confBpsUsdc,
        bool success
    ) internal {
        oraclePyth.setResult(
            IOracleAdapterPyth.PythResult({
                hypeUsd: hypeUsd,
                usdcUsd: 1e18,
                ageSecHype: ageSecHype,
                ageSecUsdc: ageSecUsdc,
                confBpsHype: confBpsHype,
                confBpsUsdc: confBpsUsdc,
                success: success
            })
        );
    }
}
