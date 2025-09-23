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
    uint256 private feeConfigPacked;
    MakerConfig public makerConfig;
    Guardians public guardians;

    IOracleAdapterHC internal immutable ORACLE_HC_;
    IOracleAdapterPyth internal immutable ORACLE_PYTH_;
    address internal immutable BASE_TOKEN_;
    address internal immutable QUOTE_TOKEN_;
    uint256 internal immutable BASE_SCALE_;
    uint256 internal immutable QUOTE_SCALE_;

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
    event TokenFeeUnsupported(address indexed user, bool isBaseIn, uint256 expectedAmountIn, uint256 receivedAmountIn);
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
        if (msg.sender != guardians.governance) revert Errors.NotGovernance();
        _;
    }

    modifier onlyPauser() {
        if (msg.sender != guardians.pauser && msg.sender != guardians.governance) revert Errors.NotPauser();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Errors.PoolPaused();
        _;
    }

    constructor(
        address baseToken_,
        address quoteToken_,
        uint8 baseDecimals_,
        uint8 quoteDecimals_,
        address oracleHc_,
        address oraclePyth_,
        InventoryConfig memory inventoryConfig_,
        OracleConfig memory oracleConfig_,
        FeePolicy.FeeConfig memory feeConfig_,
        MakerConfig memory makerConfig_,
        FeatureFlags memory featureFlags_,
        Guardians memory guardians_
    ) {
        if (baseToken_ == address(0) || quoteToken_ == address(0)) revert Errors.TokensZero();
        if (guardians_.governance == address(0)) revert Errors.GovernanceZero();
        if (inventoryConfig_.floorBps > 5000) revert Errors.InvalidConfig();
        if (feeConfig_.capBps < feeConfig_.baseBps) revert Errors.InvalidConfig();
        if (oracleConfig_.confCapBpsStrict > oracleConfig_.confCapBpsSpot) revert Errors.InvalidConfig();
        if (oracleConfig_.sigmaEwmaLambdaBps > BPS) revert Errors.InvalidConfig();

        uint256 baseScale = _pow10(baseDecimals_);
        uint256 quoteScale = _pow10(quoteDecimals_);
        tokenConfig = TokenConfig({
            baseToken: baseToken_,
            quoteToken: quoteToken_,
            baseDecimals: baseDecimals_,
            quoteDecimals: quoteDecimals_,
            baseScale: baseScale,
            quoteScale: quoteScale
        });

        ORACLE_HC_ = IOracleAdapterHC(oracleHc_);
        ORACLE_PYTH_ = IOracleAdapterPyth(oraclePyth_);
        BASE_TOKEN_ = baseToken_;
        QUOTE_TOKEN_ = quoteToken_;
        BASE_SCALE_ = baseScale;
        QUOTE_SCALE_ = quoteScale;
        inventoryConfig = inventoryConfig_;
        oracleConfig = oracleConfig_;
        feeConfigPacked = FeePolicy.pack(feeConfig_);
        makerConfig = makerConfig_;
        featureFlags = featureFlags_;
        guardians = guardians_;
    }

    function oracleHC() public view returns (IOracleAdapterHC) {
        return ORACLE_HC_;
    }

    function oraclePyth() public view returns (IOracleAdapterPyth) {
        return ORACLE_PYTH_;
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
        if (block.timestamp > deadline) revert Errors.DeadlineExpired();

        QuoteResult memory result = _quoteInternal(amountIn, isBaseIn, mode, oracleData, true);

        uint256 actualAmountIn = amountIn;
        bool isPartial = false;
        if (result.partialFillAmountIn > 0 && result.partialFillAmountIn < amountIn) {
            actualAmountIn = result.partialFillAmountIn;
            isPartial = true;
        }

        amountOut = result.amountOut;
        if (amountOut < minAmountOut) revert Errors.Slippage();

        address baseToken = BASE_TOKEN_;
        address quoteToken = QUOTE_TOKEN_;

        if (isBaseIn) {
            IERC20 baseTokenErc = IERC20(baseToken);
            uint256 beforeBal = baseTokenErc.balanceOf(address(this));
            baseToken.safeTransferFrom(msg.sender, address(this), actualAmountIn);
            uint256 received = baseTokenErc.balanceOf(address(this)) - beforeBal;
            if (received != actualAmountIn) {
                emit TokenFeeUnsupported(msg.sender, true, actualAmountIn, received);
                revert Errors.TokenFeeUnsupported();
            }
            quoteToken.safeTransfer(msg.sender, amountOut);
            if (uint256(reserves.baseReserves) + actualAmountIn > type(uint128).max) revert Errors.BaseOverflow();
            if (uint256(reserves.quoteReserves) < amountOut) revert Errors.InsufficientQuoteReserves();
            reserves.baseReserves = uint128(uint256(reserves.baseReserves) + actualAmountIn);
            reserves.quoteReserves = uint128(uint256(reserves.quoteReserves) - amountOut);
        } else {
            IERC20 quoteTokenErc = IERC20(quoteToken);
            uint256 beforeBal = quoteTokenErc.balanceOf(address(this));
            quoteToken.safeTransferFrom(msg.sender, address(this), actualAmountIn);
            uint256 received = quoteTokenErc.balanceOf(address(this)) - beforeBal;
            if (received != actualAmountIn) {
                emit TokenFeeUnsupported(msg.sender, false, actualAmountIn, received);
                revert Errors.TokenFeeUnsupported();
            }
            baseToken.safeTransfer(msg.sender, amountOut);
            if (uint256(reserves.quoteReserves) + actualAmountIn > type(uint128).max) revert Errors.QuoteOverflow();
            if (uint256(reserves.baseReserves) < amountOut) revert Errors.InsufficientBaseReserves();
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
        IOracleAdapterHC.MidResult memory midRes = ORACLE_HC_.readMidAndAge();
        if (!(midRes.success && midRes.ageSec <= cfg.maxAgeSec)) revert Errors.OracleStale();
        IOracleAdapterHC.BidAskResult memory baRes = ORACLE_HC_.readBidAsk();
        if (baRes.success && (baRes.bid == 0 || baRes.ask == 0 || baRes.ask <= baRes.bid)) {
            revert Errors.InvalidOrderbook();
        }

        FeatureFlags memory flags = featureFlags;
        uint256 confBps =
            _previewConfidenceView(cfg, flags, OracleMode.Spot, midRes.mid, baRes.spreadBps, baRes.success, false, 0, false);
        InventoryConfig memory invCfg = inventoryConfig;
        Inventory.Tokens memory invTokens = _inventoryTokens();
        uint256 invDev = Inventory.deviationBps(
            uint256(reserves.baseReserves),
            uint256(reserves.quoteReserves),
            invCfg.targetBaseXstar,
            midRes.mid,
            invTokens
        );
        FeePolicy.FeeState memory state =
            FeePolicy.FeeState({lastBlock: feeState.lastBlock, lastFeeBps: feeState.lastFeeBps});
        (uint16 feeBps,) = FeePolicy.previewPacked(state, feeConfigPacked, confBps, invDev, block.number);

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

    function feeConfig()
        public
        view
        returns (
            uint16 baseBps,
            uint16 alphaConfNumerator,
            uint16 alphaConfDenominator,
            uint16 betaInvDevNumerator,
            uint16 betaInvDevDenominator,
            uint16 capBps,
            uint16 decayPctPerBlock
        )
    {
        return FeePolicy.decode(feeConfigPacked);
    }

    // --- Governance ---

    function updateParams(ParamKind kind, bytes calldata data) external onlyGovernance {
        if (kind == ParamKind.Oracle) {
            OracleConfig memory oldCfg = oracleConfig;
            OracleConfig memory newCfg = abi.decode(data, (OracleConfig));
            if (newCfg.confCapBpsStrict > newCfg.confCapBpsSpot) revert Errors.InvalidConfig();
            oracleConfig = newCfg;
            emit ParamsUpdated("ORACLE", abi.encode(oldCfg), data);
        } else if (kind == ParamKind.Fee) {
            FeePolicy.FeeConfig memory oldCfg = FeePolicy.unpack(feeConfigPacked);
            FeePolicy.FeeConfig memory newCfg = abi.decode(data, (FeePolicy.FeeConfig));
            if (newCfg.capBps < newCfg.baseBps) revert Errors.InvalidConfig();
            feeConfigPacked = FeePolicy.pack(newCfg);
            emit ParamsUpdated("FEE", abi.encode(oldCfg), data);
        } else if (kind == ParamKind.Inventory) {
            InventoryConfig memory oldCfg = inventoryConfig;
            InventoryConfig memory newCfg = abi.decode(data, (InventoryConfig));
            if (newCfg.floorBps > 5000) revert Errors.InvalidConfig();
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
            revert Errors.InvalidParamKind();
        }
    }

    function setTargetBaseXstar(uint128 newTarget) external onlyGovernance {
        if (lastMid == 0) revert Errors.MidUnset();
        uint256 deviationBps = FixedPointMath.toBps(
            FixedPointMath.absDiff(uint256(newTarget), uint256(inventoryConfig.targetBaseXstar)),
            inventoryConfig.targetBaseXstar == 0 ? 1 : inventoryConfig.targetBaseXstar
        );
        if (deviationBps < inventoryConfig.recenterThresholdPct) revert Errors.RecenterThreshold();
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
        uint256 baseBal = IERC20(BASE_TOKEN_).balanceOf(address(this));
        uint256 quoteBal = IERC20(QUOTE_TOKEN_).balanceOf(address(this));
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
        if (amountIn == 0) revert Errors.ZeroAmount();
        if (block.timestamp < lastMidTimestamp) revert Errors.InvalidTimestamp();

        FeatureFlags memory flags = featureFlags;
        OracleConfig memory oracleCfg = oracleConfig;
        OracleOutcome memory outcome = _readOracle(mode, oracleData, flags, oracleCfg);

        InventoryConfig memory invCfg = inventoryConfig;
        Inventory.Tokens memory invTokens = _inventoryTokens();
        uint256 baseReservesLocal = uint256(reserves.baseReserves);
        uint256 quoteReservesLocal = uint256(reserves.quoteReserves);
        uint256 invDevBps = Inventory.deviationBps(
            baseReservesLocal, quoteReservesLocal, invCfg.targetBaseXstar, outcome.mid, invTokens
        );

        uint256 feeCfgPacked = feeConfigPacked;
        uint16 feeBps;
        if (shouldSettleFee) {
            feeBps = FeePolicy.settlePacked(feeState, feeCfgPacked, outcome.confBps, invDevBps);
        } else {
            FeePolicy.FeeState memory state =
                FeePolicy.FeeState({lastBlock: feeState.lastBlock, lastFeeBps: feeState.lastFeeBps});
            (feeBps,) = FeePolicy.previewPacked(state, feeCfgPacked, outcome.confBps, invDevBps, block.number);
        }

        if (flags.debugEmit) {
            FeePolicy.FeeConfig memory feeCfg = FeePolicy.unpack(feeCfgPacked);
            uint256 feeBaseComponent = feeCfg.baseBps;
            uint256 feeVolComponent = feeCfg.alphaConfDenominator == 0
                ? 0
                : FixedPointMath.mulDivDown(outcome.confBps, feeCfg.alphaConfNumerator, feeCfg.alphaConfDenominator);
            uint256 feeInvComponent = feeCfg.betaInvDevDenominator == 0
                ? 0
                : FixedPointMath.mulDivDown(invDevBps, feeCfg.betaInvDevNumerator, feeCfg.betaInvDevDenominator);

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
        (amountOut, appliedAmountIn, reason) = _computeSwapAmounts(
            amountIn,
            isBaseIn,
            outcome.mid,
            feeBps,
            invTokens,
            baseReservesLocal,
            quoteReservesLocal,
            invCfg.floorBps
        );

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
        uint256 feeBps,
        Inventory.Tokens memory invTokens,
        uint256 baseReservesLocal,
        uint256 quoteReservesLocal,
        uint16 floorBps
    ) internal pure returns (uint256 amountOut, uint256 appliedAmountIn, bytes32 reason) {
        if (feeBps >= BPS) revert Errors.FeeCapExceeded();

        bool didPartial;
        if (isBaseIn) {
            if (quoteReservesLocal == 0) revert Errors.FloorBreach();
            (amountOut, appliedAmountIn, didPartial) =
                Inventory.quoteBaseIn(amountIn, mid, feeBps, quoteReservesLocal, floorBps, invTokens);
        } else {
            if (baseReservesLocal == 0) revert Errors.FloorBreach();
            (amountOut, appliedAmountIn, didPartial) =
                Inventory.quoteQuoteIn(amountIn, mid, feeBps, baseReservesLocal, floorBps, invTokens);
        }

        if (appliedAmountIn > amountIn) {
            appliedAmountIn = amountIn;
        }
        reason = didPartial ? REASON_FLOOR : REASON_NONE;
    }

    function _inventoryTokens() internal view returns (Inventory.Tokens memory invTokens) {
        invTokens.baseScale = BASE_SCALE_;
        invTokens.quoteScale = QUOTE_SCALE_;
    }

    function _readOracle(
        OracleMode mode,
        bytes calldata oracleData,
        FeatureFlags memory flags,
        OracleConfig memory cfg
    )
        internal
        returns (OracleOutcome memory outcome)
    {
        IOracleAdapterHC.MidResult memory midRes;
        IOracleAdapterHC.BidAskResult memory baRes;

        try ORACLE_HC_.readMidAndAge() returns (IOracleAdapterHC.MidResult memory res) {
            midRes = res;
        } catch {
            midRes = IOracleAdapterHC.MidResult({mid: 0, ageSec: type(uint256).max, success: false});
        }

        try ORACLE_HC_.readBidAsk() returns (IOracleAdapterHC.BidAskResult memory res) {
            baRes = res;
        } catch {
            baRes = IOracleAdapterHC.BidAskResult({bid: 0, ask: 0, spreadBps: 0, success: false});
        }

        bool bookInvalid = baRes.success && (baRes.bid == 0 || baRes.ask == 0 || baRes.ask <= baRes.bid);
        if (bookInvalid) revert Errors.InvalidOrderbook();

        uint256 pythMid;
        uint256 pythAge;
        uint256 pythConf;
        bool pythFresh;

        if (address(ORACLE_PYTH_) != address(0)) {
            try ORACLE_PYTH_.readPythUsdMid(oracleData) returns (IOracleAdapterPyth.PythResult memory res) {
                if (res.success) {
                    (pythMid, pythAge, pythConf) = ORACLE_PYTH_.computePairMid(res);
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
            try ORACLE_HC_.readMidEmaFallback() returns (IOracleAdapterHC.MidResult memory res) {
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
            if (spreadRejected) revert Errors.OracleSpread();
            revert Errors.OracleStale();
        }

        (outcome.confBps, outcome.confSpreadBps, outcome.confSigmaBps, outcome.confPythBps, outcome.sigmaBps) =
            _computeConfidence(
                cfg,
                flags,
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
            if (divergenceBps > cfg.divergenceBps) revert Errors.OracleDivergence();
        }

        return outcome;
    }

    function _computeConfidence(
        OracleConfig memory cfg,
        FeatureFlags memory flags,
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

        if (!flags.blendOn) {
            uint256 primary = spreadAvailable ? spreadBps : 0;
            confBps = primary;
            if (fallbackConf > confBps) confBps = fallbackConf;
            if (cap > 0 && confBps > cap) confBps = cap;

            if (flags.debugEmit) {
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
        FeatureFlags memory flags,
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

        if (!flags.blendOn) {
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
