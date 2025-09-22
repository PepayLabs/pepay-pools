// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IOracleAdapterHC} from "../interfaces/IOracleAdapterHC.sol";
import {IOracleAdapterPyth} from "../interfaces/IOracleAdapterPyth.sol";
import {OracleUtils} from "../lib/OracleUtils.sol";

/// @notice Lightweight on-chain observer that mirrors the pool's oracle reads for shadow parity checks.
contract DnmOracleObserver {
    using OracleUtils for uint256;

    IOracleAdapterHC public immutable oracleHc;
    IOracleAdapterPyth public immutable oraclePyth;

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
        oracleHc = oracleHc_;
        oraclePyth = oraclePyth_;
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
        IOracleAdapterHC.MidResult memory midRes = oracleHc.readMidAndAge();
        IOracleAdapterHC.BidAskResult memory bookRes = oracleHc.readBidAsk();

        uint256 spreadBps = bookRes.success ? bookRes.spreadBps : 0;

        IOracleAdapterPyth.PythResult memory pythRes = oraclePyth.readPythUsdMid(pythUpdateData);
        (uint256 pythMid,,) = oraclePyth.computePairMid(pythRes);

        uint256 deltaBps = OracleUtils.computeDivergenceBps(midRes.mid, pythMid);

        snap = Snapshot({
            mid: midRes.mid,
            ageSec: midRes.ageSec,
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
