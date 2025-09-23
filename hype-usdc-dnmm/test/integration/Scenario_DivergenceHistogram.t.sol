// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Errors} from "../../contracts/lib/Errors.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract ScenarioDivergenceHistogramTest is BaseTest {
    uint256[] internal bins = [10, 25, 49, 50, 60, 100, 1200];
    uint256 internal divergenceThreshold;

    function setUp() public {
        setUpBase();

        DnmPool.OracleConfig memory cfg = defaultOracleConfig();
        cfg.divergenceBps = 50;
        cfg.maxAgeSec = 60;
        vm.prank(gov);
        pool.updateParams(DnmPool.ParamKind.Oracle, abi.encode(cfg));
        divergenceThreshold = cfg.divergenceBps;

        // ensure EMA fallback disabled in this scenario so divergence comes from spot/hc path
        updateBidAsk(998e15, 1_002e15, 20, true);
        updatePyth(1e18, 1e18, 0, 0, 20, 20);
    }

    function test_divergence_histogram_export() public {
        string[] memory rows = new string[](bins.length);

        for (uint256 i = 0; i < bins.length; ++i) {
            uint256 binBps = bins[i];
            _setDivergence(binBps);

            uint256 attempts = 1;
            uint256 rejects;

            if (binBps > divergenceThreshold) {
                vm.expectRevert(Errors.OracleDivergence.selector);
                _attemptQuote();
                rejects = 1;
            } else {
                _attemptQuote();
                rejects = 0;
            }

            uint256 rateBps = rejects * 10_000 / attempts;
            rows[i] = string.concat(
                EventRecorder.uintToString(binBps),
                ",",
                EventRecorder.uintToString(attempts),
                ",",
                EventRecorder.uintToString(rejects),
                ",",
                EventRecorder.uintToString(rateBps)
            );
        }

        EventRecorder.writeCSV(
            vm,
            "metrics/divergence_histogram.csv",
            "bin_bps,attempts,rejects,rate_bps",
            rows
        );
    }

    function _attemptQuote() internal {
        pool.quoteSwapExactIn(5 ether, true, IDnmPool.OracleMode.Spot, bytes(""));
    }

    function _setDivergence(uint256 deltaBps) internal {
        uint256 baseMid = 1e18;
        updateSpot(baseMid, 5, true);
        uint256 adjustedMid = baseMid * (10_000 + deltaBps) / 10_000;
        updatePyth(adjustedMid, 1e18, 0, 0, 20, 20);
    }
}
