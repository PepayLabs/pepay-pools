// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {MockOracleHC} from "../../contracts/mocks/MockOracleHC.sol";
import {MockOraclePyth} from "../../contracts/mocks/MockOraclePyth.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract InvariantMidSelectionGates is StdInvariant, BaseTest {
    GateHandler internal handler;

    function setUp() public {
        setUpBase();
        handler = new GateHandler(pool, oracleHC, oraclePyth);
        targetContract(address(handler));
    }

    function invariant_mid_selection_obeys_gates() public view {
        (DnmPool.OracleConfig memory cfg, DnmPool.QuoteResult memory result, bool lastErrored, bytes memory err) =
            handler.snapshot();
        if (lastErrored) {
            if (err.length < 4) revert("missing selector");
            bytes4 selector;
            assembly {
                selector := mload(add(err, 32))
            }
            assertTrue(
                selector == Errors.OracleStale.selector || selector == Errors.OracleDiverged.selector,
                "unexpected error"
            );
        } else {
            if (result.usedFallback) {
                bool ema = result.reason == bytes32("EMA");
                bool pyth = result.reason == bytes32("PYTH");
                assertTrue(ema || pyth, "fallback reason");
            } else {
                assertEq(result.reason, bytes32(0), "no fallback reason expected");
            }

            if (!result.usedFallback) {
                require(handler.lastAge() <= cfg.maxAgeSec, "spot age within limit");
            }
        }
    }
}

contract GateHandler {
    DnmPool public pool;
    MockOracleHC public oracleHC;
    MockOraclePyth public oraclePyth;
    DnmPool.QuoteResult internal lastResult;
    bool internal lastErrored;
    bytes internal lastErrorData;
    uint256 internal lastAgeSec;

    constructor(DnmPool pool_, MockOracleHC oracleHC_, MockOraclePyth oraclePyth_) {
        pool = pool_;
        oracleHC = oracleHC_;
        oraclePyth = oraclePyth_;
    }

    function scenarioFresh() external {
        oracleHC.setSpot(1e18, 0, true);
        oracleHC.setBidAsk(9995e14, 10005e14, 20, true);
        IOracleAdapterPyth.PythResult memory res = IOracleAdapterPyth.PythResult({
            hypeUsd: 1e18,
            usdcUsd: 1e18,
            ageSecHype: 0,
            ageSecUsdc: 0,
            confBpsHype: 20,
            confBpsUsdc: 20,
            success: true
        });
        oraclePyth.setResult(res);
        lastAgeSec = 0;
        _quote();
    }

    function scenarioStale() external {
        oracleHC.setSpot(1e18, 500, true);
        oracleHC.setBidAsk(9995e14, 10005e14, 20, true);
        oracleHC.setEma(0, 0, false);
        IOracleAdapterPyth.PythResult memory res;
        res.success = false;
        oraclePyth.setResult(res);
        lastAgeSec = 500;
        _quote();
    }

    function scenarioEmaFallback() external {
        oracleHC.setSpot(1e18, 500, true);
        oracleHC.setEma(995e15, 3, true);
        oracleHC.setBidAsk(990e15, 1_010e15, 150, true);
        IOracleAdapterPyth.PythResult memory res;
        res.success = false;
        oraclePyth.setResult(res);
        lastAgeSec = 3;
        _quote();
    }

    function scenarioDivergence() external {
        oracleHC.setSpot(1e18, 0, true);
        oracleHC.setBidAsk(9995e14, 10005e14, 20, true);
        IOracleAdapterPyth.PythResult memory res = IOracleAdapterPyth.PythResult({
            hypeUsd: 12e17,
            usdcUsd: 1e18,
            ageSecHype: 0,
            ageSecUsdc: 0,
            confBpsHype: 20,
            confBpsUsdc: 20,
            success: true
        });
        oraclePyth.setResult(res);
        lastAgeSec = 0;
        _quote();
    }

    function _quote() internal {
        lastErrored = false;
        try pool.quoteSwapExactIn(1_000 ether, true, IDnmPool.OracleMode.Spot, bytes("")) returns (
            DnmPool.QuoteResult memory res
        ) {
            lastResult = res;
        } catch (bytes memory reason) {
            lastErrored = true;
            lastErrorData = reason;
        }
    }

    function snapshot()
        external
        view
        returns (DnmPool.OracleConfig memory cfg, DnmPool.QuoteResult memory res, bool errored, bytes memory err)
    {
        (
            uint32 maxAgeSec,
            uint32 stallWindowSec,
            uint16 confCapBpsSpot,
            uint16 confCapBpsStrict,
            uint16 divergenceBps,
            bool allowEmaFallback,
            uint16 confWeightSpreadBps,
            uint16 confWeightSigmaBps,
            uint16 confWeightPythBps,
            uint16 sigmaEwmaLambdaBps
        ) = pool.oracleConfig();
        cfg = DnmPool.OracleConfig({
            maxAgeSec: maxAgeSec,
            stallWindowSec: stallWindowSec,
            confCapBpsSpot: confCapBpsSpot,
            confCapBpsStrict: confCapBpsStrict,
            divergenceBps: divergenceBps,
            allowEmaFallback: allowEmaFallback,
            confWeightSpreadBps: confWeightSpreadBps,
            confWeightSigmaBps: confWeightSigmaBps,
            confWeightPythBps: confWeightPythBps,
            sigmaEwmaLambdaBps: sigmaEwmaLambdaBps
        });
        res = lastResult;
        errored = lastErrored;
        err = lastErrorData;
    }

    function lastAge() external view returns (uint256) {
        return lastAgeSec;
    }
}
