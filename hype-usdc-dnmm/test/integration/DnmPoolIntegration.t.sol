// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {DnmPool} from "../../contracts/DnmPool.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {MockOracleHC} from "../../contracts/mocks/MockOracleHC.sol";
import {MockOraclePyth} from "../../contracts/mocks/MockOraclePyth.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";

contract DnmPoolIntegrationTest is Test {
    DnmPool internal pool;
    MockERC20 internal hype;
    MockERC20 internal usdc;
    MockOracleHC internal hc;
    MockOraclePyth internal pyth;
    address internal gov = address(0xA11CE);

    function setUp() public {
        hype = new MockERC20("HYPE", "HYPE", 18, 1_000_000 ether, address(this));
        usdc = new MockERC20("USDC", "USDC", 6, 1_000_000_000000, address(this));
        hc = new MockOracleHC();
        pyth = new MockOraclePyth();

        hc.setSpot(1e18, 0, true);
        hc.setBidAsk(1e18 - 2e14, 1e18 + 2e14, 40, true);
        pyth.setResult(defaultPyth(), 1e18, 0, 40);

        DnmPool.InventoryConfig memory inventoryCfg = DnmPool.InventoryConfig({
            targetBaseXstar: 50_000 ether,
            floorBps: 300,
            recenterThresholdPct: 750
        });

        DnmPool.OracleConfig memory oracleCfg = DnmPool.OracleConfig({
            maxAgeSec: 48,
            stallWindowSec: 10,
            confCapBpsSpot: 100,
            confCapBpsStrict: 100,
            divergenceBps: 50,
            allowEmaFallback: true
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
        DnmPool.Guardians memory guardians = DnmPool.Guardians({governance: gov, pauser: gov});

        pool = new DnmPool(
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
            guardians
        );

        hype.transfer(address(pool), 100_000 ether);
        usdc.transfer(address(pool), 10_000_000000);
        pool.sync();
    }

    function testRecenterGate() public {
        vm.startPrank(gov);
        vm.expectRevert("THRESHOLD");
        pool.setTargetBaseXstar(49_500 ether);

        // Move price by threshold
        hc.setSpot(11e17, 0, true); // +10%
        pool.setTargetBaseXstar(49_500 ether);
        vm.stopPrank();
    }

    function testFallbackToPythWhenSpotStale() public {
        hc.setSpot(0, 100, false);
        pyth.setResult(stalePyth(), 98e16, 0, 80);

        hype.approve(address(pool), 100 ether);
        pool.swapExactIn(100 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
    }

    function defaultPyth() internal pure returns (MockOraclePyth.PythResult memory r) {
        r = MockOraclePyth.PythResult({
            hypeUsd: 1e18,
            usdcUsd: 1e18,
            ageSecHype: 0,
            ageSecUsdc: 0,
            confBpsHype: 40,
            confBpsUsdc: 40,
            success: true
        });
    }

    function stalePyth() internal pure returns (MockOraclePyth.PythResult memory r) {
        r = MockOraclePyth.PythResult({
            hypeUsd: 98e16,
            usdcUsd: 1e18,
            ageSecHype: 5,
            ageSecUsdc: 5,
            confBpsHype: 80,
            confBpsUsdc: 40,
            success: true
        });
    }
}
