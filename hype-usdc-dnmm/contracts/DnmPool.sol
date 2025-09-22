// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "./interfaces/IDnmPool.sol";
import {IOracleAdapterHC} from "./interfaces/IOracleAdapterHC.sol";
import {IOracleAdapterPyth} from "./interfaces/IOracleAdapterPyth.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SafeTransferLib} from "./lib/SafeTransferLib.sol";
import {ReentrancyGuard} from "./lib/ReentrancyGuard.sol";
import {FixedPointMath} from "./lib/FixedPointMath.sol";
import {FeePolicy} from "./lib/FeePolicy.sol";
import {OracleUtils} from "./lib/OracleUtils.sol";
import {Errors} from "./lib/Errors.sol";
import {Inventory} from "./lib/Inventory.sol";

contract DnmPool is IDnmPool, ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 private constant ONE = 1e18;
    uint256 private constant BPS = 10_000;

    enum ParamKind {
        Oracle,
        Fee,
        Inventory,
        Maker,
        Feature
    }

    struct TokenConfig {
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
        uint16 confWeightSpreadBps;
        uint16 confWeightSigmaBps;
        uint16 confWeightPythBps;
        uint16 sigmaEwmaLambdaBps; // 0-10000 (1.0 -> 10000)
    }

    struct MakerConfig {
        uint128 s0Notional;
        uint32 ttlMs;
    }

    struct FeatureFlags {
        bool blendOn;
        bool parityCiOn;
        bool debugEmit;
    }

    struct Guardians {
        address governance;
        address pauser;
    }

    struct ConfidenceState {
        uint64 lastSigmaBlock;
        uint64 sigmaBps;
        uint128 lastObservedMid;
    }

    struct OracleOutcome {
        uint256 mid;
        uint256 confBps;
        uint256 spreadBps;
        uint256 ageSec;
        uint256 sigmaBps;
        uint256 confSpreadBps;
        uint256 confSigmaBps;
        uint256 confPythBps;
        bool usedFallback;
        bytes32 reason;
    }

    TokenConfig public tokenConfig;
    Reserves public reserves;
    InventoryConfig public inventoryConfig;
    OracleConfig public oracleConfig;
    FeePolicy.FeeConfig public feeConfig;
    MakerConfig public makerConfig;
    Guardians public guardians;

    IOracleAdapterHC public oracleHC;
    IOracleAdapterPyth public oraclePyth;

    FeePolicy.FeeState private feeState;
    bool public paused;

    uint256 public lastMid;
    uint64 public lastMidTimestamp;

    FeatureFlags public featureFlags;
    ConfidenceState private confidenceState;

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
        bool isPartial,
        bytes32 reason
    );

    event QuoteServed(uint256 bidPx, uint256 askPx, uint256 s0Notional, uint256 ttlMs, uint256 mid, uint256 feeBps);
    event ParamsUpdated(bytes32 indexed kind, bytes oldVal, bytes newVal);
    event Paused(address indexed caller);
    event Unpaused(address indexed caller);
    event TargetBaseXstarUpdated(uint128 oldTarget, uint128 newTarget, uint256 mid, uint64 timestamp);
    event ConfidenceDebug(
        uint256 confSpreadBps,
        uint256 confSigmaBps,
        uint256 confPythBps,
        uint256 confBlendedBps,
        uint256 sigmaBps,
        uint256 feeBaseBps,
        uint256 feeVolBps,
        uint256 feeInvBps,
        uint256 feeTotalBps
    );

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
        FeePolicy.FeeConfig memory feeConfig_,
        MakerConfig memory makerConfig_,
        FeatureFlags memory featureFlags_,
        Guardians memory guardians_
    ) {
        require(baseToken_ != address(0) && quoteToken_ != address(0), "TOKENS_ZERO");
        require(guardians_.governance != address(0), "GOV_ZERO");
        require(inventoryConfig_.floorBps <= 5000, Errors.INVALID_CONFIG);
        require(feeConfig_.capBps >= feeConfig_.baseBps, Errors.INVALID_CONFIG);
        require(oracleConfig_.confCapBpsStrict <= oracleConfig_.confCapBpsSpot, Errors.INVALID_CONFIG);
        require(oracleConfig_.sigmaEwmaLambdaBps <= BPS, Errors.INVALID_CONFIG);

        tokenConfig = TokenConfig({
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
        featureFlags = featureFlags_;
        guardians = guardians_;
    }

    // --- User actions ---

    function quoteSwapExactIn(uint256 amountIn, bool isBaseIn, OracleMode mode, bytes calldata oracleData)
        external
        returns (QuoteResult memory result)
    {
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
        bool isPartial = false;
        if (result.partialFillAmountIn > 0 && result.partialFillAmountIn < amountIn) {
            actualAmountIn = result.partialFillAmountIn;
            isPartial = true;
        }

        amountOut = result.amountOut;
        require(amountOut >= minAmountOut, "SLIPPAGE");

        if (isBaseIn) {
            uint256 beforeBal = IERC20(tokenConfig.baseToken).balanceOf(address(this));
            tokenConfig.baseToken.safeTransferFrom(msg.sender, address(this), actualAmountIn);
            uint256 received = IERC20(tokenConfig.baseToken).balanceOf(address(this)) - beforeBal;
            require(received == actualAmountIn, Errors.TOKEN_FEE_UNSUPPORTED);
            tokenConfig.quoteToken.safeTransfer(msg.sender, amountOut);
            require(uint256(reserves.baseReserves) + actualAmountIn <= type(uint128).max, "BASE_OOB");
            require(uint256(reserves.quoteReserves) >= amountOut, "INSUFFICIENT_QUOTE");
            reserves.baseReserves = uint128(uint256(reserves.baseReserves) + actualAmountIn);
            reserves.quoteReserves = uint128(uint256(reserves.quoteReserves) - amountOut);
        } else {
            uint256 beforeBal = IERC20(tokenConfig.quoteToken).balanceOf(address(this));
            tokenConfig.quoteToken.safeTransferFrom(msg.sender, address(this), actualAmountIn);
            uint256 received = IERC20(tokenConfig.quoteToken).balanceOf(address(this)) - beforeBal;
            require(received == actualAmountIn, Errors.TOKEN_FEE_UNSUPPORTED);
            tokenConfig.baseToken.safeTransfer(msg.sender, amountOut);
            require(uint256(reserves.quoteReserves) + actualAmountIn <= type(uint128).max, "QUOTE_OOB");
            require(uint256(reserves.baseReserves) >= amountOut, "INSUFFICIENT_BASE");
            reserves.quoteReserves = uint128(uint256(reserves.quoteReserves) + actualAmountIn);
            reserves.baseReserves = uint128(uint256(reserves.baseReserves) - amountOut);
        }

        lastMid = result.midUsed;
        lastMidTimestamp = uint64(block.timestamp);

        emit SwapExecuted(
            msg.sender, isBaseIn, actualAmountIn, amountOut, result.midUsed, result.feeBpsUsed, isPartial, result.reason
        );
    }

    function getTopOfBookQuote(uint256 s0Notional)
        external
        view
        override
        returns (uint256 bidPx, uint256 askPx, uint256 ttlMs, bytes32 quoteId)
    {
        OracleConfig memory cfg = oracleConfig;
        IOracleAdapterHC.MidResult memory midRes = oracleHC.readMidAndAge();
        require(midRes.success && midRes.ageSec <= cfg.maxAgeSec, Errors.ORACLE_STALE);
        IOracleAdapterHC.BidAskResult memory baRes = oracleHC.readBidAsk();
        require(!baRes.success || (baRes.bid > 0 && baRes.ask > baRes.bid), Errors.INVALID_OB);

        uint256 confBps =
            _previewConfidenceView(cfg, OracleMode.Spot, midRes.mid, baRes.spreadBps, baRes.success, false, 0, false);
        uint256 invDev = _computeInventoryDeviationBps(midRes.mid);
        FeePolicy.FeeState memory state =
            FeePolicy.FeeState({lastBlock: feeState.lastBlock, lastFeeBps: feeState.lastFeeBps});
        (uint16 feeBps,) = FeePolicy.preview(state, feeConfig, confBps, invDev, block.number);

        bidPx = FixedPointMath.mulDivDown(midRes.mid, BPS - feeBps, BPS);
        askPx = FixedPointMath.mulDivUp(midRes.mid, BPS + feeBps, BPS);
        ttlMs = makerConfig.ttlMs;
        quoteId = keccak256(abi.encodePacked(block.number, midRes.mid, feeBps, s0Notional));
    }

    function tokens()
        external
        view
        override
        returns (
            address baseToken,
            address quoteToken,
            uint8 baseDecimals,
            uint8 quoteDecimals,
            uint256 baseScale,
            uint256 quoteScale
        )
    {
        TokenConfig memory cfg = tokenConfig;
        return (cfg.baseToken, cfg.quoteToken, cfg.baseDecimals, cfg.quoteDecimals, cfg.baseScale, cfg.quoteScale);
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
            FeePolicy.FeeConfig memory oldCfg = feeConfig;
            FeePolicy.FeeConfig memory newCfg = abi.decode(data, (FeePolicy.FeeConfig));
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
        } else if (kind == ParamKind.Feature) {
            FeatureFlags memory oldFlags = featureFlags;
            FeatureFlags memory newFlags = abi.decode(data, (FeatureFlags));
            featureFlags = newFlags;
            emit ParamsUpdated("FEATURE", abi.encode(oldFlags), data);
        } else {
            revert("PARAM_KIND");
        }
    }

    function setTargetBaseXstar(uint128 newTarget) external onlyGovernance {
        require(lastMid > 0, "MID_UNSET");
        uint256 deviationBps = FixedPointMath.toBps(
            FixedPointMath.absDiff(uint256(newTarget), uint256(inventoryConfig.targetBaseXstar)),
            inventoryConfig.targetBaseXstar == 0 ? 1 : inventoryConfig.targetBaseXstar
        );
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
        uint256 baseBal = IERC20(tokenConfig.baseToken).balanceOf(address(this));
        uint256 quoteBal = IERC20(tokenConfig.quoteToken).balanceOf(address(this));
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
        require(block.timestamp >= lastMidTimestamp, Errors.INVALID_TS);

        OracleOutcome memory outcome = _readOracle(mode, oracleData);

        uint256 invDevBps = _computeInventoryDeviationBps(outcome.mid);
        FeePolicy.FeeConfig memory cfg = feeConfig;
        uint16 feeBps;
        if (shouldSettleFee) {
            feeBps = FeePolicy.settle(feeState, cfg, outcome.confBps, invDevBps);
        } else {
            FeePolicy.FeeState memory state =
                FeePolicy.FeeState({lastBlock: feeState.lastBlock, lastFeeBps: feeState.lastFeeBps});
            (feeBps,) = FeePolicy.preview(state, cfg, outcome.confBps, invDevBps, block.number);
        }

        if (featureFlags.debugEmit) {
            uint256 feeBaseComponent = cfg.baseBps;
            uint256 feeVolComponent = cfg.alphaConfDenominator == 0
                ? 0
                : FixedPointMath.mulDivDown(outcome.confBps, cfg.alphaConfNumerator, cfg.alphaConfDenominator);
            uint256 feeInvComponent = cfg.betaInvDevDenominator == 0
                ? 0
                : FixedPointMath.mulDivDown(invDevBps, cfg.betaInvDevNumerator, cfg.betaInvDevDenominator);

            emit ConfidenceDebug(
                outcome.confSpreadBps,
                outcome.confSigmaBps,
                outcome.confPythBps,
                outcome.confBps,
                outcome.sigmaBps,
                feeBaseComponent,
                feeVolComponent,
                feeInvComponent,
                feeBps
            );
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

    function _computeSwapAmounts(uint256 amountIn, bool isBaseIn, uint256 mid, uint256 feeBps)
        internal
        view
        returns (uint256 amountOut, uint256 appliedAmountIn, bytes32 reason)
    {
        require(feeBps < BPS, "FEE_CAP");
        Inventory.Tokens memory invTokens =
            Inventory.Tokens({baseScale: tokenConfig.baseScale, quoteScale: tokenConfig.quoteScale});

        bool didPartial;
        if (isBaseIn) {
            (amountOut, appliedAmountIn, didPartial) = Inventory.quoteBaseIn(
                amountIn, mid, feeBps, uint256(reserves.quoteReserves), inventoryConfig.floorBps, invTokens
            );
            if (appliedAmountIn > amountIn) {
                appliedAmountIn = amountIn;
            }
            reason = didPartial ? REASON_FLOOR : REASON_NONE;
        } else {
            (amountOut, appliedAmountIn, didPartial) = Inventory.quoteQuoteIn(
                amountIn, mid, feeBps, uint256(reserves.baseReserves), inventoryConfig.floorBps, invTokens
            );
            if (appliedAmountIn > amountIn) {
                appliedAmountIn = amountIn;
            }
            reason = didPartial ? REASON_FLOOR : REASON_NONE;
        }
    }

    function _computeInventoryDeviationBps(uint256 mid) internal view returns (uint256) {
        Inventory.Tokens memory invTokens =
            Inventory.Tokens({baseScale: tokenConfig.baseScale, quoteScale: tokenConfig.quoteScale});
        return Inventory.deviationBps(
            uint256(reserves.baseReserves),
            uint256(reserves.quoteReserves),
            inventoryConfig.targetBaseXstar,
            mid,
            invTokens
        );
    }

    function _readOracle(OracleMode mode, bytes calldata oracleData) internal returns (OracleOutcome memory outcome) {
        OracleConfig memory cfg = oracleConfig;
        IOracleAdapterHC.MidResult memory midRes;
        IOracleAdapterHC.BidAskResult memory baRes;

        try oracleHC.readMidAndAge() returns (IOracleAdapterHC.MidResult memory res) {
            midRes = res;
        } catch {
            midRes = IOracleAdapterHC.MidResult({mid: 0, ageSec: type(uint256).max, success: false});
        }

        try oracleHC.readBidAsk() returns (IOracleAdapterHC.BidAskResult memory res) {
            baRes = res;
        } catch {
            baRes = IOracleAdapterHC.BidAskResult({bid: 0, ask: 0, spreadBps: 0, success: false});
        }

        bool bookInvalid = baRes.success && (baRes.bid == 0 || baRes.ask == 0 || baRes.ask <= baRes.bid);
        require(!bookInvalid, Errors.INVALID_OB);

        uint256 pythMid;
        uint256 pythAge;
        uint256 pythConf;
        bool pythFresh;

        if (address(oraclePyth) != address(0)) {
            try oraclePyth.readPythUsdMid(oracleData) returns (IOracleAdapterPyth.PythResult memory res) {
                if (res.success) {
                    (pythMid, pythAge, pythConf) = oraclePyth.computePairMid(res);
                    pythFresh = pythMid > 0 && pythAge <= cfg.maxAgeSec;
                }
            } catch {
                // ignore precompile errors; handled via staleness/guards below
            }
        }

        bool midFresh = midRes.success && midRes.mid > 0 && midRes.ageSec <= cfg.maxAgeSec;
        bool spreadAvailable = baRes.success;
        bool spreadAcceptable = baRes.spreadBps <= cfg.confCapBpsSpot;
        bool spreadRejected = midFresh && spreadAvailable && !spreadAcceptable;
        IOracleAdapterHC.MidResult memory emaRes;
        bool emaFresh;
        if (cfg.allowEmaFallback) {
            try oracleHC.readMidEmaFallback() returns (IOracleAdapterHC.MidResult memory res) {
                emaRes = res;
            } catch {
                emaRes = IOracleAdapterHC.MidResult({mid: 0, ageSec: type(uint256).max, success: false});
            }
            emaFresh = emaRes.success && emaRes.mid > 0 && emaRes.ageSec <= cfg.maxAgeSec
                && emaRes.ageSec <= cfg.stallWindowSec;
        }

        if (midFresh && spreadAvailable && spreadAcceptable) {
            outcome.mid = midRes.mid;
            outcome.spreadBps = baRes.spreadBps;
            outcome.ageSec = midRes.ageSec;
            outcome.reason = REASON_NONE;
        } else if (emaFresh) {
            outcome.mid = emaRes.mid;
            outcome.spreadBps = spreadAvailable ? baRes.spreadBps : 0;
            outcome.ageSec = emaRes.ageSec;
            outcome.usedFallback = true;
            outcome.reason = REASON_EMA;
        }

        if (outcome.mid == 0 && pythFresh) {
            outcome.mid = pythMid;
            outcome.spreadBps = 0;
            outcome.ageSec = pythAge;
            outcome.usedFallback = true;
            outcome.reason = REASON_PYTH;
            spreadAvailable = false;
        } else {
            spreadAvailable = spreadAvailable && (outcome.reason != REASON_PYTH);
        }

        if (outcome.mid == 0) {
            if (spreadRejected) revert(Errors.ORACLE_SPREAD);
            revert(Errors.ORACLE_STALE);
        }

        (outcome.confBps, outcome.confSpreadBps, outcome.confSigmaBps, outcome.confPythBps, outcome.sigmaBps) =
            _computeConfidence(
                cfg,
                mode,
                outcome.mid,
                outcome.spreadBps,
                spreadAvailable,
                pythFresh,
                pythConf,
                outcome.reason == REASON_PYTH
            );

        if (!outcome.usedFallback && pythFresh && cfg.divergenceBps > 0) {
            uint256 divergenceBps = OracleUtils.computeDivergenceBps(outcome.mid, pythMid);
            require(divergenceBps <= cfg.divergenceBps, Errors.ORACLE_DIVERGENCE);
        }

        return outcome;
    }

    function _computeConfidence(
        OracleConfig memory cfg,
        OracleMode mode,
        uint256 mid,
        uint256 spreadBps,
        bool spreadAvailable,
        bool pythFresh,
        uint256 pythConf,
        bool pythUsed
    )
        internal
        returns (uint256 confBps, uint256 confSpreadBps, uint256 confSigmaBps, uint256 confPythBps, uint256 sigmaBps)
    {
        uint256 capSpot = cfg.confCapBpsSpot;
        uint256 capStrict = cfg.confCapBpsStrict;
        uint256 cap = mode == OracleMode.Strict ? capStrict : capSpot;
        if (pythUsed) {
            // Force strict cap discipline whenever the PYTH path contributes confidence.
            if (capStrict == 0) {
                cap = 0;
            } else if (cap == 0 || capStrict < cap) {
                cap = capStrict;
            }
        }
        uint256 fallbackConf = pythFresh && pythUsed ? pythConf : 0;

        if (!featureFlags.blendOn) {
            uint256 primary = spreadAvailable ? spreadBps : 0;
            confBps = primary;
            if (fallbackConf > confBps) confBps = fallbackConf;
            if (cap > 0 && confBps > cap) confBps = cap;

            if (featureFlags.debugEmit) {
                confSpreadBps = FixedPointMath.min(primary, cap);
                confSigmaBps = 0;
            }
            confPythBps = FixedPointMath.min(fallbackConf, cap);
            ConfidenceState storage state = confidenceState;
            state.lastObservedMid = uint128(mid);
            sigmaBps = state.sigmaBps;
            return (confBps, confSpreadBps, confSigmaBps, confPythBps, sigmaBps);
        }

        uint256 spreadSample = spreadAvailable && cap > 0 ? FixedPointMath.min(spreadBps, cap) : spreadBps;
        sigmaBps = _updateSigma(cfg, mid, spreadSample);

        uint256 cappedSpread = cap > 0 ? FixedPointMath.min(spreadSample, cap) : spreadSample;
        confSpreadBps = spreadAvailable ? FixedPointMath.mulDivDown(cappedSpread, cfg.confWeightSpreadBps, BPS) : 0;
        uint256 cappedSigma = cap > 0 ? FixedPointMath.min(sigmaBps, cap) : sigmaBps;
        confSigmaBps = cappedSigma > 0 ? FixedPointMath.mulDivDown(cappedSigma, cfg.confWeightSigmaBps, BPS) : 0;
        uint256 cappedPyth = cap > 0 ? FixedPointMath.min(fallbackConf, cap) : fallbackConf;
        confPythBps = cappedPyth > 0 ? FixedPointMath.mulDivDown(cappedPyth, cfg.confWeightPythBps, BPS) : 0;

        confBps = confSpreadBps;
        if (confSigmaBps > confBps) confBps = confSigmaBps;
        if (confPythBps > confBps) confBps = confPythBps;
        if (cap > 0 && confBps > cap) confBps = cap;

        return (confBps, confSpreadBps, confSigmaBps, confPythBps, sigmaBps);
    }

    function _updateSigma(OracleConfig memory cfg, uint256 mid, uint256 spreadSample) internal returns (uint256) {
        ConfidenceState storage state = confidenceState;
        ConfidenceState memory snapshot = ConfidenceState({
            lastSigmaBlock: state.lastSigmaBlock,
            sigmaBps: state.sigmaBps,
            lastObservedMid: state.lastObservedMid
        });

        (uint256 sigmaBps, uint64 nextBlock, uint128 nextObservedMid) =
            _forecastSigma(cfg, mid, spreadSample, snapshot, uint64(block.number));

        state.lastSigmaBlock = nextBlock;
        state.sigmaBps = uint64(sigmaBps);
        state.lastObservedMid = nextObservedMid;

        return sigmaBps;
    }

    function _previewSigma(OracleConfig memory cfg, uint256 mid, uint256 spreadSample) internal view returns (uint256) {
        ConfidenceState memory snapshot = ConfidenceState({
            lastSigmaBlock: confidenceState.lastSigmaBlock,
            sigmaBps: confidenceState.sigmaBps,
            lastObservedMid: confidenceState.lastObservedMid
        });

        (uint256 sigmaBps,,) = _forecastSigma(cfg, mid, spreadSample, snapshot, uint64(block.number));
        return sigmaBps;
    }

    function _forecastSigma(
        OracleConfig memory cfg,
        uint256 mid,
        uint256 spreadSample,
        ConfidenceState memory snapshot,
        uint64 currentBlock
    ) internal pure returns (uint256 sigmaBps, uint64 nextBlock, uint128 nextObservedMid) {
        nextObservedMid = uint128(mid);

        if (snapshot.lastSigmaBlock == currentBlock) {
            return (snapshot.sigmaBps, currentBlock, nextObservedMid);
        }

        uint256 cap = cfg.confCapBpsSpot;
        uint256 sample = spreadSample;

        if (snapshot.lastObservedMid > 0 && mid > 0) {
            uint256 priorMid = uint256(snapshot.lastObservedMid);
            uint256 deltaBps = FixedPointMath.toBps(FixedPointMath.absDiff(mid, priorMid), priorMid);
            if (cap > 0 && deltaBps > cap) {
                deltaBps = cap;
            }
            if (deltaBps > sample) {
                sample = deltaBps;
            }
        }

        uint256 lambda = cfg.sigmaEwmaLambdaBps;

        if (snapshot.lastSigmaBlock == 0) {
            sigmaBps = sample;
        } else if (lambda >= BPS) {
            sigmaBps = snapshot.sigmaBps;
        } else {
            sigmaBps = (uint256(snapshot.sigmaBps) * lambda + sample * (BPS - lambda)) / BPS;
        }

        if (cap > 0 && sigmaBps > cap) {
            sigmaBps = cap;
        }

        nextBlock = currentBlock;
    }

    function _previewConfidenceView(
        OracleConfig memory cfg,
        OracleMode mode,
        uint256 mid,
        uint256 spreadBps,
        bool spreadAvailable,
        bool pythFresh,
        uint256 pythConf,
        bool pythUsed
    ) internal view returns (uint256 confBps) {
        uint256 capSpot = cfg.confCapBpsSpot;
        uint256 capStrict = cfg.confCapBpsStrict;
        uint256 cap = mode == OracleMode.Strict ? capStrict : capSpot;
        if (pythUsed && pythFresh) {
            if (capStrict == 0) {
                cap = 0;
            } else if (cap == 0 || capStrict < cap) {
                cap = capStrict;
            }
        }
        uint256 fallbackConf = (pythFresh && pythUsed) ? pythConf : 0;

        if (!featureFlags.blendOn) {
            uint256 conf = spreadAvailable ? spreadBps : 0;
            if (fallbackConf > conf) conf = fallbackConf;
            if (cap > 0 && conf > cap) conf = cap;
            return conf;
        }

        uint256 spreadSample = spreadAvailable && cap > 0 ? FixedPointMath.min(spreadBps, cap) : spreadBps;
        uint256 sigmaPreview = _previewSigma(cfg, mid, spreadSample);
        uint256 cappedSigma = cap > 0 ? FixedPointMath.min(sigmaPreview, cap) : sigmaPreview;

        uint256 cappedSpread = cap > 0 ? FixedPointMath.min(spreadSample, cap) : spreadSample;
        uint256 confSpread = spreadAvailable ? FixedPointMath.mulDivDown(cappedSpread, cfg.confWeightSpreadBps, BPS) : 0;
        uint256 confSigma = cappedSigma > 0 ? FixedPointMath.mulDivDown(cappedSigma, cfg.confWeightSigmaBps, BPS) : 0;
        uint256 cappedPyth = cap > 0 ? FixedPointMath.min(fallbackConf, cap) : fallbackConf;
        uint256 confPyth = cappedPyth > 0 ? FixedPointMath.mulDivDown(cappedPyth, cfg.confWeightPythBps, BPS) : 0;

        confBps = confSpread;
        if (confSigma > confBps) confBps = confSigma;
        if (confPyth > confBps) confBps = confPyth;
        if (cap > 0 && confBps > cap) confBps = cap;
    }

    function _pow10(uint8 exp) private pure returns (uint256) {
        return 10 ** exp;
    }
}
