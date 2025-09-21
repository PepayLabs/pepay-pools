// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {DnmPool} from "../contracts/DnmPool.sol";
import {OracleAdapterHC} from "../contracts/OracleAdapterHC.sol";
import {OracleAdapterPyth} from "../contracts/OracleAdapterPyth.sol";
import {FeeMath} from "../contracts/libraries/FeeMath.sol";

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

        DnmPool.InventoryConfig memory inventoryCfg = DnmPool.InventoryConfig({
            targetBaseXstar: 0,
            floorBps: 300,
            recenterThresholdPct: 750
        });

        DnmPool.OracleConfig memory oracleCfg = DnmPool.OracleConfig({
            maxAgeSec: 5,
            stallWindowSec: 2,
            confCapBpsSpot: 75,
            confCapBpsStrict: 50,
            divergenceBps: 50,
            allowEmaFallback: true
        });

        FeeMath.FeeConfig memory feeCfg = FeeMath.FeeConfig({
            baseBps: 15,
            alphaConfNumerator: 60,
            alphaConfDenominator: 100,
            betaInvDevNumerator: 10,
            betaInvDevDenominator: 100,
            capBps: 150,
            decayPctPerBlock: 20
        });

        DnmPool.MakerConfig memory makerCfg = DnmPool.MakerConfig({
            s0Notional: 5_000 ether,
            ttlMs: 200
        });

        DnmPool.Guardians memory guardians = DnmPool.Guardians({
            governance: msg.sender,
            pauser: msg.sender
        });

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
            guardians
        );

        vm.stopBroadcast();
    }
}
