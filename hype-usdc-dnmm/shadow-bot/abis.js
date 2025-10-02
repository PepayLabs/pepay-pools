export const IDNM_POOL_ABI = [
    'event TargetBaseXstarUpdated(uint128 oldTarget, uint128 newTarget, uint256 mid, uint64 timestamp)',
    'event DivergenceHaircut(uint256 deltaBps, uint256 extraFeeBps)',
    'event AomqActivated(bytes32 trigger, bool isBaseIn, uint256 amountIn, uint256 quoteNotional, uint16 spreadBps)',
    'event PreviewSnapshotRefreshed(address indexed caller, uint64 timestamp, uint64 blockNumber, uint96 midWad, uint32 divergenceBps, uint8 flags)',
    'function tokens() view returns (address baseToken, address quoteToken, uint8 baseDecimals, uint8 quoteDecimals, uint256 baseScale, uint256 quoteScale)',
    'function featureFlags() view returns (bool blendOn, bool parityCiOn, bool debugEmit, bool enableSoftDivergence, bool enableSizeFee, bool enableBboFloor, bool enableInvTilt, bool enableAOMQ, bool enableRebates, bool enableAutoRecenter)',
    'function oracleConfig() view returns (uint32 maxAgeSec, uint32 stallWindowSec, uint16 confCapBpsSpot, uint16 confCapBpsStrict, uint16 divergenceBps, bool allowEmaFallback, uint16 confWeightSpreadBps, uint16 confWeightSigmaBps, uint16 confWeightPythBps, uint16 sigmaEwmaLambdaBps, uint16 divergenceAcceptBps, uint16 divergenceSoftBps, uint16 divergenceHardBps, uint16 haircutMinBps, uint16 haircutSlopeBps)',
    'function inventoryConfig() view returns (uint128 targetBaseXstar, uint16 floorBps, uint16 recenterThresholdPct, uint16 invTiltBpsPer1pct, uint16 invTiltMaxBps, uint16 tiltConfWeightBps, uint16 tiltSpreadWeightBps)',
    'function feeConfig() view returns (uint16 baseBps, uint16 alphaNumerator, uint16 alphaDenominator, uint16 betaInvDevNumerator, uint16 betaInvDevDenominator, uint16 capBps, uint16 decayPctPerBlock, uint16 gammaSizeLinBps, uint16 gammaSizeQuadBps, uint16 sizeFeeCapBps)',
    'function makerConfig() view returns (uint128 s0Notional, uint32 ttlMs, uint16 alphaBboBps, uint16 betaFloorBps)',
    'function reserves() view returns (uint256 baseReserves, uint256 quoteReserves)',
    'function lastMid() view returns (uint256)',
    'function previewSnapshotAge() view returns (uint256 ageSec, uint64 snapshotTimestamp)',
    'function previewConfig() view returns (uint32 maxAgeSec, uint32 snapshotCooldownSec, bool revertOnStalePreview, bool enablePreviewFresh)',
    'function previewLadder(uint256 s0BaseWad) view returns (uint256[] sizesBaseWad, uint256[] askFeeBps, uint256[] bidFeeBps, bool[] askClamped, bool[] bidClamped, uint64 snapshotTimestamp, uint96 snapshotMid)',
    'function previewFees(uint256[] sizesBaseWad) view returns (uint256[] askFeeBps, uint256[] bidFeeBps)',
    'function previewFeesFresh(uint8 mode, bytes oracleData, uint256[] sizesBaseWad) view returns (uint256[] askFeeBps, uint256[] bidFeeBps)',
    'function quoteSwapExactIn(uint256 amountIn, bool isBaseIn, uint8 mode, bytes oracleData) view returns (tuple(uint256 amountOut, uint256 midUsed, uint256 feeBpsUsed, uint256 partialFillAmountIn, bool usedFallback, bytes32 reason))',
    'function getSoftDivergenceState() view returns (bool active, uint16 lastDeltaBps, uint8 healthyStreak)'
];
export const PYTH_ABI = [
    'function getPriceUnsafe(bytes32 id) view returns (tuple(int64 price, uint64 conf, int32 expo, uint64 publishTime))'
];
export const QUOTE_RFQ_ABI = [
    'function quoteExactIn(address pool, uint256 amount, bool isBaseIn, bytes params) view returns (uint256 amountOut)',
    'function previewDiscount(address executor) view returns (uint16 discountBps)'
];
