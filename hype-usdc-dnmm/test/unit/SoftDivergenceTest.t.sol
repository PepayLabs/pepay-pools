// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {OracleUtils} from "../../contracts/lib/OracleUtils.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract SoftDivergenceTest is BaseTest {
    uint256 internal constant ONE = 1e18;

    struct Thresholds {
        uint16 accept;
        uint16 soft;
        uint16 hard;
        uint16 minHaircut;
        uint16 slope;
    }

    Thresholds internal thresholds;

    function setUp() public {
        setUpBase();
        approveAll(alice);

        thresholds = Thresholds({accept: 30, soft: 60, hard: 90, minHaircut: 3, slope: 2});

        DnmPool.OracleConfig memory cfg = defaultOracleConfig();
        cfg.divergenceAcceptBps = thresholds.accept;
        cfg.divergenceSoftBps = thresholds.soft;
        cfg.divergenceHardBps = thresholds.hard;
        cfg.haircutMinBps = thresholds.minHaircut;
        cfg.haircutSlopeBps = thresholds.slope;

        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Oracle, abi.encode(cfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.blendOn = true;
        flags.enableSoftDivergence = true;
        setFeatureFlags(flags);

        // reset oracle surfaces to aligned baseline
        _setAlignedOracles();
    }

    function test_noHaircutWithinAcceptBand() public {
        _setDivergenceBps(25); // Below accept threshold
        uint256 snapshotId = vm.snapshot();

        uint16 feeWithoutHaircut = _quoteFee();
        vm.revertTo(snapshotId);

        uint16 feeWithHaircutEnabled = _quoteFee();
        assertEq(feeWithHaircutEnabled, feeWithoutHaircut, "no haircut within accept band");

        (bool active,,) = pool.getSoftDivergenceState();
        assertFalse(active, "soft divergence state inactive");
    }

    function test_softBandAppliesHaircutAndEmitsEvent() public {
        uint256 hcMid = ONE;
        uint256 pythMid = (ONE * 10040) / 10000; // ~40 bps divergence
        _setOracles(hcMid, pythMid);

        uint256 delta = OracleUtils.computeDivergenceBps(hcMid, pythMid);
        uint256 expectedHaircut = thresholds.minHaircut + thresholds.slope * (delta - thresholds.accept);

        uint256 snapshotId = vm.snapshot();
        {
            DnmPool.FeatureFlags memory flags = getFeatureFlags();
            flags.enableSoftDivergence = false;
            setFeatureFlags(flags);
        }
        uint16 baselineFee = _quoteFee();
        vm.revertTo(snapshotId);

        vm.expectEmit(true, false, false, true, address(pool));
        emit DnmPool.DivergenceHaircut(delta, expectedHaircut);
        uint16 haircutFee = _quoteFee();

        assertEq(haircutFee - baselineFee, expectedHaircut, "haircut applied");

        (bool active, uint16 lastDelta, uint8 healthyStreak) = pool.getSoftDivergenceState();
        assertTrue(active, "soft divergence active after haircut");
        assertEq(lastDelta, delta, "state tracks last delta");
        assertEq(healthyStreak, 0, "reset healthy streak on soft activation");
    }

    function test_hardBandRejectsAndEmitsEvent() public {
        uint256 hcMid = ONE;
        uint256 pythMid = (ONE * 10150) / 10000; // ~149 bps
        _setOracles(hcMid, pythMid);

        uint256 delta = OracleUtils.computeDivergenceBps(hcMid, pythMid);

        vm.expectEmit(true, false, false, true, address(pool));
        emit DnmPool.DivergenceRejected(delta);
        vm.expectRevert(abi.encodeWithSelector(Errors.DivergenceHard.selector, delta, uint256(thresholds.hard)));
        quote(10 ether, true, IDnmPool.OracleMode.Spot);
    }

    function test_hysteresisRequiresThreeHealthyQuotes() public {
        uint256 hcMid = ONE;
        uint256 pythMid = (ONE * 10050) / 10000; // ~50 bps divergence
        _setOracles(hcMid, pythMid);
        _quoteFee();

        (bool active,, uint8 streak) = pool.getSoftDivergenceState();
        assertTrue(active, "soft divergence active");
        assertEq(streak, 0, "streak reset");

        // Step 1: healthy sample below accept
        _setDivergenceBps(20);
        _quoteFee();
        (active,, streak) = pool.getSoftDivergenceState();
        assertTrue(active, "still active after one healthy sample");
        assertEq(streak, 1, "streak increments");

        // Step 2
        _setDivergenceBps(15);
        _quoteFee();
        (active,, streak) = pool.getSoftDivergenceState();
        assertTrue(active, "requires third healthy sample");
        assertEq(streak, 2);

        // Step 3 resets state
        _setDivergenceBps(10);
        _quoteFee();
        (active,, streak) = pool.getSoftDivergenceState();
        assertFalse(active, "soft divergence cleared after three healthy samples");
        assertEq(streak, 3, "streak capped at hysteresis");
    }

    function _quoteFee() internal returns (uint16) {
        DnmPool.QuoteResult memory result = quote(10 ether, true, IDnmPool.OracleMode.Spot);
        return uint16(result.feeBpsUsed);
    }

    function _setAlignedOracles() internal {
        _setOracles(ONE, ONE);
    }

    function _setOracles(uint256 hcMid, uint256 pythMid) internal {
        updateSpot(hcMid, 1, true);
        uint256 bid = (hcMid * 9990) / 10000;
        uint256 ask = (hcMid * 10010) / 10000;
        updateBidAsk(bid, ask, OracleUtils.computeSpreadBps(bid, ask), true);
        updateEma(hcMid, 0, true);
        updatePyth(pythMid, ONE, 0, 0, 10, 10);
    }

    function _setDivergenceBps(uint256 deltaBps) internal {
        uint256 hcMid = ONE;
        uint256 hi = (hcMid * (10000 + deltaBps)) / 10000;
        if (deltaBps == 0) {
            _setOracles(hcMid, hcMid);
        } else {
            _setOracles(hcMid, hi);
        }
    }
}
