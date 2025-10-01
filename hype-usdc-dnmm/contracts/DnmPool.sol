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
    uint256 private constant HC_AGE_UNKNOWN = type(uint256).max;
    uint8 private constant AUTO_RECENTER_HEALTHY_REQUIRED = 3;

    enum ParamKind {
        Oracle,
        Fee,
        Inventory,
        Maker,
        Feature,
        Aomq
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
        uint16 invTiltBpsPer1pct;
        uint16 invTiltMaxBps;
        uint16 tiltConfWeightBps;
        uint16 tiltSpreadWeightBps;
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
        uint16 divergenceAcceptBps;
        uint16 divergenceSoftBps;
        uint16 divergenceHardBps;
        uint16 haircutMinBps;
        uint16 haircutSlopeBps;
    }

    struct MakerConfig {
        uint128 s0Notional;
        uint32 ttlMs;
        uint16 alphaBboBps;
        uint16 betaFloorBps;
    }

    struct AomqConfig {
        uint128 minQuoteNotional;
        uint16 emergencySpreadBps;
        uint16 floorEpsilonBps;
    }

    struct GovernanceConfig {
        uint32 timelockDelaySec; // seconds; 0 == immediate
    }

    struct FeatureFlags {
        bool blendOn;
        bool parityCiOn;
        bool debugEmit;
        bool enableSoftDivergence;
        bool enableSizeFee;
        bool enableBboFloor;
        bool enableInvTilt;
        bool enableAOMQ;
        bool enableRebates;
        bool enableAutoRecenter;
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

    struct SoftDivergenceState {
        uint64 lastSampleAt;
        uint16 lastDeltaBps;
        uint8 healthyStreak;
        bool active;
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
        uint256 divergenceBps;
        uint16 divergenceHaircutBps;
        bool softDivergenceActive;
    }

    TokenConfig public tokenConfig;
    Reserves public reserves;
    InventoryConfig public inventoryConfig;
    OracleConfig public oracleConfig;
    uint256 private feeConfigPacked;
    MakerConfig public makerConfig;
    AomqConfig public aomqConfig;
    Guardians public guardians;
    GovernanceConfig private _governanceConfig;

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
    uint256 public lastRebalancePrice;
    uint64 public lastRebalanceAt;
    uint32 public recenterCooldownSec = 120;

    FeatureFlags public featureFlags;
    ConfidenceState private confidenceState;
    SoftDivergenceState private softDivergenceState;
    uint8 private autoRecenterHealthyFrames = AUTO_RECENTER_HEALTHY_REQUIRED;

    mapping(address => uint16) private _aggregatorDiscountBps;

    bytes32 private constant REASON_NONE = bytes32(0);
    bytes32 private constant REASON_FLOOR = bytes32("FLOOR");
    bytes32 private constant REASON_EMA = bytes32("EMA");
    bytes32 private constant REASON_PYTH = bytes32("PYTH");
    bytes32 private constant REASON_SPREAD = bytes32("SPREAD");
    bytes32 private constant REASON_HAIRCUT = bytes32("HAIRCUT");
    uint8 private constant SOFT_DIVERGENCE_RECOVERY_STREAK = 3;

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
    event ManualRebalanceExecuted(address indexed caller, uint256 price, uint64 timestamp);
    event RecenterCooldownSet(uint32 oldCooldown, uint32 newCooldown);
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

    event OracleDivergenceChecked(uint256 pythMid, uint256 hcMid, uint256 deltaBps, uint256 maxBps);
    event DivergenceHaircut(uint256 deltaBps, uint256 extraFeeBps);
    event DivergenceRejected(uint256 deltaBps);

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
        AomqConfig memory aomqConfig_,
        FeatureFlags memory featureFlags_,
        Guardians memory guardians_
    ) {
        if (baseToken_ == address(0) || quoteToken_ == address(0)) revert Errors.TokensZero();
        if (guardians_.governance == address(0)) revert Errors.GovernanceZero();
        if (inventoryConfig_.floorBps > 5000) revert Errors.InvalidConfig();
        if (inventoryConfig_.invTiltBpsPer1pct > BPS) revert Errors.InvalidConfig();
        if (inventoryConfig_.invTiltMaxBps > BPS) revert Errors.InvalidConfig();
        if (inventoryConfig_.tiltConfWeightBps > BPS) revert Errors.InvalidConfig();
        if (inventoryConfig_.tiltSpreadWeightBps > BPS) revert Errors.InvalidConfig();
        if (feeConfig_.capBps < feeConfig_.baseBps) revert Errors.InvalidConfig();
        if (oracleConfig_.confCapBpsStrict > oracleConfig_.confCapBpsSpot) revert Errors.InvalidConfig();
        if (makerConfig_.alphaBboBps > BPS) revert Errors.InvalidConfig();
        if (makerConfig_.betaFloorBps > BPS) revert Errors.InvalidConfig();
        if (aomqConfig_.emergencySpreadBps > BPS) revert Errors.InvalidConfig();
        if (aomqConfig_.floorEpsilonBps > BPS) revert Errors.InvalidConfig();
        if (oracleConfig_.sigmaEwmaLambdaBps > BPS) revert Errors.InvalidConfig();
        if (oracleConfig_.divergenceSoftBps != 0 && oracleConfig_.divergenceSoftBps < oracleConfig_.divergenceAcceptBps) {
            revert Errors.InvalidConfig();
        }
        uint16 ctorSoft = oracleConfig_.divergenceSoftBps != 0
            ? oracleConfig_.divergenceSoftBps
            : oracleConfig_.divergenceAcceptBps;
        if (oracleConfig_.divergenceHardBps != 0 && ctorSoft != 0 && oracleConfig_.divergenceHardBps < ctorSoft) {
            revert Errors.InvalidConfig();
        }
        uint256 ctorMaxDelta = 0;
        if (ctorSoft > oracleConfig_.divergenceAcceptBps) {
            ctorMaxDelta = ctorSoft - oracleConfig_.divergenceAcceptBps;
        }
        uint256 ctorMaxHaircut = uint256(oracleConfig_.haircutMinBps)
            + uint256(oracleConfig_.haircutSlopeBps) * ctorMaxDelta;
        if (ctorMaxHaircut >= BPS) revert Errors.InvalidConfig();

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
        aomqConfig = aomqConfig_;
        featureFlags = featureFlags_;
        guardians = guardians_;
        _governanceConfig = GovernanceConfig({timelockDelaySec: 0});
    }

    function oracleAdapterHC() public view returns (IOracleAdapterHC) {
        return ORACLE_HC_;
    }

    function oracleAdapterPyth() public view returns (IOracleAdapterPyth) {
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
        uint256 confBps = _previewConfidenceView(
            cfg, flags, OracleMode.Spot, midRes.mid, baRes.spreadBps, baRes.success, false, 0, false
        );
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
        FeePolicy.FeeState memory previewState;
        uint16 feeBps;
        (feeBps, previewState) = FeePolicy.previewPacked(state, feeConfigPacked, confBps, invDev, block.number);
        if (previewState.lastFeeBps != feeBps) revert Errors.FeePreviewInvariant();

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

    function governanceConfig() external view returns (GovernanceConfig memory) {
        return _governanceConfig;
    }

    function aggregatorDiscount(address executor) external view returns (uint16) {
        return _aggregatorDiscountBps[executor];
    }

    function getSoftDivergenceState()
        external
        view
        returns (bool active, uint16 lastDeltaBps, uint8 healthyStreak)
    {
        SoftDivergenceState memory state = softDivergenceState;
        return (state.active, state.lastDeltaBps, state.healthyStreak);
    }

    function baseTokenAddress() external view override returns (address) {
        return BASE_TOKEN_;
    }

    function quoteTokenAddress() external view override returns (address) {
        return QUOTE_TOKEN_;
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
            uint16 decayPctPerBlock,
            uint16 gammaSizeLinBps,
            uint16 gammaSizeQuadBps,
            uint16 sizeFeeCapBps
        )
    {
        (
            baseBps,
            alphaConfNumerator,
            alphaConfDenominator,
            betaInvDevNumerator,
            betaInvDevDenominator,
            capBps,
            decayPctPerBlock
        ) = FeePolicy.decode(feeConfigPacked);
        (gammaSizeLinBps, gammaSizeQuadBps, sizeFeeCapBps) = FeePolicy.decodeSizeFee(feeConfigPacked);
    }

    // --- Governance ---

    function updateParams(ParamKind kind, bytes calldata data) external onlyGovernance {
        if (kind == ParamKind.Oracle) {
            OracleConfig memory oldCfg = oracleConfig;
            OracleConfig memory newCfg = abi.decode(data, (OracleConfig));
            if (newCfg.confCapBpsStrict > newCfg.confCapBpsSpot) revert Errors.InvalidConfig();
            if (newCfg.divergenceSoftBps != 0 && newCfg.divergenceSoftBps < newCfg.divergenceAcceptBps) {
                revert Errors.InvalidConfig();
            }
            uint16 softRef = newCfg.divergenceSoftBps != 0 ? newCfg.divergenceSoftBps : newCfg.divergenceAcceptBps;
            if (newCfg.divergenceHardBps != 0 && softRef != 0 && newCfg.divergenceHardBps < softRef) {
                revert Errors.InvalidConfig();
            }
            uint256 maxDelta = 0;
            if (softRef > newCfg.divergenceAcceptBps) {
                maxDelta = softRef - newCfg.divergenceAcceptBps;
            }
            uint256 maxHaircut = uint256(newCfg.haircutMinBps) + uint256(newCfg.haircutSlopeBps) * maxDelta;
            if (maxHaircut >= BPS) revert Errors.InvalidConfig();
            oracleConfig = newCfg;
            emit ParamsUpdated("ORACLE", abi.encode(oldCfg), data);
        } else if (kind == ParamKind.Fee) {
            FeePolicy.FeeConfig memory oldCfg = FeePolicy.unpack(feeConfigPacked);
            FeePolicy.FeeConfig memory newCfg = abi.decode(data, (FeePolicy.FeeConfig));
            if (newCfg.capBps >= 10_000) revert FeePolicy.FeeCapTooHigh(newCfg.capBps); // AUDIT:ORFQ-002 enforce <100%
            if (newCfg.baseBps > newCfg.capBps) {
                revert FeePolicy.FeeBaseAboveCap(newCfg.baseBps, newCfg.capBps);
            }
            feeConfigPacked = FeePolicy.pack(newCfg);
            emit ParamsUpdated("FEE", abi.encode(oldCfg), data);
        } else if (kind == ParamKind.Inventory) {
            InventoryConfig memory oldCfg = inventoryConfig;
            InventoryConfig memory newCfg = abi.decode(data, (InventoryConfig));
            if (newCfg.floorBps > 5000) revert Errors.InvalidConfig();
            if (newCfg.invTiltBpsPer1pct > BPS) revert Errors.InvalidConfig();
            if (newCfg.invTiltMaxBps > BPS) revert Errors.InvalidConfig();
            if (newCfg.tiltConfWeightBps > BPS) revert Errors.InvalidConfig();
            if (newCfg.tiltSpreadWeightBps > BPS) revert Errors.InvalidConfig();
            inventoryConfig = newCfg;
            emit ParamsUpdated("INVENTORY", abi.encode(oldCfg), data);
        } else if (kind == ParamKind.Maker) {
            MakerConfig memory oldCfg = makerConfig;
            MakerConfig memory newCfg = abi.decode(data, (MakerConfig));
            if (newCfg.alphaBboBps > BPS) revert Errors.InvalidConfig();
            if (newCfg.betaFloorBps > BPS) revert Errors.InvalidConfig();
            makerConfig = newCfg;
            emit ParamsUpdated("MAKER", abi.encode(oldCfg), data);
        } else if (kind == ParamKind.Feature) {
            FeatureFlags memory oldFlags = featureFlags;
            FeatureFlags memory newFlags = abi.decode(data, (FeatureFlags));
            featureFlags = newFlags;
            if (!oldFlags.enableAutoRecenter && newFlags.enableAutoRecenter) {
                autoRecenterHealthyFrames = AUTO_RECENTER_HEALTHY_REQUIRED;
            }
            emit ParamsUpdated("FEATURE", abi.encode(oldFlags), data);
        } else if (kind == ParamKind.Aomq) {
            AomqConfig memory oldCfg = aomqConfig;
            AomqConfig memory newCfg = abi.decode(data, (AomqConfig));
            if (newCfg.emergencySpreadBps > BPS) revert Errors.InvalidConfig();
            if (newCfg.floorEpsilonBps > BPS) revert Errors.InvalidConfig();
            aomqConfig = newCfg;
            emit ParamsUpdated("AOMQ", abi.encode(oldCfg), data);
        } else {
            revert Errors.InvalidParamKind();
        }
    }

    function setTargetBaseXstar(uint128 newTarget) external onlyGovernance {
        uint256 freshMid = _getFreshSpotPrice();

        InventoryConfig storage invCfg = inventoryConfig;
        uint128 oldTarget = invCfg.targetBaseXstar;
        uint256 baseline = oldTarget == 0 ? 1 : oldTarget;
        uint256 deviationBps = FixedPointMath.toBps(
            FixedPointMath.absDiff(uint256(newTarget), uint256(oldTarget)),
            baseline
        );
        if (deviationBps < invCfg.recenterThresholdPct) revert Errors.RecenterThreshold();

        invCfg.targetBaseXstar = newTarget;
        lastRebalancePrice = freshMid;
        lastRebalanceAt = uint64(block.timestamp);

        emit TargetBaseXstarUpdated(oldTarget, newTarget, freshMid, uint64(block.timestamp));
    }

    function setRecenterCooldownSec(uint32 newCooldownSec) external onlyGovernance {
        uint32 oldCooldown = recenterCooldownSec;
        recenterCooldownSec = newCooldownSec;
        emit RecenterCooldownSet(oldCooldown, newCooldownSec);
    }

    /**
     * @dev Manual, permissionless trigger that mirrors the automatic rebalance path.
     * Reverts when price drift since the last rebalance does not exceed `recenterThresholdPct`.
     */
    function rebalanceTarget() external {
        uint256 currentPrice = _getFreshSpotPrice();
        if (!_cooldownElapsed()) revert Errors.RecenterCooldown();
        uint256 previousPrice = lastRebalancePrice;
        if (previousPrice == 0) {
            lastRebalancePrice = currentPrice;
            lastRebalanceAt = uint64(block.timestamp);
            autoRecenterHealthyFrames = AUTO_RECENTER_HEALTHY_REQUIRED;
            return;
        }

        uint16 thresholdBps = inventoryConfig.recenterThresholdPct;
        uint256 priceChange = FixedPointMath.absDiff(currentPrice, previousPrice);
        uint256 priceChangeBps = FixedPointMath.toBps(priceChange, previousPrice);
        if (priceChangeBps < thresholdBps) revert Errors.RecenterThreshold();

        bool updated = _performRebalance(currentPrice, thresholdBps);
        if (!updated) revert Errors.RecenterThreshold();

        autoRecenterHealthyFrames = 0;

        emit ManualRebalanceExecuted(msg.sender, currentPrice, uint64(block.timestamp));
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
        FeePolicy.FeeConfig memory feeCfg = FeePolicy.unpack(feeCfgPacked);
        MakerConfig memory makerCfg = makerConfig;
        uint16 feeBps;
        if (shouldSettleFee) {
            feeBps = FeePolicy.settlePacked(feeState, feeCfgPacked, outcome.confBps, invDevBps);
        } else {
            FeePolicy.FeeState memory state =
                FeePolicy.FeeState({lastBlock: feeState.lastBlock, lastFeeBps: feeState.lastFeeBps});
            FeePolicy.FeeState memory previewState;
            (feeBps, previewState) =
                FeePolicy.previewPacked(state, feeCfgPacked, outcome.confBps, invDevBps, block.number);
            if (previewState.lastFeeBps != feeBps) revert Errors.FeePreviewInvariant();
        }

        if (flags.enableSizeFee && feeCfg.sizeFeeCapBps > 0 && makerCfg.s0Notional > 0) {
            uint16 sizeFeeBps = _computeSizeFeeBps(amountIn, isBaseIn, outcome.mid, feeCfg, makerCfg.s0Notional);
            if (sizeFeeBps > 0) {
                uint256 updated = uint256(feeBps) + sizeFeeBps;
                if (updated > feeCfg.capBps) {
                    feeBps = feeCfg.capBps;
                } else {
                    feeBps = uint16(updated);
                }
            }
        }

        if (flags.enableInvTilt) {
            int256 tiltAdj = _computeInventoryTiltBps(
                isBaseIn,
                outcome.mid,
                outcome.spreadBps,
                outcome.confBps,
                inventoryConfig,
                invTokens,
                baseReservesLocal,
                quoteReservesLocal
            );
            if (tiltAdj != 0) {
                if (tiltAdj > 0) {
                    uint256 increased = uint256(feeBps) + uint256(tiltAdj);
                    feeBps = increased > feeCfg.capBps ? feeCfg.capBps : uint16(increased);
                } else {
                    uint256 decrease = uint256(-tiltAdj);
                    feeBps = decrease >= feeBps ? 0 : uint16(uint256(feeBps) - decrease);
                }
            }
        }

        if (outcome.divergenceHaircutBps > 0) {
            uint256 adjusted = uint256(feeBps) + outcome.divergenceHaircutBps;
            if (adjusted > feeCfg.capBps) {
                feeBps = feeCfg.capBps;
            } else {
                feeBps = uint16(adjusted);
            }
        }

        if (flags.enableBboFloor) {
            uint16 floorBps = _computeBboFloor(outcome.spreadBps, makerCfg);
            if (floorBps > feeCfg.capBps) {
                floorBps = feeCfg.capBps;
            }
            if (feeBps < floorBps) {
                feeBps = floorBps;
            }
        }

        if (flags.debugEmit) {
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
            amountIn, isBaseIn, outcome.mid, feeBps, invTokens, baseReservesLocal, quoteReservesLocal, invCfg.floorBps
        );

        result = QuoteResult({
            amountOut: amountOut,
            midUsed: outcome.mid,
            feeBpsUsed: feeBps,
            partialFillAmountIn: appliedAmountIn < amountIn ? appliedAmountIn : 0,
            usedFallback: outcome.usedFallback,
            reason: reason != REASON_NONE ? reason : outcome.reason
        });

        if (shouldSettleFee && flags.enableAutoRecenter) {
            _checkAndRebalanceAuto(outcome.mid);
        }
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

        reason = didPartial ? REASON_FLOOR : REASON_NONE;
    }

    function _computeSizeFeeBps(
        uint256 amountIn,
        bool isBaseIn,
        uint256 mid,
        FeePolicy.FeeConfig memory feeCfg,
        uint128 s0Notional
    ) internal view returns (uint16) {
        if (s0Notional == 0) return 0;

        uint256 tradeNotionalWad;
        if (isBaseIn) {
            uint256 amountBaseWad = FixedPointMath.mulDivDown(amountIn, ONE, BASE_SCALE_);
            if (amountBaseWad == 0 || mid == 0) return 0;
            tradeNotionalWad = FixedPointMath.mulDivDown(amountBaseWad, mid, ONE);
        } else {
            tradeNotionalWad = FixedPointMath.mulDivDown(amountIn, ONE, QUOTE_SCALE_);
        }

        if (tradeNotionalWad == 0) return 0;

        uint256 s0NotionalWad = uint256(s0Notional);
        if (s0NotionalWad == 0) return 0;

        uint256 u = FixedPointMath.mulDivDown(tradeNotionalWad, ONE, s0NotionalWad);
        if (u == 0) return 0;

        uint256 sizeFeeLin = feeCfg.gammaSizeLinBps == 0
            ? 0
            : FixedPointMath.mulDivDown(u, feeCfg.gammaSizeLinBps, ONE);
        uint256 sizeFeeQuad;
        if (feeCfg.gammaSizeQuadBps > 0) {
            uint256 uSquared = FixedPointMath.mulDivDown(u, u, ONE);
            sizeFeeQuad = FixedPointMath.mulDivDown(uSquared, feeCfg.gammaSizeQuadBps, ONE);
        }

        uint256 sizeFee = sizeFeeLin + sizeFeeQuad;
        if (sizeFee > feeCfg.sizeFeeCapBps) {
            sizeFee = feeCfg.sizeFeeCapBps;
        }
        if (sizeFee > type(uint16).max) {
            sizeFee = type(uint16).max;
        }
        return uint16(sizeFee);
    }

    function _computeBboFloor(uint256 spreadBps, MakerConfig memory makerCfg) internal pure returns (uint16) {
        uint16 betaFloor = makerCfg.betaFloorBps;
        uint16 alphaFloor = 0;

        if (makerCfg.alphaBboBps > 0 && spreadBps > 0) {
            uint256 scaled = FixedPointMath.mulDivDown(spreadBps, makerCfg.alphaBboBps, BPS);
            if (scaled > type(uint16).max) {
                alphaFloor = type(uint16).max;
            } else {
                alphaFloor = uint16(scaled);
            }
        }

        return alphaFloor > betaFloor ? alphaFloor : betaFloor;
    }

    function _computeInventoryTiltBps(
        bool isBaseIn,
        uint256 mid,
        uint256 spreadBps,
        uint256 confBps,
        InventoryConfig memory invCfg,
        Inventory.Tokens memory invTokens,
        uint256 baseReservesLocal,
        uint256 quoteReservesLocal
    ) internal pure returns (int256) {
        if (invCfg.invTiltBpsPer1pct == 0 || invCfg.invTiltMaxBps == 0) return 0;
        if (mid == 0) return 0;

        uint256 baseWad = FixedPointMath.mulDivDown(baseReservesLocal, ONE, invTokens.baseScale);
        uint256 quoteWad = FixedPointMath.mulDivDown(quoteReservesLocal, ONE, invTokens.quoteScale);
        if (baseWad == 0 && quoteWad == 0) return 0;

        uint256 baseNotionalWad = FixedPointMath.mulDivDown(baseWad, mid, ONE);
        uint256 numerator = quoteWad + baseNotionalWad;
        if (numerator == 0) return 0;

        uint256 denom = mid * 2;
        if (denom == 0) return 0;

        uint256 xStarWad = FixedPointMath.mulDivDown(numerator, ONE, denom);
        if (xStarWad == 0) return 0;

        int256 deltaSign;
        uint256 deltaWad;
        if (baseWad >= xStarWad) {
            deltaSign = 1;
            deltaWad = baseWad - xStarWad;
        } else {
            deltaSign = -1;
            deltaWad = xStarWad - baseWad;
        }
        if (deltaWad == 0) return 0;

        uint256 deltaBps = FixedPointMath.toBps(deltaWad, xStarWad);
        if (deltaBps == 0) return 0;

        uint256 tiltBase = FixedPointMath.mulDivDown(deltaBps, invCfg.invTiltBpsPer1pct, 100);
        if (tiltBase == 0) return 0;

        uint256 weightFactorBps = BPS;
        if (invCfg.tiltConfWeightBps > 0 && confBps > 0) {
            weightFactorBps += FixedPointMath.mulDivDown(confBps, invCfg.tiltConfWeightBps, BPS);
        }
        if (invCfg.tiltSpreadWeightBps > 0 && spreadBps > 0) {
            weightFactorBps += FixedPointMath.mulDivDown(spreadBps, invCfg.tiltSpreadWeightBps, BPS);
        }

        uint256 weightedTilt = FixedPointMath.mulDivDown(tiltBase, weightFactorBps, BPS);
        if (weightedTilt == 0) return 0;
        if (weightedTilt > invCfg.invTiltMaxBps) {
            weightedTilt = invCfg.invTiltMaxBps;
        }

        int256 signedTilt = deltaSign * int256(weightedTilt);
        if (!isBaseIn) {
            signedTilt = -signedTilt;
        }

        return signedTilt;
    }

    function _checkAndRebalanceAuto(uint256 currentPrice) internal {
        if (currentPrice == 0) return;

        uint256 previousPrice = lastRebalancePrice;
        if (previousPrice == 0) {
            lastRebalancePrice = currentPrice;
            autoRecenterHealthyFrames = AUTO_RECENTER_HEALTHY_REQUIRED;
            return;
        }

        uint16 thresholdBps = inventoryConfig.recenterThresholdPct;
        if (thresholdBps == 0) return;

        uint256 priceChange = FixedPointMath.absDiff(currentPrice, previousPrice);
        uint256 deviationBps = FixedPointMath.toBps(priceChange, previousPrice);

        if (deviationBps < thresholdBps) {
            if (autoRecenterHealthyFrames < AUTO_RECENTER_HEALTHY_REQUIRED) {
                unchecked {
                    autoRecenterHealthyFrames += 1;
                }
            }
            return;
        }

        if (!_cooldownElapsed()) return;
        if (autoRecenterHealthyFrames < AUTO_RECENTER_HEALTHY_REQUIRED) return;

        if (_performRebalance(currentPrice, thresholdBps)) {
            autoRecenterHealthyFrames = 0;
        }
    }

    function _performRebalance(uint256 currentPrice, uint16 thresholdBps) internal returns (bool updated) {
        if (currentPrice == 0) return false;

        TokenConfig memory tokenCfg = tokenConfig;
        uint256 baseReservesLocal = uint256(reserves.baseReserves);
        uint256 quoteReservesLocal = uint256(reserves.quoteReserves);

        uint256 baseReservesWad = FixedPointMath.mulDivDown(baseReservesLocal, ONE, tokenCfg.baseScale);
        uint256 quoteReservesWad = FixedPointMath.mulDivDown(quoteReservesLocal, ONE, tokenCfg.quoteScale);
        uint256 baseNotionalWad = FixedPointMath.mulDivDown(baseReservesWad, currentPrice, ONE);
        uint256 totalNotionalWad = quoteReservesWad + baseNotionalWad;

        uint256 targetValueWad = totalNotionalWad / 2;
        if (targetValueWad == 0) {
            lastRebalancePrice = currentPrice;
            return false;
        }

        uint256 newTargetWad = FixedPointMath.mulDivDown(targetValueWad, ONE, currentPrice);
        uint128 newTarget = uint128(FixedPointMath.mulDivDown(newTargetWad, tokenCfg.baseScale, ONE));

        InventoryConfig storage invCfg = inventoryConfig;
        uint256 currentTarget = invCfg.targetBaseXstar == 0 ? 1 : invCfg.targetBaseXstar;
        uint256 targetDeviation = FixedPointMath.absDiff(uint256(newTarget), currentTarget);
        if (FixedPointMath.toBps(targetDeviation, currentTarget) < thresholdBps) {
            lastRebalancePrice = currentPrice;
            return false;
        }

        uint128 oldTarget = invCfg.targetBaseXstar;
        invCfg.targetBaseXstar = newTarget;
        lastRebalancePrice = currentPrice;
        lastRebalanceAt = uint64(block.timestamp);

        emit TargetBaseXstarUpdated(oldTarget, newTarget, currentPrice, uint64(block.timestamp));
        return true;
    }

    function _inventoryTokens() internal view returns (Inventory.Tokens memory invTokens) {
        invTokens.baseScale = BASE_SCALE_;
        invTokens.quoteScale = QUOTE_SCALE_;
    }

    function _getFreshSpotPrice() internal view returns (uint256 mid) {
        IOracleAdapterHC.MidResult memory midRes = ORACLE_HC_.readMidAndAge();
        OracleConfig memory oracleCfg = oracleConfig;

        bool ageKnown = midRes.ageSec != HC_AGE_UNKNOWN;
        if (!(midRes.success && ageKnown && midRes.ageSec <= oracleCfg.maxAgeSec && midRes.mid > 0)) {
            revert Errors.OracleStale();
        }

        return midRes.mid;
    }

    function _cooldownElapsed() internal view returns (bool) {
        uint32 cooldown = recenterCooldownSec;
        if (cooldown == 0) return true;

        uint64 lastAt = lastRebalanceAt;
        if (lastAt == 0) return true;

        return block.timestamp >= uint256(lastAt) + cooldown;
    }

    function _readOracle(OracleMode mode, bytes calldata oracleData, FeatureFlags memory flags, OracleConfig memory cfg)
        internal
        returns (OracleOutcome memory outcome)
    {
        // AUDIT:HCABI-002 adapters now fail-closed; surface reverts instead of success flags
        IOracleAdapterHC.MidResult memory midRes = ORACLE_HC_.readMidAndAge();
        IOracleAdapterHC.BidAskResult memory baRes = ORACLE_HC_.readBidAsk();

        bool spreadAvailable = baRes.bid > 0 && baRes.ask > 0;
        if (spreadAvailable && baRes.ask <= baRes.bid) revert Errors.InvalidOrderbook();

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

        bool midAgeKnown = midRes.ageSec != HC_AGE_UNKNOWN;
        bool midFresh = midRes.mid > 0 && midAgeKnown && midRes.ageSec <= cfg.maxAgeSec;
        bool spreadAcceptable = baRes.spreadBps <= cfg.confCapBpsSpot;
        bool spreadRejected = midFresh && spreadAvailable && !spreadAcceptable;
        IOracleAdapterHC.MidResult memory emaRes;
        bool emaFresh;
        if (cfg.allowEmaFallback) {
            emaRes = ORACLE_HC_.readMidEmaFallback();
            bool emaAgeKnown = emaRes.ageSec != HC_AGE_UNKNOWN;
            emaFresh =
                emaRes.mid > 0 && emaAgeKnown && emaRes.ageSec <= cfg.maxAgeSec && emaRes.ageSec <= cfg.stallWindowSec;
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

        if (!outcome.usedFallback && pythFresh) {
            uint256 divergenceBps = OracleUtils.computeDivergenceBps(outcome.mid, pythMid);
            outcome.divergenceBps = divergenceBps;

            if (flags.enableSoftDivergence) {
                (uint16 acceptBps, uint16 softBps, uint16 hardBps) = _resolveDivergenceThresholds(cfg);
                if (flags.debugEmit && hardBps > 0) {
                    emit OracleDivergenceChecked(pythMid, outcome.mid, divergenceBps, hardBps);
                }
                uint16 haircutBps =
                    _processSoftDivergence(divergenceBps, acceptBps, softBps, hardBps, cfg.haircutMinBps, cfg.haircutSlopeBps);
                outcome.divergenceHaircutBps = haircutBps;
                outcome.softDivergenceActive = softDivergenceState.active;
                if (haircutBps > 0 && outcome.reason == REASON_NONE) {
                    outcome.reason = REASON_HAIRCUT;
                }
            } else if (cfg.divergenceBps > 0 && divergenceBps > cfg.divergenceBps) {
                if (flags.debugEmit) {
                    emit OracleDivergenceChecked(pythMid, outcome.mid, divergenceBps, cfg.divergenceBps);
                }
                revert Errors.OracleDiverged(divergenceBps, cfg.divergenceBps);
            }
        }

        return outcome;
    }

    function _resolveDivergenceThresholds(OracleConfig memory cfg)
        internal
        pure
        returns (uint16 acceptBps, uint16 softBps, uint16 hardBps)
    {
        acceptBps = cfg.divergenceAcceptBps;
        if (acceptBps == 0) acceptBps = cfg.divergenceBps;

        softBps = cfg.divergenceSoftBps;
        if (softBps == 0) softBps = cfg.divergenceBps;
        if (softBps < acceptBps) softBps = acceptBps;

        hardBps = cfg.divergenceHardBps;
        if (hardBps == 0) hardBps = cfg.divergenceBps;
        if (hardBps < softBps) hardBps = softBps;
    }

    function _processSoftDivergence(
        uint256 divergenceBps,
        uint16 acceptBps,
        uint16 softBps,
        uint16 hardBps,
        uint16 haircutMinBps,
        uint16 haircutSlopeBps
    ) internal returns (uint16 haircutBps) {
        SoftDivergenceState storage state = softDivergenceState;
        if (divergenceBps > type(uint16).max) {
            state.lastDeltaBps = type(uint16).max;
        } else {
            state.lastDeltaBps = uint16(divergenceBps);
        }
        state.lastSampleAt = uint64(block.timestamp);

        if (hardBps > 0 && divergenceBps > hardBps) {
            state.active = true;
            state.healthyStreak = 0;
            emit DivergenceRejected(divergenceBps);
            revert Errors.DivergenceHard(divergenceBps, hardBps);
        }

        if (acceptBps > 0 && divergenceBps > acceptBps) {
            state.active = true;
            state.healthyStreak = 0;

            uint256 deltaOverAccept = divergenceBps - acceptBps;
            if (softBps > acceptBps) {
                uint256 maxDelta = softBps - acceptBps;
                if (deltaOverAccept > maxDelta) {
                    deltaOverAccept = maxDelta;
                }
            } else {
                deltaOverAccept = 0;
            }

            uint256 haircut = haircutMinBps;
            if (haircutSlopeBps > 0 && deltaOverAccept > 0) {
                haircut += uint256(haircutSlopeBps) * deltaOverAccept;
            }
            if (haircut >= BPS) {
                haircut = BPS - 1;
            }
            if (haircut > type(uint16).max) {
                haircut = type(uint16).max;
            }

            emit DivergenceHaircut(divergenceBps, haircut);
            return uint16(haircut);
        }

        if (state.active) {
            if (state.healthyStreak < SOFT_DIVERGENCE_RECOVERY_STREAK) {
                state.healthyStreak += 1;
            }
            if (state.healthyStreak >= SOFT_DIVERGENCE_RECOVERY_STREAK) {
                state.active = false;
            }
        } else if (state.healthyStreak < SOFT_DIVERGENCE_RECOVERY_STREAK) {
            state.healthyStreak += 1;
        }

        return 0;
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

    function _previewSigma(OracleConfig memory cfg, uint256 mid, uint256 spreadSample)
        internal
        view
        returns (uint256)
    {
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
