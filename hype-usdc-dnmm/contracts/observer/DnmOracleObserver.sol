// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapterHC} from "../interfaces/IOracleAdapterHC.sol";
import {IOracleAdapterPyth} from "../interfaces/IOracleAdapterPyth.sol";
import {OracleUtils} from "../lib/OracleUtils.sol";

/// @notice Lightweight on-chain observer that mirrors the pool's oracle reads for shadow parity checks.
contract DnmOracleObserver {
    using OracleUtils for uint256;

    IOracleAdapterHC internal immutable ORACLE_HC_;
    IOracleAdapterPyth internal immutable ORACLE_PYTH_;

    struct Snapshot {
        uint256 mid;
        uint256 ageSec;
        uint256 spreadBps;
        uint256 pythMid;
        uint256 deltaBps;
        bool hcSuccess;
        bool bookSuccess;
        bool pythSuccess;
    }

    event OracleSnapshot(
        bytes32 label,
        uint256 mid,
        uint256 ageSec,
        uint256 spreadBps,
        uint256 pythMid,
        uint256 deltaBps,
        bool hcSuccess,
        bool bookSuccess,
        bool pythSuccess
    );

    constructor(IOracleAdapterHC oracleHc_, IOracleAdapterPyth oraclePyth_) {
        ORACLE_HC_ = oracleHc_;
        ORACLE_PYTH_ = oraclePyth_;
    }

    function oracleHc() public view returns (IOracleAdapterHC) {
        return ORACLE_HC_;
    }

    function oraclePyth() public view returns (IOracleAdapterPyth) {
        return ORACLE_PYTH_;
    }

    /// @notice Capture the current oracle state and emit an `OracleSnapshot` event for downstream analysis.
    function snapshot(bytes32 label, bytes calldata pythUpdateData) public returns (Snapshot memory snap) {
        return _snapshot(label, pythUpdateData);
    }

    /// @notice Convenience overload for callers that do not supply fresh Pyth update data.
    function snapshot(bytes32 label) external returns (Snapshot memory snap) {
        return _snapshot(label, bytes(""));
    }

    function _snapshot(bytes32 label, bytes memory pythUpdateData) internal returns (Snapshot memory snap) {
        IOracleAdapterHC.MidResult memory midRes = ORACLE_HC_.readMidAndAge();
        IOracleAdapterHC.BidAskResult memory bookRes = ORACLE_HC_.readBidAsk();

        uint256 spreadBps = bookRes.success ? bookRes.spreadBps : 0;

        IOracleAdapterPyth.PythResult memory pythRes = ORACLE_PYTH_.readPythUsdMid(pythUpdateData);
        (uint256 pythMid, uint256 pythAge,) = ORACLE_PYTH_.computePairMid(pythRes);

        uint256 effectiveMid = midRes.success ? midRes.mid : (pythRes.success ? pythMid : 0);
        uint256 effectiveAge = midRes.success ? midRes.ageSec : (pythRes.success ? pythAge : type(uint256).max);

        uint256 deltaBps = 0;
        if (midRes.success && pythRes.success && midRes.mid > 0 && pythMid > 0) {
            deltaBps = OracleUtils.computeDivergenceBps(midRes.mid, pythMid);
        }

        snap = Snapshot({
            mid: effectiveMid,
            ageSec: effectiveAge,
            spreadBps: spreadBps,
            pythMid: pythMid,
            deltaBps: deltaBps,
            hcSuccess: midRes.success,
            bookSuccess: bookRes.success,
            pythSuccess: pythRes.success
        });

        emit OracleSnapshot(
            label,
            snap.mid,
            snap.ageSec,
            snap.spreadBps,
            snap.pythMid,
            snap.deltaBps,
            snap.hcSuccess,
            snap.bookSuccess,
            snap.pythSuccess
        );
    }
}
