// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {DnmPool} from "../contracts/DnmPool.sol";
import {OracleAdapterHC} from "../contracts/oracle/OracleAdapterHC.sol";
import {OracleAdapterPyth} from "../contracts/oracle/OracleAdapterPyth.sol";
import {FeePolicy} from "../contracts/lib/FeePolicy.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        // TODO: replace with live addresses
        address hyperCorePrecompile = address(0x1234);
        bytes32 assetIdHype = bytes32("HYPE");
        bytes32 assetIdUsdc = bytes32("USDC");
        bytes32 marketId = bytes32("HYPE_USDC");

        OracleAdapterHC hc = new OracleAdapterHC(hyperCorePrecompile, assetIdHype, assetIdUsdc, marketId);

        address pythContract = address(0x5678);
        bytes32 priceIdHypeUsd = bytes32(0);
        bytes32 priceIdUsdcUsd = bytes32(0);
        OracleAdapterPyth pyth = new OracleAdapterPyth(pythContract, priceIdHypeUsd, priceIdUsdcUsd);

        DnmPool.InventoryConfig memory inventoryCfg =
            DnmPool.InventoryConfig({targetBaseXstar: 0, floorBps: 300, recenterThresholdPct: 750});

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
            sigmaEwmaLambdaBps: 9000
        });

        FeePolicy.FeeConfig memory feeCfg = FeePolicy.FeeConfig({
            baseBps: 15,
            alphaConfNumerator: 60,
            alphaConfDenominator: 100,
            betaInvDevNumerator: 10,
            betaInvDevDenominator: 100,
            capBps: 150,
            decayPctPerBlock: 20
        });

        DnmPool.MakerConfig memory makerCfg = DnmPool.MakerConfig({s0Notional: 5_000 ether, ttlMs: 200});

        DnmPool.Guardians memory guardians = DnmPool.Guardians({governance: msg.sender, pauser: msg.sender});

        new DnmPool(
            address(0),
            address(0),
            18,
            6,
            address(hc),
            address(pyth),
            inventoryCfg,
            oracleCfg,
            feeCfg,
            makerCfg,
            DnmPool.FeatureFlags({blendOn: true, parityCiOn: true, debugEmit: true}),
            guardians
        );

        vm.stopBroadcast();
    }
}
