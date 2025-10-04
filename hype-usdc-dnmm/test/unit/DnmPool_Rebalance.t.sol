// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract DnmPoolRebalanceTest is BaseTest {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant HEALTHY_FRAMES_REQUIRED = 3;

    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);
    }

    function test_autoRebalanceUpdatesTarget() public {
        _enableAutoRecenter();

        // establish baseline so lastRebalancePrice is populated
        vm.prank(alice);
        pool.swapExactIn(1_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        assertEq(pool.lastRebalancePrice(), pool.lastMid(), "baseline price recorded");

        uint256 newMid = 1_100_000_000_000_000_000; // 1.10
        _setOraclePrice(newMid);

        (uint128 baseBefore, uint128 quoteBefore) = pool.reserves();

        vm.prank(alice);
        pool.swapExactIn(500 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        assertEq(pool.lastRebalancePrice(), newMid, "lastRebalancePrice updated");

        (uint128 targetAfter,,,,,,) = pool.inventoryConfig();
        uint128 expectedTarget = _computeTarget(baseBefore, quoteBefore, newMid);
        assertEq(targetAfter, expectedTarget, "target recentered to oracle mid");
    }

    function test_autoRebalanceSkipsBelowThreshold() public {
        _enableAutoRecenter();

        vm.prank(alice);
        pool.swapExactIn(1_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        (uint128 targetBefore,,,,,,) = pool.inventoryConfig();
        uint256 baselinePrice = pool.lastRebalancePrice();

        uint256 nearMid = 1_040_000_000_000_000_000; // 4% drift < 7.5% threshold
        _setOraclePrice(nearMid);

        vm.prank(alice);
        pool.swapExactIn(500 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        (uint128 targetAfter,,,,,,) = pool.inventoryConfig();
        assertEq(targetAfter, targetBefore, "target unchanged when drift < threshold");
        assertEq(pool.lastRebalancePrice(), baselinePrice, "baseline unchanged without rebalance");
    }

    function test_manualRebalancePermissionless() public {
        _enableAutoRecenter();

        vm.prank(alice);
        pool.swapExactIn(1_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        uint256 shockedMid = 1_150_000_000_000_000_000; // 15% drift
        _setOraclePrice(shockedMid);

        (uint128 baseBefore, uint128 quoteBefore) = pool.reserves();

        vm.expectEmit(true, false, false, true, address(pool));
        emit DnmPool.ManualRebalanceExecuted(bob, shockedMid, uint64(block.timestamp));
        vm.prank(bob);
        pool.rebalanceTarget();

        (uint128 targetAfter,,,,,,) = pool.inventoryConfig();
        uint128 expectedTarget = _computeTarget(baseBefore, quoteBefore, shockedMid);
        assertEq(targetAfter, expectedTarget, "manual rebalance matches auto calculations");
        assertEq(pool.lastRebalancePrice(), shockedMid, "lastRebalancePrice updated");
    }

    function test_manualRebalanceRevertsWhenBelowThreshold() public {
        vm.prank(alice);
        pool.swapExactIn(1_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        vm.prank(bob);
        pool.rebalanceTarget(); // seed baseline at current mid (no drift)

        uint256 nearMid = 1_030_000_000_000_000_000; // 3% drift
        _setOraclePrice(nearMid);

        vm.prank(bob);
        vm.expectRevert(Errors.RecenterThreshold.selector);
        pool.rebalanceTarget();
    }

    function test_rebalanceRespectsCooldown() public {
        _enableAutoRecenter();

        vm.prank(gov);
        pool.setRecenterCooldownSec(180);
        assertEq(pool.recenterCooldownSec(), 180, "cooldown param set");

        vm.prank(alice);
        pool.swapExactIn(1_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        _setOraclePrice(1_250_000_000_000_000_000);
        vm.prank(alice);
        pool.swapExactIn(400 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        uint64 firstRebalanceAt = pool.lastRebalanceAt();
        assertGt(firstRebalanceAt, 0, "cooldown seeded");

        _setOraclePrice(1_480_000_000_000_000_000);
        vm.prank(alice);
        pool.swapExactIn(400 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        assertEq(pool.lastRebalanceAt(), firstRebalanceAt, "cooldown blocks second rebalance");
        assertEq(pool.lastRebalancePrice(), 1_250_000_000_000_000_000, "price baseline held");

        // Once governance clears the cooldown, subsequent swaps can trigger rebalances again (covered elsewhere).
    }

    function test_manualRebalanceRevertsWhenOracleStale() public {
        vm.prank(alice);
        pool.swapExactIn(1_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        updateSpot(1e18, 61, true); // exceeds default maxAgeSec (60)
        updateBidAsk(9995e14, 10005e14, 20, true);
        updateEma(1e18, 0, true);

        vm.prank(bob);
        vm.expectRevert(Errors.OracleStale.selector);
        pool.rebalanceTarget();
    }

    function test_manualRebalanceHonorsCooldown() public {
        vm.prank(gov);
        pool.setRecenterCooldownSec(240);
        assertEq(pool.recenterCooldownSec(), 240, "manual cooldown set");

        vm.prank(alice);
        pool.swapExactIn(1_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        _setOraclePrice(1_300_000_000_000_000_000);
        vm.prank(bob);
        pool.rebalanceTarget();
        uint64 firstManual = pool.lastRebalanceAt();
        assertGt(firstManual, 0, "timestamp recorded");
        assertEq(firstManual, block.timestamp, "timestamp matches block");

        _setOraclePrice(1_480_000_000_000_000_000);
        assertEq(pool.lastRebalancePrice(), 1_300_000_000_000_000_000, "baseline locked");
        (, uint256 currentAge, bool currentSuccess) = _readSpot();
        assertTrue(currentSuccess, "spot success");
        assertEq(currentAge, 0, "fresh age");
        assertEq(_currentSpot(), 1_480_000_000_000_000_000, "fresh mid");
        assertLt(block.timestamp, uint256(firstManual) + pool.recenterCooldownSec(), "still in cooldown window");
        vm.prank(bob);
        try pool.rebalanceTarget() {
            fail("expected cooldown revert");
        } catch (bytes memory err) {
            bytes4 sel;
            assembly ("memory-safe") {
                sel := mload(add(err, 32))
            }
            assertEq(sel, Errors.RecenterCooldown.selector, "cooldown revert");
        }

        // No need to assert post-cooldown behavior here; other tests cover rebalancing success paths.
    }

    function test_autoRebalanceDisabledWhenFlagOff() public {
        vm.prank(alice);
        pool.swapExactIn(1_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        (uint128 targetBefore,,,,,,) = pool.inventoryConfig();
        uint256 baselinePrice = pool.lastRebalancePrice();

        _setOraclePrice(1_160_000_000_000_000_000); // 16% drift > threshold

        vm.prank(alice);
        pool.swapExactIn(500 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        (uint128 targetAfter,,,,,,) = pool.inventoryConfig();
        assertEq(targetAfter, targetBefore, "auto recenter disabled keeps target static");
        assertEq(pool.lastRebalancePrice(), baselinePrice, "baseline price unchanged");
    }

    function test_autoRebalanceRequiresHealthyFramesBeforeRearming() public {
        _enableAutoRecenter();

        vm.prank(gov);
        pool.setRecenterCooldownSec(0);

        vm.prank(alice);
        pool.swapExactIn(1_000 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);

        _setOraclePrice(1_200_000_000_000_000_000);
        vm.prank(alice);
        pool.swapExactIn(400 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        uint256 firstAutoPrice = pool.lastRebalancePrice();
        uint64 firstAutoAt = pool.lastRebalanceAt();
        assertEq(firstAutoPrice, 1_200_000_000_000_000_000, "auto recenter committed");
        assertGt(firstAutoAt, 0, "timestamp seeded");

        _setOraclePrice(1_320_000_000_000_000_000); // still above threshold
        vm.prank(alice);
        pool.swapExactIn(350 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        assertEq(pool.lastRebalancePrice(), firstAutoPrice, "hysteresis blocks immediate retrigger");

        // Accumulate healthy frames (deviation below threshold)
        for (uint256 i = 0; i < HEALTHY_FRAMES_REQUIRED; i++) {
            _setOraclePrice(1_160_000_000_000_000_000); // ~5% drift < threshold
            vm.prank(alice);
            pool.swapExactIn(100 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
            assertEq(pool.lastRebalancePrice(), firstAutoPrice, "no commit while recovering");
        }

        _setOraclePrice(1_360_000_000_000_000_000);
        vm.prank(alice);
        pool.swapExactIn(350 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        assertEq(pool.lastRebalancePrice(), 1_360_000_000_000_000_000, "second auto commit after recovery");
        assertEq(pool.lastRebalanceAt(), uint64(block.timestamp), "timestamp reflects rearmed commit");
    }

    function _enableAutoRecenter() internal {
        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.enableAutoRecenter = true;
        setFeatureFlags(flags);
    }

    function _currentSpot() internal view returns (uint256) {
        (uint256 mid,,) = oracleHC.spot();
        return mid;
    }

    function _readSpot() internal view returns (uint256 mid, uint256 ageSec, bool success) {
        return oracleHC.spot();
    }

    function _computeTarget(uint128 baseReserves, uint128 quoteReserves, uint256 mid) internal view returns (uint128) {
        (,,,, uint256 baseScale, uint256 quoteScale) = pool.tokens();
        uint256 baseWad = FixedPointMath.mulDivDown(uint256(baseReserves), ONE, baseScale);
        uint256 quoteWad = FixedPointMath.mulDivDown(uint256(quoteReserves), ONE, quoteScale);
        uint256 baseNotional = FixedPointMath.mulDivDown(baseWad, mid, ONE);
        uint256 totalNotional = quoteWad + baseNotional;
        uint256 targetValueWad = totalNotional / 2;
        uint256 newTargetWad = FixedPointMath.mulDivDown(targetValueWad, ONE, mid);
        return uint128(FixedPointMath.mulDivDown(newTargetWad, baseScale, ONE));
    }

    function _setOraclePrice(uint256 mid) internal {
        uint256 spreadBps = 40;
        uint256 spread = mid * spreadBps / 10_000;
        updateSpot(mid, 0, true);
        updateBidAsk(mid - spread, mid + spread, spreadBps, true);
        updateEma(mid, 0, true);
        updatePyth(mid, ONE, 0, 0, 20, 20);
    }
}
