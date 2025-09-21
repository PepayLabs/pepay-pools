// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {Inventory} from "../../contracts/lib/Inventory.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {ReentrantERC20, MaliciousReceiver} from "../utils/Mocks.sol";
import {MockOracleHC} from "../../contracts/mocks/MockOracleHC.sol";
import {MockOraclePyth} from "../../contracts/mocks/MockOraclePyth.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

contract DnmPoolSwapTest is BaseTest {
    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
    }

    function test_swap_base_in_normal() public {
        recordLogs();
        vm.prank(alice);
        uint256 amountOut = pool.swapExactIn(1_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        assertGt(amountOut, 0, "amount out");
        EventRecorder.SwapEvent[] memory swaps = drainLogsToSwapEvents();
        assertEq(swaps.length, 1, "swap event");
        assertEq(swaps[0].amountOut, amountOut, "event amount");
        assertFalse(swaps[0].isPartial, "not partial");
        assertEq(swaps[0].reason, bytes32(0), "no reason");
    }

    function test_swap_quote_in_normal() public {
        recordLogs();
        vm.prank(bob);
        uint256 amountOut = pool.swapExactIn(500_000000, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        assertGt(amountOut, 0, "amount out");
        EventRecorder.SwapEvent[] memory swaps = drainLogsToSwapEvents();
        assertEq(swaps[0].amountOut, amountOut, "event out");
        assertFalse(swaps[0].isPartial, "partial");
    }

    function test_swap_partial_fill_floor_protection() public {
        uint256 largeAmount = 400_000 ether;
        (uint128 baseBefore, uint128 quoteBefore) = pool.reserves();
        (, uint16 floorBps,) = pool.inventoryConfig();
        uint256 expectedFloor = Inventory.floorAmount(uint256(quoteBefore), floorBps);

        DnmPool.QuoteResult memory preview = quote(largeAmount, true, IDnmPool.OracleMode.Spot);
        assertGt(preview.partialFillAmountIn, 0, "partial expected");

        recordLogs();
        vm.prank(alice);
        uint256 amountOut = pool.swapExactIn(largeAmount, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        EventRecorder.SwapEvent[] memory swaps = drainLogsToSwapEvents();
        assertTrue(swaps[0].isPartial, "partial fill");
        assertEq(swaps[0].reason, bytes32("FLOOR"), "floor reason");
        assertEq(amountOut, swaps[0].amountOut, "amount matches");

        (, uint128 quoteAfter) = pool.reserves();
        assertEq(uint256(quoteAfter), expectedFloor, "floor respected");
    }

    function test_swap_deadline_reverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes(Errors.DEADLINE_EXPIRED));
        pool.swapExactIn(1_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp - 1);
    }

    function test_swap_minOut_reverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("SLIPPAGE"));
        pool.swapExactIn(1_000 ether, 2_000_000000, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
    }

    function test_reentrancy_guard_blocks_callback() public {
        MockERC20 baseToken = new MockERC20("HYPE", "HYPE", 18, 2_000_000 ether, address(this));
        ReentrantERC20 quoteToken = new ReentrantERC20("USDC", "USDC", 6);
        quoteToken.mint(address(this), 2_000_000_000000);

        MockOracleHC hc = new MockOracleHC();
        MockOraclePyth pyth = new MockOraclePyth();
        hc.setSpot(1e18, 0, true);
        hc.setBidAsk(9995e14, 10005e14, 20, true);
        hc.setEma(1e18, 0, true);
        IOracleAdapterPyth.PythResult memory result = IOracleAdapterPyth.PythResult({
            hypeUsd: 1e18,
            usdcUsd: 1e18,
            ageSecHype: 0,
            ageSecUsdc: 0,
            confBpsHype: 20,
            confBpsUsdc: 20,
            success: true
        });
        pyth.setResult(result);

        DnmPool poolLocal = new DnmPool(
            address(baseToken),
            address(quoteToken),
            18,
            6,
            address(hc),
            address(pyth),
            defaultInventoryConfig(),
            defaultOracleConfig(),
            defaultFeeConfig(),
            defaultMakerConfig(),
            DnmPool.Guardians({governance: gov, pauser: pauser})
        );

        baseToken.transfer(address(poolLocal), 100_000 ether);
        quoteToken.transfer(address(poolLocal), 10_000_000000);
        poolLocal.sync();

        MaliciousReceiver attacker = new MaliciousReceiver();
        attacker.configure(poolLocal, address(baseToken), address(quoteToken));
        attacker.setAttackSide(true);
        attacker.setTrigger(true);
        quoteToken.setHook(address(attacker));

        baseToken.transfer(address(attacker), 10_000 ether);
        quoteToken.transfer(address(attacker), 1_000_000000);

        vm.prank(address(attacker));
        vm.expectRevert(bytes("REENTRANCY"));
        attacker.executeAttack(1_000 ether);
    }
}
