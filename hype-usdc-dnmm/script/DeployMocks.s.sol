// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockOracleHC} from "../contracts/mocks/MockOracleHC.sol";
import {MockOraclePyth} from "../contracts/mocks/MockOraclePyth.sol";
import {IOracleAdapterPyth} from "../contracts/interfaces/IOracleAdapterPyth.sol";
import {DnmPool} from "../contracts/DnmPool.sol";
import {FeePolicy} from "../contracts/lib/FeePolicy.sol";

contract DeployMocks is Script {
    function run() external {
        vm.startBroadcast();
        address deployer = msg.sender;

        MockERC20 hype = new MockERC20("Mock HYPE", "mHYPE", 18, 1_000_000 ether, deployer);
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC", 6, 10_000_000 * 1e6, deployer);

        MockOracleHC hc = new MockOracleHC();
        hc.setSpot(1e8, 1, true);
        hc.setBidAsk(99_500_000, 100_500_000, 10, true);
        hc.setEma(1e8, 10, true);

        MockOraclePyth pyth = new MockOraclePyth();
        IOracleAdapterPyth.PythResult memory baseResult = IOracleAdapterPyth.PythResult({
            hypeUsd: 1e18,
            usdcUsd: 1e18,
            ageSecHype: 5,
            ageSecUsdc: 5,
            confBpsHype: 25,
            confBpsUsdc: 15,
            success: true
        });
        pyth.setResult(baseResult);

        DnmPool.InventoryConfig memory inventoryCfg = DnmPool.InventoryConfig({
            targetBaseXstar: 2_500 ether,
            floorBps: 500,
            recenterThresholdPct: 500,
            invTiltBpsPer1pct: 8,
            invTiltMaxBps: 40,
            tiltConfWeightBps: 20,
            tiltSpreadWeightBps: 20
        });

        DnmPool.OracleConfig memory oracleCfg = DnmPool.OracleConfig({
            maxAgeSec: 30,
            stallWindowSec: 5,
            confCapBpsSpot: 250,
            confCapBpsStrict: 150,
            divergenceBps: 80,
            allowEmaFallback: true,
            confWeightSpreadBps: 20,
            confWeightSigmaBps: 10,
            confWeightPythBps: 30,
            sigmaEwmaLambdaBps: 9500,
            divergenceAcceptBps: 35,
            divergenceSoftBps: 50,
            divergenceHardBps: 90,
            haircutMinBps: 5,
            haircutSlopeBps: 15
        });

        FeePolicy.FeeConfig memory feeCfg = FeePolicy.FeeConfig({
            baseBps: 12,
            alphaConfNumerator: 60,
            alphaConfDenominator: 100,
            betaInvDevNumerator: 5,
            betaInvDevDenominator: 100,
            capBps: 180,
            decayPctPerBlock: 10,
            gammaSizeLinBps: 12,
            gammaSizeQuadBps: 3,
            sizeFeeCapBps: 80
        });

        DnmPool.MakerConfig memory makerCfg = DnmPool.MakerConfig({
            s0Notional: 50_000 * 1e6,
            ttlMs: 1_000,
            alphaBboBps: 25,
            betaFloorBps: 20
        });

        DnmPool.AomqConfig memory aomqCfg = DnmPool.AomqConfig({
            minQuoteNotional: 25_000 * 1e6,
            emergencySpreadBps: 60,
            floorEpsilonBps: 10
        });

        DnmPool.PreviewConfig memory previewCfg = DnmPool.PreviewConfig({
            maxAgeSec: 5,
            snapshotCooldownSec: 2,
            revertOnStalePreview: false,
            enablePreviewFresh: true
        });

        DnmPool.FeatureFlags memory flags = DnmPool.FeatureFlags({
            blendOn: true,
            parityCiOn: true,
            debugEmit: false,
            enableSoftDivergence: true,
            enableSizeFee: true,
            enableBboFloor: true,
            enableInvTilt: true,
            enableAOMQ: true,
            enableRebates: false,
            enableAutoRecenter: true
        });

        DnmPool.Guardians memory guardians = DnmPool.Guardians({governance: deployer, pauser: deployer});
        DnmPool pool = new DnmPool(
            address(hype),
            address(usdc),
            18,
            6,
            address(hc),
            address(pyth),
            inventoryCfg,
            oracleCfg,
            feeCfg,
            makerCfg,
            aomqCfg,
            previewCfg,
            flags,
            guardians
        );

        string memory json = string.concat(
            '{"chainId":',
            vm.toString(block.chainid),
            ',"poolAddress":"',
            vm.toString(address(pool)),
            '","hypeAddress":"',
            vm.toString(address(hype)),
            '","usdcAddress":"',
            vm.toString(address(usdc)),
            '","hcPxPrecompile":"',
            vm.toString(address(hc)),
            '","hcBboPrecompile":"',
            vm.toString(address(hc)),
            '","pythAddress":"',
            vm.toString(address(pyth)),
            '"}'
        );

        string memory outputPath = vm.envOr("OUTPUT_JSON", string("metrics/hype-metrics/output/deploy-mocks.json"));
        vm.createDir("metrics/hype-metrics/output", true);
        vm.writeJson(json, outputPath);
        console2.log(json);

        vm.stopBroadcast();
    }
}
