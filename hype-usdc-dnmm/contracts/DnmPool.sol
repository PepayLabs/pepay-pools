// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "./interfaces/IDnmPool.sol";
import {IOracleAdapterHC} from "./interfaces/IOracleAdapterHC.sol";
import {IOracleAdapterPyth} from "./interfaces/IOracleAdapterPyth.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "./libraries/ReentrancyGuard.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {OracleUtils} from "./libraries/OracleUtils.sol";
import {Errors} from "./libraries/Errors.sol";

contract DnmPool is IDnmPool, ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 private constant ONE = 1e18;
    uint256 private constant BPS = 10_000;

    enum ParamKind {
        Oracle,
        Fee,
        Inventory,
        Maker
    }

    struct Tokens {
        address baseToken;
        address quoteToken;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        uint256 baseScale;
        uint256 quoteScale;
    }

    struct Reserves {
        uint128 baseReserves;
        uint128 quoteReserves;
    }

    struct InventoryConfig {
        uint128 targetBaseXstar;
        uint16 floorBps;
        uint16 recenterThresholdPct;
    }

    struct OracleConfig {
        uint32 maxAgeSec;
        uint32 stallWindowSec;
        uint16 confCapBpsSpot;
        uint16 confCapBpsStrict;
        uint16 divergenceBps;
        bool allowEmaFallback;
    }

    struct MakerConfig {
        uint128 s0Notional;
        uint32 ttlMs;
    }

    struct Guardians {
        address governance;
        address pauser;
    }

    struct OracleOutcome {
        uint256 mid;
        uint256 confBps;
        uint256 spreadBps;
        uint256 ageSec;
        uint256 fallbackMid;
        uint256 fallbackConfBps;
        bool usedFallback;
        bytes32 reason;
    }

    Tokens public tokens;
    Reserves public reserves;
    InventoryConfig public inventoryConfig;
    OracleConfig public oracleConfig;
    FeeMath.FeeConfig public feeConfig;
    MakerConfig public makerConfig;
    Guardians public guardians;

    IOracleAdapterHC public oracleHC;
    IOracleAdapterPyth public oraclePyth;

    FeeMath.FeeState private feeState;
    bool public paused;

    uint256 public lastMid;
    uint64 public lastMidTimestamp;

    bytes32 private constant REASON_NONE = bytes32(0);
    bytes32 private constant REASON_FLOOR = bytes32("FLOOR");
    bytes32 private constant REASON_EMA = bytes32("EMA");
    bytes32 private constant REASON_PYTH = bytes32("PYTH");
    bytes32 private constant REASON_SPREAD = bytes32("SPREAD");

    event SwapExecuted(
        address indexed user,
        bool isBaseIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 mid,
        uint256 feeBps,
        bool partial,
        bytes32 reason
    );

    event QuoteServed(uint256 bidPx, uint256 askPx, uint256 s0Notional, uint256 ttlMs, uint256 mid, uint256 feeBps);
    event ParamsUpdated(bytes32 indexed kind, bytes oldVal, bytes newVal);
    event Paused(address indexed caller);
    event Unpaused(address indexed caller);
    event TargetBaseXstarUpdated(uint128 oldTarget, uint128 newTarget, uint256 mid, uint64 timestamp);

    modifier onlyGovernance() {
        require(msg.sender == guardians.governance, Errors.NOT_GOVERNANCE);
        _;
    }

    modifier onlyPauser() {
        require(msg.sender == guardians.pauser || msg.sender == guardians.governance, Errors.NOT_PAUSER);
        _;
    }

    modifier whenNotPaused() {
        require(!paused, Errors.PAUSED);
        _;
    }

    constructor(
        address baseToken_,
        address quoteToken_,
        uint8 baseDecimals_,
        uint8 quoteDecimals_,
        address oracleHC_,
        address oraclePyth_,
        InventoryConfig memory inventoryConfig_,
        OracleConfig memory oracleConfig_,
        FeeMath.FeeConfig memory feeConfig_,
        MakerConfig memory makerConfig_,
        Guardians memory guardians_
    ) {
        require(baseToken_ != address(0) && quoteToken_ != address(0), "TOKENS_ZERO");
        require(guardians_.governance != address(0), "GOV_ZERO");
        require(inventoryConfig_.floorBps <= 5000, Errors.INVALID_CONFIG);
        require(feeConfig_.capBps >= feeConfig_.baseBps, Errors.INVALID_CONFIG);
        require(oracleConfig_.confCapBpsStrict <= oracleConfig_.confCapBpsSpot, Errors.INVALID_CONFIG);

        tokens = Tokens({
            baseToken: baseToken_,
            quoteToken: quoteToken_,
            baseDecimals: baseDecimals_,
            quoteDecimals: quoteDecimals_,
            baseScale: _pow10(baseDecimals_),
            quoteScale: _pow10(quoteDecimals_)
        });

        oracleHC = IOracleAdapterHC(oracleHC_);
        oraclePyth = IOracleAdapterPyth(oraclePyth_);
        inventoryConfig = inventoryConfig_;
        oracleConfig = oracleConfig_;
        feeConfig = feeConfig_;
        makerConfig = makerConfig_;
        guardians = guardians_;
    }

    // --- User actions ---

    function quoteSwapExactIn(
        uint256 amountIn,
        bool isBaseIn,
        OracleMode mode,
        bytes calldata oracleData
    ) external returns (QuoteResult memory result) {
        result = _quoteInternal(amountIn, isBaseIn, mode, oracleData, false);
    }

    function swapExactIn(
        uint256 amountIn,
        uint256 minAmountOut,
        bool isBaseIn,
        OracleMode mode,
        bytes calldata oracleData,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut) {
        require(block.timestamp <= deadline, Errors.DEADLINE_EXPIRED);

        QuoteResult memory result = _quoteInternal(amountIn, isBaseIn, mode, oracleData, true);

        uint256 actualAmountIn = amountIn;
        bool partial = false;
        if (result.partialFillAmountIn > 0 && result.partialFillAmountIn < amountIn) {
            actualAmountIn = result.partialFillAmountIn;
            partial = true;
        }

        amountOut = result.amountOut;
        require(amountOut >= minAmountOut, "SLIPPAGE");

        if (isBaseIn) {
            tokens.baseToken.safeTransferFrom(msg.sender, address(this), actualAmountIn);
            tokens.quoteToken.safeTransfer(msg.sender, amountOut);
            require(uint256(reserves.baseReserves) + actualAmountIn <= type(uint128).max, "BASE_OOB");
            require(uint256(reserves.quoteReserves) >= amountOut, "INSUFFICIENT_QUOTE");
            reserves.baseReserves = uint128(uint256(reserves.baseReserves) + actualAmountIn);
            reserves.quoteReserves = uint128(uint256(reserves.quoteReserves) - amountOut);
        } else {
            tokens.quoteToken.safeTransferFrom(msg.sender, address(this), actualAmountIn);
            tokens.baseToken.safeTransfer(msg.sender, amountOut);
            require(uint256(reserves.quoteReserves) + actualAmountIn <= type(uint128).max, "QUOTE_OOB");
            require(uint256(reserves.baseReserves) >= amountOut, "INSUFFICIENT_BASE");
            reserves.quoteReserves = uint128(uint256(reserves.quoteReserves) + actualAmountIn);
            reserves.baseReserves = uint128(uint256(reserves.baseReserves) - amountOut);
        }

        lastMid = result.midUsed;
        lastMidTimestamp = uint64(block.timestamp);

        emit SwapExecuted(
            msg.sender,
            isBaseIn,
            actualAmountIn,
            amountOut,
            result.midUsed,
            result.feeBpsUsed,
            partial,
            result.reason
        );
    }

    function getTopOfBookQuote(uint256 s0Notional)
        external
        view
        override
        returns (uint256 bidPx, uint256 askPx, uint256 ttlMs, bytes32 quoteId)
    {
        IOracleAdapterHC.MidResult memory midRes = oracleHC.readMidAndAge();
        require(midRes.success && midRes.ageSec <= oracleConfig.maxAgeSec, Errors.ORACLE_STALE);
        IOracleAdapterHC.BidAskResult memory baRes = oracleHC.readBidAsk();

        uint256 confBps = _capConfidence(baRes.spreadBps, 0, OracleMode.Spot);
        uint256 invDev = _computeInventoryDeviationBps(midRes.mid);
        FeeMath.FeeState memory state = feeState;
        (uint16 feeBps, ) = FeeMath.preview(state, feeConfig, confBps, invDev, block.number);

        bidPx = MathUtils.mulDivDown(midRes.mid, BPS - feeBps, BPS);
        askPx = MathUtils.mulDivUp(midRes.mid, BPS + feeBps, BPS);
        ttlMs = s0Notional > 0 ? makerConfig.ttlMs : makerConfig.ttlMs;
        quoteId = keccak256(abi.encodePacked(block.number, midRes.mid, feeBps, s0Notional));
    }

    // --- Governance ---

    function updateParams(ParamKind kind, bytes calldata data) external onlyGovernance {
        if (kind == ParamKind.Oracle) {
            OracleConfig memory oldCfg = oracleConfig;
            OracleConfig memory newCfg = abi.decode(data, (OracleConfig));
            require(newCfg.confCapBpsStrict <= newCfg.confCapBpsSpot, Errors.INVALID_CONFIG);
            oracleConfig = newCfg;
            emit ParamsUpdated("ORACLE", abi.encode(oldCfg), data);
        } else if (kind == ParamKind.Fee) {
            FeeMath.FeeConfig memory oldCfg = feeConfig;
            FeeMath.FeeConfig memory newCfg = abi.decode(data, (FeeMath.FeeConfig));
            require(newCfg.capBps >= newCfg.baseBps, Errors.INVALID_CONFIG);
            feeConfig = newCfg;
            emit ParamsUpdated("FEE", abi.encode(oldCfg), data);
        } else if (kind == ParamKind.Inventory) {
            InventoryConfig memory oldCfg = inventoryConfig;
            InventoryConfig memory newCfg = abi.decode(data, (InventoryConfig));
            require(newCfg.floorBps <= 5000, Errors.INVALID_CONFIG);
            inventoryConfig = newCfg;
            emit ParamsUpdated("INVENTORY", abi.encode(oldCfg), data);
        } else if (kind == ParamKind.Maker) {
            MakerConfig memory oldCfg = makerConfig;
            MakerConfig memory newCfg = abi.decode(data, (MakerConfig));
            makerConfig = newCfg;
            emit ParamsUpdated("MAKER", abi.encode(oldCfg), data);
        } else {
            revert("PARAM_KIND");
        }
    }

    function setTargetBaseXstar(uint128 newTarget) external onlyGovernance {
        require(lastMid > 0, "MID_UNSET");
        uint256 deviationBps = MathUtils.toBps(MathUtils.absDiff(uint256(newTarget), uint256(inventoryConfig.targetBaseXstar)), inventoryConfig.targetBaseXstar == 0 ? 1 : inventoryConfig.targetBaseXstar);
        require(deviationBps >= inventoryConfig.recenterThresholdPct, "THRESHOLD");
        uint128 oldTarget = inventoryConfig.targetBaseXstar;
        inventoryConfig.targetBaseXstar = newTarget;
        emit TargetBaseXstarUpdated(oldTarget, newTarget, lastMid, uint64(block.timestamp));
    }

    function pause() external onlyPauser {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyGovernance {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function sync() external {
        uint256 baseBal = IERC20(tokens.baseToken).balanceOf(address(this));
        uint256 quoteBal = IERC20(tokens.quoteToken).balanceOf(address(this));
        reserves.baseReserves = uint128(baseBal);
        reserves.quoteReserves = uint128(quoteBal);
    }

    // --- Internal helpers ---

    function _quoteInternal(
        uint256 amountIn,
        bool isBaseIn,
        OracleMode mode,
        bytes calldata oracleData,
        bool shouldSettleFee
    ) internal returns (QuoteResult memory result) {
        require(amountIn > 0, Errors.ZERO_AMOUNT);

        OracleOutcome memory outcome = _readOracle(mode, oracleData);

        uint256 invDevBps = _computeInventoryDeviationBps(outcome.mid);
        uint16 feeBps;
        if (shouldSettleFee) {
            feeBps = FeeMath.settle(feeState, feeConfig, outcome.confBps, invDevBps);
        } else {
            FeeMath.FeeState memory state = feeState;
            (feeBps, ) = FeeMath.preview(state, feeConfig, outcome.confBps, invDevBps, block.number);
        }

        uint256 amountOut;
        uint256 appliedAmountIn;
        bytes32 reason;
        (amountOut, appliedAmountIn, reason) = _computeSwapAmounts(amountIn, isBaseIn, outcome.mid, feeBps);

        result = QuoteResult({
            amountOut: amountOut,
            midUsed: outcome.mid,
            feeBpsUsed: feeBps,
            partialFillAmountIn: appliedAmountIn < amountIn ? appliedAmountIn : 0,
            usedFallback: outcome.usedFallback,
            reason: reason != REASON_NONE ? reason : outcome.reason
        });
    }

    function _computeSwapAmounts(
        uint256 amountIn,
        bool isBaseIn,
        uint256 mid,
        uint256 feeBps
    ) internal view returns (uint256 amountOut, uint256 appliedAmountIn, bytes32 reason) {
        require(feeBps < BPS, "FEE_CAP");
        if (isBaseIn) {
            uint256 amountInWad = MathUtils.mulDivDown(amountIn, ONE, tokens.baseScale);
            uint256 grossQuoteWad = MathUtils.mulDivDown(amountInWad, mid, ONE);
            uint256 feeWad = MathUtils.mulDivDown(grossQuoteWad, feeBps, BPS);
            uint256 netQuoteWad = grossQuoteWad - feeWad;
            amountOut = MathUtils.mulDivDown(netQuoteWad, tokens.quoteScale, ONE);

            uint256 floorQuote = MathUtils.mulDivDown(uint256(reserves.quoteReserves), inventoryConfig.floorBps, BPS);
            uint256 availableQuote = uint256(reserves.quoteReserves) > floorQuote ? uint256(reserves.quoteReserves) - floorQuote : 0;

            if (amountOut > availableQuote) {
                require(availableQuote > 0, Errors.FLOOR_BREACH);
                amountOut = availableQuote;
                uint256 netQuoteWadPartial = MathUtils.mulDivDown(amountOut, ONE, tokens.quoteScale);
                uint256 grossQuoteWadPartial = MathUtils.mulDivUp(netQuoteWadPartial, BPS, BPS - feeBps);
                uint256 amountInWadPartial = MathUtils.mulDivUp(grossQuoteWadPartial, ONE, mid);
                appliedAmountIn = MathUtils.mulDivUp(amountInWadPartial, tokens.baseScale, ONE);
                reason = REASON_FLOOR;
            } else {
                appliedAmountIn = amountIn;
                reason = REASON_NONE;
            }
        } else {
            uint256 amountInWad = MathUtils.mulDivDown(amountIn, ONE, tokens.quoteScale);
            uint256 grossBaseWad = MathUtils.mulDivDown(amountInWad, ONE, mid);
            uint256 feeWad = MathUtils.mulDivDown(grossBaseWad, feeBps, BPS);
            uint256 netBaseWad = grossBaseWad - feeWad;
            amountOut = MathUtils.mulDivDown(netBaseWad, tokens.baseScale, ONE);

            uint256 floorBase = MathUtils.mulDivDown(uint256(reserves.baseReserves), inventoryConfig.floorBps, BPS);
            uint256 availableBase = uint256(reserves.baseReserves) > floorBase ? uint256(reserves.baseReserves) - floorBase : 0;

            if (amountOut > availableBase) {
                require(availableBase > 0, Errors.FLOOR_BREACH);
                amountOut = availableBase;
                uint256 netBaseWadPartial = MathUtils.mulDivDown(amountOut, ONE, tokens.baseScale);
                uint256 grossBaseWadPartial = MathUtils.mulDivUp(netBaseWadPartial, BPS, BPS - feeBps);
                uint256 amountInWadPartial = MathUtils.mulDivUp(grossBaseWadPartial, mid, ONE);
                appliedAmountIn = MathUtils.mulDivUp(amountInWadPartial, tokens.quoteScale, ONE);
                reason = REASON_FLOOR;
            } else {
                appliedAmountIn = amountIn;
                reason = REASON_NONE;
            }
        }
    }

    function _computeInventoryDeviationBps(uint256 mid) internal view returns (uint256) {
        uint256 baseWad = MathUtils.mulDivDown(uint256(reserves.baseReserves), ONE, tokens.baseScale);
        uint256 quoteWad = MathUtils.mulDivDown(uint256(reserves.quoteReserves), ONE, tokens.quoteScale);
        uint256 targetWad = MathUtils.mulDivDown(uint256(inventoryConfig.targetBaseXstar), ONE, tokens.baseScale);
        uint256 baseNotionalWad = MathUtils.mulDivDown(baseWad, mid, ONE);
        uint256 totalNotionalWad = quoteWad + baseNotionalWad;
        if (totalNotionalWad == 0) return 0;
        uint256 deviation = MathUtils.absDiff(baseWad, targetWad);
        return MathUtils.toBps(deviation, totalNotionalWad);
    }

    function _readOracle(OracleMode mode, bytes calldata oracleData) internal returns (OracleOutcome memory outcome) {
        OracleConfig memory cfg = oracleConfig;
        IOracleAdapterHC.MidResult memory midRes = oracleHC.readMidAndAge();
        IOracleAdapterHC.BidAskResult memory baRes = oracleHC.readBidAsk();

        IOracleAdapterPyth.PythResult memory pythResult;
        uint256 pythMid;
        uint256 pythAge;
        uint256 pythConf;
        bool pythFresh;

        if (address(oraclePyth) != address(0)) {
            try oraclePyth.readPythUsdMid(oracleData) returns (IOracleAdapterPyth.PythResult memory res) {
                pythResult = res;
                if (res.success) {
                    (pythMid, pythAge, pythConf) = oraclePyth.computePairMid(res);
                    pythFresh = pythMid > 0 && pythAge <= cfg.maxAgeSec;
                }
            } catch {
                // ignore
            }
        }

        bool spotEligible = midRes.success && baRes.success && midRes.ageSec <= cfg.maxAgeSec;
        bool spreadAcceptable = baRes.spreadBps <= cfg.confCapBpsSpot;

        if (spotEligible && spreadAcceptable) {
            outcome.mid = midRes.mid;
            outcome.confBps = _capConfidence(baRes.spreadBps, pythFresh ? pythConf : 0, mode);
            outcome.spreadBps = baRes.spreadBps;
            outcome.ageSec = midRes.ageSec;
            outcome.reason = REASON_NONE;
        } else if (spotEligible && cfg.allowEmaFallback) {
            IOracleAdapterHC.MidResult memory emaRes = oracleHC.readMidEmaFallback();
            bool emaFresh = emaRes.success && emaRes.ageSec <= cfg.maxAgeSec && emaRes.ageSec <= cfg.stallWindowSec;
            if (emaFresh) {
                outcome.mid = emaRes.mid;
                outcome.confBps = _capConfidence(baRes.success ? baRes.spreadBps : 0, pythFresh ? pythConf : 0, mode);
                outcome.spreadBps = baRes.success ? baRes.spreadBps : 0;
                outcome.ageSec = emaRes.ageSec;
                outcome.usedFallback = true;
                outcome.reason = REASON_EMA;
            }
        }

        if (outcome.mid == 0 && pythFresh) {
            outcome.mid = pythMid;
            outcome.confBps = _capConfidence(pythConf, pythConf, mode);
            outcome.spreadBps = 0;
            outcome.ageSec = pythAge;
            outcome.usedFallback = true;
            outcome.reason = REASON_PYTH;
        }

        require(outcome.mid > 0, Errors.ORACLE_STALE);

        if (!outcome.usedFallback && pythFresh && cfg.divergenceBps > 0) {
            uint256 divergenceBps = OracleUtils.computeDivergenceBps(outcome.mid, pythMid);
            require(divergenceBps <= cfg.divergenceBps, Errors.ORACLE_DIVERGENCE);
        }

        return outcome;
    }

    function _capConfidence(
        uint256 primary,
        uint256 fallbackConf,
        OracleMode mode
    ) internal view returns (uint256) {
        uint256 conf = primary;
        if (fallbackConf > conf) conf = fallbackConf;
        uint256 cap = mode == OracleMode.Strict ? oracleConfig.confCapBpsStrict : oracleConfig.confCapBpsSpot;
        if (cap > 0 && conf > cap) conf = cap;
        return conf;
    }

    function _pow10(uint8 exp) private pure returns (uint256) {
        return 10 ** exp;
    }
}
