// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DnmPool} from "../DnmPool.sol";
import {IOracleAdapterHC} from "../interfaces/IOracleAdapterHC.sol";
import {IOracleAdapterPyth} from "../interfaces/IOracleAdapterPyth.sol";
import {OracleUtils} from "../lib/OracleUtils.sol";
import {ReentrancyGuard} from "../lib/ReentrancyGuard.sol";

interface IOraclePauseHandler {
    function onOracleCritical(bytes32 label) external;
}

/// @notice OracleWatcher mirrors the pool's oracle reads and emits alerts when thresholds are violated.
contract OracleWatcher is ReentrancyGuard {
    using OracleUtils for uint256;

    enum AlertKind {
        Age,
        Divergence,
        Fallback
    }

    struct Config {
        uint256 maxAgeCritical;
        uint256 divergenceCriticalBps;
    }

    struct CheckResult {
        uint256 hcMid;
        uint256 hcAgeSec;
        bool hcSuccess;
        uint256 spreadBps;
        uint256 pythMid;
        uint256 pythAgeSec;
        bool pythSuccess;
        uint256 divergenceBps;
        bool fallbackUsed;
    }

    error NotOwner();
    error InvalidThreshold();
    error PauseHandlerZero();
    error FeeResidual(uint256 leftoverWei);
    error OwnerZero();

    event OracleAlert(bytes32 indexed source, AlertKind kind, uint256 value, uint256 threshold, bool critical);
    event AutoPauseRequested(bytes32 indexed source, bool handlerCalled, bytes handlerData);
    event ConfigUpdated(Config previousConfig, Config newConfig);
    event PauseHandlerUpdated(address indexed previousHandler, address indexed newHandler);
    event AutoPauseToggled(bool enabled);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    DnmPool internal immutable POOL_;

    address public owner;
    Config public config;
    address public pauseHandler;
    bool public autoPauseEnabled;

    constructor(DnmPool pool_, Config memory config_, address pauseHandler_, bool autoPauseEnabled_) {
        POOL_ = pool_;
        owner = msg.sender;
        if (pauseHandler_ == address(0) && autoPauseEnabled_) revert PauseHandlerZero();
        pauseHandler = pauseHandler_;
        autoPauseEnabled = autoPauseEnabled_;

        _setConfig(_sanitizeConfig(config_));
    }

    /// @notice Mirror the oracle reads and emit alerts when thresholds are violated.
    /// @param label An opaque label forwarded to emitted events/handlers (e.g. bytes32("KEEPER"))
    /// @param oracleData Optional Pyth price-update payload (forwarded directly to the pool's adapter).
    function check(bytes32 label, bytes calldata oracleData)
        external
        payable
        nonReentrant
        returns (CheckResult memory result)
    {
        DnmPool.OracleConfig memory poolCfg = _pullOracleConfig();

        IOracleAdapterHC oracleHc = POOL_.oracleAdapterHC();
        IOracleAdapterHC.MidResult memory midRes = oracleHc.readMidAndAge();
        IOracleAdapterHC.BidAskResult memory bookRes = oracleHc.readBidAsk();

        IOracleAdapterPyth oraclePyth = POOL_.oracleAdapterPyth();
        IOracleAdapterPyth.PythResult memory pythRes;
        bool pythSuccess;
        try oraclePyth.readPythUsdMid{value: msg.value}(oracleData) returns (IOracleAdapterPyth.PythResult memory res) {
            pythRes = res;
            pythSuccess = res.success;
        } catch {
            pythSuccess = false;
        }

        uint256 pythMid;
        uint256 pythAgeSec;
        if (pythSuccess) {
            (pythMid, pythAgeSec,) = oraclePyth.computePairMid(pythRes);
        }

        uint256 observedAge = type(uint256).max;
        if (midRes.success && midRes.mid > 0) {
            observedAge = midRes.ageSec;
        } else if (pythSuccess) {
            observedAge = pythAgeSec;
        }

        uint256 divergenceBps;
        if (midRes.success && midRes.mid > 0 && pythSuccess && pythMid > 0) {
            divergenceBps = OracleUtils.computeDivergenceBps(midRes.mid, pythMid);
        }

        bool fallbackUsed = _detectFallback(poolCfg, midRes, bookRes);

        result = CheckResult({
            hcMid: midRes.mid,
            hcAgeSec: midRes.ageSec,
            hcSuccess: midRes.success,
            spreadBps: bookRes.spreadBps,
            pythMid: pythMid,
            pythAgeSec: pythAgeSec,
            pythSuccess: pythSuccess,
            divergenceBps: divergenceBps,
            fallbackUsed: fallbackUsed
        });

        Config memory cfg = config;

        if (observedAge > cfg.maxAgeCritical) {
            _emitAndHandle(label, AlertKind.Age, observedAge, cfg.maxAgeCritical, true);
        }

        if (divergenceBps > cfg.divergenceCriticalBps) {
            _emitAndHandle(label, AlertKind.Divergence, divergenceBps, cfg.divergenceCriticalBps, true);
        }

        if (fallbackUsed) {
            _emitAndHandle(label, AlertKind.Fallback, bookRes.spreadBps, poolCfg.confCapBpsSpot, false);
        }

        // Refund any leftover ETH from the Pyth adapter call back to the caller.
        uint256 balance = address(this).balance;
        if (balance > 0) revert FeeResidual(balance);
    }

    function setConfig(Config calldata newConfig) external onlyOwner {
        _setConfig(_sanitizeConfig(newConfig));
    }

    function setPauseHandler(address newHandler) external onlyOwner {
        if (newHandler == address(0) && autoPauseEnabled) revert PauseHandlerZero();
        emit PauseHandlerUpdated(pauseHandler, newHandler);
        pauseHandler = newHandler;
    }

    function setAutoPauseEnabled(bool enabled) external onlyOwner {
        if (enabled && pauseHandler == address(0)) revert PauseHandlerZero();
        autoPauseEnabled = enabled;
        emit AutoPauseToggled(enabled);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert OwnerZero();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    receive() external payable {}

    function _pullOracleConfig() internal view returns (DnmPool.OracleConfig memory cfg) {
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
        ) = POOL_.oracleConfig();
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
    }

    function pool() public view returns (DnmPool) {
        return POOL_;
    }

    function _emitAndHandle(bytes32 label, AlertKind kind, uint256 value, uint256 threshold, bool critical) internal {
        emit OracleAlert(label, kind, value, threshold, critical);

        if (autoPauseEnabled && critical) {
            bool handlerCalled;
            bytes memory handlerData;
            if (pauseHandler != address(0)) {
                try IOraclePauseHandler(pauseHandler).onOracleCritical(label) {
                    handlerCalled = true;
                } catch (bytes memory errData) {
                    handlerData = errData;
                }
            }
            emit AutoPauseRequested(label, handlerCalled, handlerData);
        }
    }

    function _setConfig(Config memory newConfig) internal {
        emit ConfigUpdated(config, newConfig);
        config = newConfig;
    }

    function _sanitizeConfig(Config memory cfg) internal view returns (Config memory) {
        DnmPool.OracleConfig memory poolCfg = _pullOracleConfig();
        if (cfg.maxAgeCritical == 0) {
            cfg.maxAgeCritical = poolCfg.maxAgeSec;
        }
        if (cfg.divergenceCriticalBps == 0) {
            cfg.divergenceCriticalBps = poolCfg.divergenceBps;
        }
        if (cfg.maxAgeCritical == 0 || cfg.divergenceCriticalBps == 0) {
            revert InvalidThreshold();
        }
        return cfg;
    }

    function _detectFallback(
        DnmPool.OracleConfig memory poolCfg,
        IOracleAdapterHC.MidResult memory midRes,
        IOracleAdapterHC.BidAskResult memory bookRes
    ) internal pure returns (bool) {
        bool midFresh = midRes.success && midRes.mid > 0 && midRes.ageSec <= poolCfg.maxAgeSec;
        bool spreadAcceptable = !bookRes.success || bookRes.spreadBps <= poolCfg.confCapBpsSpot;
        if (!midFresh) {
            return true;
        }
        if (bookRes.success && !spreadAcceptable) {
            return true;
        }
        return false;
    }
}
