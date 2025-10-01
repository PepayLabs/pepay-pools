// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {DnmPool} from "../contracts/DnmPool.sol";
import {OracleAdapterHC} from "../contracts/oracle/OracleAdapterHC.sol";
import {HyperCoreConstants} from "../contracts/oracle/HyperCoreConstants.sol";
import {OracleAdapterPyth} from "../contracts/oracle/OracleAdapterPyth.sol";
import {FeePolicy} from "../contracts/lib/FeePolicy.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        // Default to SPOT_PX (0x0808) for spot markets, ORACLE_PX (0x0807) for perp
        bool isSpot = vm.envOr("DNMM_HYPERCORE_IS_SPOT", true);
        address hyperCorePrecompile = isSpot
            ? vm.envOr("DNMM_HYPERCORE_PRECOMPILE", HyperCoreConstants.SPOT_PX_PRECOMPILE)
            : vm.envOr("DNMM_HYPERCORE_PRECOMPILE", HyperCoreConstants.ORACLE_PX_PRECOMPILE);
        bytes32 assetIdHype = vm.envOr("DNMM_HYPERCORE_ASSET_ID_HYPE", bytes32("HYPE"));
        bytes32 assetIdUsdc = vm.envOr("DNMM_HYPERCORE_ASSET_ID_USDC", bytes32("USDC"));
        bytes32 marketId = vm.envOr("DNMM_HYPERCORE_MARKET_ID", bytes32("HYPE_USDC"));

        OracleAdapterHC hc = new OracleAdapterHC(hyperCorePrecompile, assetIdHype, assetIdUsdc, marketId, isSpot);

        address pythContract = vm.envAddress("DNMM_PYTH_CONTRACT");
        bytes32 priceIdHypeUsd = vm.envBytes32("DNMM_PYTH_PRICE_ID_HYPE_USD");
        bytes32 priceIdUsdcUsd = vm.envBytes32("DNMM_PYTH_PRICE_ID_USDC_USD");
        OracleAdapterPyth pyth = new OracleAdapterPyth(pythContract, priceIdHypeUsd, priceIdUsdcUsd);

        DnmPool.InventoryConfig memory inventoryCfg = DnmPool.InventoryConfig({
            targetBaseXstar: 0,
            floorBps: 300,
            recenterThresholdPct: 750,
            invTiltBpsPer1pct: 0,
            invTiltMaxBps: 0,
            tiltConfWeightBps: 0,
            tiltSpreadWeightBps: 0
        });

        DnmPool.OracleConfig memory oracleCfg = DnmPool.OracleConfig({
            maxAgeSec: 48,
            stallWindowSec: 10,
            confCapBpsSpot: 100,
            confCapBpsStrict: 100,
            divergenceBps: 50,
            allowEmaFallback: true,
            confWeightSpreadBps: 10_000,
            confWeightSigmaBps: 10_000,
            confWeightPythBps: 10_000,
            sigmaEwmaLambdaBps: 9000,
            divergenceAcceptBps: 30,
            divergenceSoftBps: 50,
            divergenceHardBps: 50,
            haircutMinBps: 3,
            haircutSlopeBps: 1
        });

        FeePolicy.FeeConfig memory feeCfg = FeePolicy.FeeConfig({
            baseBps: 15,
            alphaConfNumerator: 60,
            alphaConfDenominator: 100,
            betaInvDevNumerator: 10,
            betaInvDevDenominator: 100,
            capBps: 150,
            decayPctPerBlock: 20,
            gammaSizeLinBps: 0,
            gammaSizeQuadBps: 0,
            sizeFeeCapBps: 0
        });

        DnmPool.MakerConfig memory makerCfg = DnmPool.MakerConfig({
            s0Notional: 5_000 ether,
            ttlMs: 200,
            alphaBboBps: 0,
            betaFloorBps: 0
        });

        DnmPool.AomqConfig memory aomqCfg = DnmPool.AomqConfig({
            minQuoteNotional: 0,
            emergencySpreadBps: 0,
            floorEpsilonBps: 0
        });

        DnmPool.Guardians memory guardians = DnmPool.Guardians({governance: msg.sender, pauser: msg.sender});

        address baseToken = vm.envAddress("DNMM_BASE_TOKEN");
        address quoteToken = vm.envAddress("DNMM_QUOTE_TOKEN");
        uint8 baseDecimals = uint8(uint256(vm.envUint("DNMM_BASE_DECIMALS")));
        uint8 quoteDecimals = uint8(uint256(vm.envUint("DNMM_QUOTE_DECIMALS")));

        new DnmPool(
            baseToken,
            quoteToken,
            baseDecimals,
            quoteDecimals,
            address(hc),
            address(pyth),
            inventoryCfg,
            oracleCfg,
            feeCfg,
            makerCfg,
            aomqCfg,
            DnmPool.FeatureFlags({
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
            }),
            guardians
        );

        vm.stopBroadcast();
    }
}
