// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {DnmPool} from "../../contracts/DnmPool.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {OracleAdapterHC} from "../../contracts/oracle/OracleAdapterHC.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {MockOraclePyth} from "../../contracts/mocks/MockOraclePyth.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {HyperCoreConstants} from "../../contracts/oracle/HyperCoreConstants.sol";

contract RevertingHyperCore {
    fallback() external {
        revert("HC fail");
    }
}

contract DnmPoolReadOracleFailClosedTest is Test {
    MockERC20 internal baseToken;
    MockERC20 internal quoteToken;
    MockOraclePyth internal pyth;
    OracleAdapterHC internal adapter;
    DnmPool internal pool;

    address internal constant GOV = address(0xA11CE);
    address internal constant PAUSER = address(0xBEEF);
    address internal trader = address(0xB0B);

    function setUp() public {
        baseToken = new MockERC20("HYPE", "HYPE", 18, 2_000_000 ether, address(this));
        quoteToken = new MockERC20("USDC", "USDC", 6, 2_000_000_000000, address(this));
        pyth = new MockOraclePyth();

        address core = address(new RevertingHyperCore());
        vm.etch(HyperCoreConstants.ORACLE_PX_PRECOMPILE, core.code);
        adapter = new OracleAdapterHC(
            HyperCoreConstants.ORACLE_PX_PRECOMPILE, bytes32("HYPE"), bytes32("USDC"), bytes32("HYPE"), false
        );

        DnmPool.InventoryConfig memory inventoryCfg =
            DnmPool.InventoryConfig({targetBaseXstar: 50_000 ether, floorBps: 300, recenterThresholdPct: 750});
        DnmPool.OracleConfig memory oracleCfg = DnmPool.OracleConfig({
            maxAgeSec: 60,
            stallWindowSec: 15,
            confCapBpsSpot: 80,
            confCapBpsStrict: 50,
            divergenceBps: 75,
            allowEmaFallback: true,
            confWeightSpreadBps: 10_000,
            confWeightSigmaBps: 10_000,
            confWeightPythBps: 10_000,
            sigmaEwmaLambdaBps: 9_000,
            divergenceAcceptBps: 30,
            divergenceSoftBps: 60,
            divergenceHardBps: 75,
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
        DnmPool.MakerConfig memory makerCfg = DnmPool.MakerConfig({s0Notional: 5_000 ether, ttlMs: 300});
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

        pool = new DnmPool(
            address(baseToken),
            address(quoteToken),
            18,
            6,
            address(adapter),
            address(pyth),
            inventoryCfg,
            oracleCfg,
            feeCfg,
            makerCfg,
            flags,
            DnmPool.Guardians({governance: GOV, pauser: PAUSER})
        );

        baseToken.transfer(address(pool), 100_000 ether);
        quoteToken.transfer(address(pool), 10_000_000000);
        pool.sync();

        baseToken.transfer(trader, 1_000_000 ether);
        vm.prank(trader);
        baseToken.approve(address(pool), type(uint256).max);

        IOracleAdapterPyth.PythResult memory stale = IOracleAdapterPyth.PythResult({
            hypeUsd: 1e18,
            usdcUsd: 1e18,
            ageSecHype: 1_000,
            ageSecUsdc: 1_000,
            confBpsHype: 20,
            confBpsUsdc: 20,
            success: true
        });
        pyth.setResult(stale);
    }

    function test_swapBubblesHyperCoreFailure() public {
        bytes memory revertData = abi.encodeWithSignature("Error(string)", "HC fail");

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAdapterHC.HyperCoreCallFailed.selector, HyperCoreConstants.ORACLE_PX_PRECOMPILE, revertData
            )
        );
        pool.swapExactIn(1_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
    }
}
