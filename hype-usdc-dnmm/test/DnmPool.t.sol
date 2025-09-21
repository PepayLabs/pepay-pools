// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {DnmPool} from "../contracts/DnmPool.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";
import {MockOracleHC} from "../contracts/mocks/MockOracleHC.sol";
import {MockOraclePyth} from "../contracts/mocks/MockOraclePyth.sol";
import {IDnmPool} from "../contracts/interfaces/IDnmPool.sol";
import {IOracleAdapterPyth} from "../contracts/interfaces/IOracleAdapterPyth.sol";
import {FeeMath} from "../contracts/libraries/FeeMath.sol";

contract DnmPoolTest is Test {
    MockERC20 public base;
    MockERC20 public quote;
    MockOracleHC public oracleHC;
    MockOraclePyth public oraclePyth;
    DnmPool public pool;

    address public gov = address(0xA11CE);
    address public pauser = address(0xBEEF);
    address public user = address(0x1234);

    function setUp() public {
        base = new MockERC20("HYPE", "HYPE", 18, 1_000_000 ether, address(this));
        quote = new MockERC20("USDC", "USDC", 6, 1_000_000_000000, address(this));

        oracleHC = new MockOracleHC();
        oraclePyth = new MockOraclePyth();

        // Configure oracle defaults
        oracleHC.setSpot(1e18, 0, true);
        oracleHC.setBidAsk(1e18 - 5e14, 1e18 + 5e14, 10, true);
        oraclePyth.setResult(
            IOracleAdapterPyth.PythResult({
                hypeUsd: 1e18,
                usdcUsd: 1e18,
                ageSecHype: 0,
                ageSecUsdc: 0,
                confBpsHype: 10,
                confBpsUsdc: 10,
                success: true
            }),
            1e18,
            0,
            10
        );

        DnmPool.InventoryConfig memory inventoryCfg = DnmPool.InventoryConfig({
            targetBaseXstar: 50_000 ether,
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

        DnmPool.MakerConfig memory makerCfg = DnmPool.MakerConfig({s0Notional: 5_000 ether, ttlMs: 200});
        DnmPool.Guardians memory guardians = DnmPool.Guardians({governance: gov, pauser: pauser});

        pool = new DnmPool(
            address(base),
            address(quote),
            18,
            6,
            address(oracleHC),
            address(oraclePyth),
            inventoryCfg,
            oracleCfg,
            feeCfg,
            makerCfg,
            guardians
        );

        // Seed liquidity
        base.transfer(address(pool), 100_000 ether);
        quote.transfer(address(pool), 10_000_000000);
        pool.sync();

        base.transfer(user, 10_000 ether);
        quote.transfer(user, 1_000_000000);
    }

    function testSwapBaseForQuoteHappyPath() public {
        vm.prank(user);
        base.approve(address(pool), 1_000 ether);

        vm.prank(user);
        uint256 amountOut = pool.swapExactIn(
            1_000 ether,
            0,
            true,
            IDnmPool.OracleMode.Spot,
            bytes(""),
            block.timestamp + 1
        );

        assertGt(amountOut, 0, "amountOut zero");
        assertApproxEqRel(amountOut, 1_000 * 1e12, 0.01e18); // expect roughly parity minus fee
    }

    function testSpreadFallbackToPyth() public {
        oracleHC.setBidAsk(1e18 - 2e17, 1e18 + 2e17, 400, true); // widen spread beyond cap

        vm.prank(user);
        base.approve(address(pool), 100 ether);

        vm.prank(user);
        uint256 amountOut = pool.swapExactIn(
            100 ether,
            0,
            true,
            IDnmPool.OracleMode.Spot,
            bytes(""),
            block.timestamp + 1
        );

        assertGt(amountOut, 0, "fallback amountOut zero");
    }

    function testDivergenceReverts() public {
        // Configure Pyth to diverge by > divergenceBps
        oraclePyth.setResult(
            IOracleAdapterPyth.PythResult({
                hypeUsd: 12e17,
                usdcUsd: 1e18,
                ageSecHype: 0,
                ageSecUsdc: 0,
                confBpsHype: 10,
                confBpsUsdc: 10,
                success: true
            }),
            12e17,
            0,
            10
        );

        vm.prank(user);
        base.approve(address(pool), 100 ether);

        vm.prank(user);
        vm.expectRevert(bytes("ORACLE_DIVERGENCE"));
        pool.swapExactIn(
            100 ether,
            0,
            true,
            IDnmPool.OracleMode.Spot,
            bytes(""),
            block.timestamp + 1
        );
    }
}
