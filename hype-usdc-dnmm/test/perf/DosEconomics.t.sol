// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract DosEconomicsTest is BaseTest {
    uint256 internal constant SAMPLE_COUNT = 1000;
    uint256 internal constant MAX_FAILURE_GAS = 120_000;

    function setUp() public {
        setUpBase();
        approveAll(alice);
        enableBlend();
    }

    function test_failure_paths_are_cheap_and_stateless() public {
        (uint128 baseBefore, uint128 quoteBefore) = pool.reserves();

        string[] memory rows = new string[](3);
        uint256 rowIdx;

        rowIdx = _recordBurst(rows, rowIdx, "STALE", Errors.OracleStale.selector, _configureStaleScenario);
        rowIdx = _recordBurst(rows, rowIdx, "SPREAD", Errors.OracleSpread.selector, _configureSpreadScenario);
        rowIdx = _recordBurst(rows, rowIdx, "DIVERGENCE", Errors.OracleDiverged.selector, _configureDivergenceScenario);

        EventRecorder.writeCSV(vm, "metrics/gas_dos_failures.csv", "reason,avg_gas,max_gas", rows);

        (uint128 baseAfter, uint128 quoteAfter) = pool.reserves();
        assertEq(baseAfter, baseBefore, "base reserves drift");
        assertEq(quoteAfter, quoteBefore, "quote reserves drift");
    }

    function _recordBurst(
        string[] memory rows,
        uint256 startIdx,
        string memory label,
        bytes4 expectedSelector,
        function() internal configure
    ) internal returns (uint256 nextIdx) {
        configure();

        uint256 totalGas;
        uint256 maxGas;

        for (uint256 i = 0; i < SAMPLE_COUNT; ++i) {
            uint256 gasBefore = gasleft();
            (bool ok, bytes memory data) = address(pool).call(
                abi.encodeWithSelector(
                    IDnmPool.quoteSwapExactIn.selector, 10 ether, true, IDnmPool.OracleMode.Spot, bytes("")
                )
            );
            uint256 gasUsed = gasBefore - gasleft();
            require(!ok, "expected failure");
            require(gasUsed <= MAX_FAILURE_GAS, "failure gas too high");
            bytes4 selector = _decodeRevertSelector(data);
            require(selector == expectedSelector, "unexpected revert selector");
            totalGas += gasUsed;
            if (gasUsed > maxGas) {
                maxGas = gasUsed;
            }
        }

        uint256 avgGas = totalGas / SAMPLE_COUNT;
        rows[startIdx] =
            string.concat(label, ",", EventRecorder.uintToString(avgGas), ",", EventRecorder.uintToString(maxGas));

        return startIdx + 1;
    }

    function _configureStaleScenario() internal {
        updateSpot(0, 0, false);
        updateBidAsk(0, 0, 0, false);
        updateEma(0, 0, false);
        updatePyth(0, 0, 0, 0, 0, 0);
    }

    function _configureSpreadScenario() internal {
        updateSpot(1e18, 1, true);
        updateBidAsk(900e15, 1_100e15, 500, true);
        updateEma(0, 0, false);
        updatePyth(0, 0, 0, 0, 0, 0);
    }

    function _configureDivergenceScenario() internal {
        updateSpot(1e18, 1, true);
        updateBidAsk(995e15, 1_005e15, 20, true);
        updateEma(1e18, 2, true);
        updatePyth(1_120_000_000_000_000_000, 1e18, 1, 1, 30, 30);
    }

    function _decodeRevertSelector(bytes memory revertData) internal pure returns (bytes4) {
        if (revertData.length < 4) return bytes4(0);
        bytes4 selector;
        assembly {
            selector := mload(add(revertData, 32))
        }
        return selector;
    }
}
