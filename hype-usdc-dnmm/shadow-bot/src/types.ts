export type ShadowBotMode = 'live' | 'fork' | 'mock';

export type ErrorReason =
  | 'OK'
  | 'PrecompileError'
  | 'PythError'
  | 'PreviewStale'
  | 'AOMQClamp'
  | 'FallbackMode'
  | 'ViewPathMismatch'
  | 'PoolError';
export const ERROR_REASONS: ErrorReason[] = [
  'OK',
  'PrecompileError',
  'PythError',
  'PreviewStale',
  'AOMQClamp',
  'FallbackMode',
  'ViewPathMismatch',
  'PoolError'
];

export type ProbeSide = 'base_in' | 'quote_in';
export type ProbeMode = 'exact_in' | 'exact_out';

export interface ShadowBotLabels {
  readonly pair: string;
  readonly chain: string;
  readonly baseSymbol: string;
  readonly quoteSymbol: string;
}

export interface HistogramBuckets {
  readonly deltaBps: number[];
  readonly confBps: number[];
  readonly bboSpreadBps: number[];
  readonly quoteLatencyMs: number[];
  readonly feeBps: number[];
  readonly totalBps: number[];
}

interface GuaranteedMinOutConfig {
  readonly calmBps: number;
  readonly fallbackBps: number;
  readonly clampMin: number;
  readonly clampMax: number;
}

interface SamplingConfig {
  readonly intervalLabel: string;
  readonly timeoutMs: number;
  readonly retryBackoffMs: number;
  readonly retryAttempts: number;
}

export interface ShadowBotPreviewConfig {
  readonly maxAgeSec: number;
  readonly snapshotCooldownSec: number;
  readonly revertOnStalePreview: boolean;
  readonly enablePreviewFresh: boolean;
}

export interface ShadowBotFeeConfig {
  readonly baseBps: number;
  readonly alphaConfNumerator: number;
  readonly alphaConfDenominator: number;
  readonly betaInvDevNumerator: number;
  readonly betaInvDevDenominator: number;
  readonly capBps: number;
  readonly decayPctPerBlock: number;
  readonly gammaSizeLinBps: number;
  readonly gammaSizeQuadBps: number;
  readonly sizeFeeCapBps: number;
  readonly kappaLvrBps: number;
}

export interface ShadowBotMakerConfig {
  readonly S0Notional: number;
  readonly ttlMs: number;
  readonly alphaBboBps: number;
  readonly betaFloorBps: number;
}

export interface ShadowBotInventoryConfig {
  readonly floorBps: number;
  readonly recenterThresholdPct: number;
  readonly initialTargetBaseXstar: string | 'auto';
  readonly invTiltBpsPer1pct: number;
  readonly invTiltMaxBps: number;
  readonly tiltConfWeightBps: number;
  readonly tiltSpreadWeightBps: number;
}

export interface ShadowBotFeatureFlagsConfig {
  readonly blendOn: boolean;
  readonly parityCiOn: boolean;
  readonly debugEmit: boolean;
  readonly enableSoftDivergence: boolean;
  readonly enableSizeFee: boolean;
  readonly enableBboFloor: boolean;
  readonly enableInvTilt: boolean;
  readonly enableAOMQ: boolean;
  readonly enableRebates: boolean;
  readonly enableAutoRecenter: boolean;
  readonly enableLvrFee: boolean;
}

export interface ShadowBotAomqConfig {
  readonly minQuoteNotional: number;
  readonly emergencySpreadBps: number;
  readonly floorEpsilonBps: number;
}

export interface ShadowBotRebateConfig {
  readonly allowlist: string[];
}

export interface ShadowBotOracleHyperCoreConfig {
  readonly confCapBpsSpot: number;
  readonly confCapBpsStrict: number;
  readonly maxAgeSec: number;
  readonly stallWindowSec: number;
  readonly allowEmaFallback: boolean;
  readonly divergenceBps: number;
  readonly divergenceAcceptBps: number;
  readonly divergenceSoftBps: number;
  readonly divergenceHardBps: number;
  readonly haircutMinBps: number;
  readonly haircutSlopeBps: number;
  readonly confWeightSpreadBps: number;
  readonly confWeightSigmaBps: number;
  readonly confWeightPythBps: number;
  readonly sigmaEwmaLambdaBps: number;
}

export interface ShadowBotOraclePythConfig {
  readonly maxAgeSec: number;
  readonly maxAgeSecStrict: number;
  readonly confCapBps: number;
}

export interface ShadowBotOracleConfig {
  readonly hypercore: ShadowBotOracleHyperCoreConfig;
  readonly pyth: ShadowBotOraclePythConfig;
}

export interface ShadowBotParameters {
  readonly enableLvrFee: boolean;
  readonly oracle: ShadowBotOracleConfig;
  readonly fee: ShadowBotFeeConfig;
  readonly inventory: ShadowBotInventoryConfig;
  readonly maker: ShadowBotMakerConfig;
  readonly preview: ShadowBotPreviewConfig;
  readonly featureFlags: ShadowBotFeatureFlagsConfig;
  readonly aomq: ShadowBotAomqConfig;
  readonly rebates: ShadowBotRebateConfig;
}

export interface BaseShadowBotConfig {
  readonly mode: ShadowBotMode;
  readonly labels: ShadowBotLabels;
  readonly sizeGrid: bigint[];
  readonly intervalMs: number;
  readonly snapshotMaxAgeSec: number;
  readonly histogramBuckets: HistogramBuckets;
  readonly promPort: number;
  readonly logLevel: 'info' | 'debug';
  readonly csvDirectory: string;
  readonly jsonSummaryPath: string;
  readonly sizesSource: string;
  readonly guaranteedMinOut: GuaranteedMinOutConfig;
  readonly sampling: SamplingConfig;
  readonly baseDecimals: number;
  readonly quoteDecimals: number;
  readonly parameters: ShadowBotParameters;
}

export interface ChainBackedConfig extends BaseShadowBotConfig {
  readonly mode: 'live' | 'fork';
  readonly rpcUrl: string;
  readonly wsUrl?: string;
  readonly chainId?: number;
  readonly poolAddress: string;
  readonly pythAddress?: string;
  readonly hcPxPrecompile: string;
  readonly hcBboPrecompile: string;
  readonly hcPxKey: number;
  readonly hcBboKey: number;
  readonly hcMarketType: 'spot' | 'perp';
  readonly hcSizeDecimals: number;
  readonly hcPxMultiplier: bigint;
  readonly baseTokenAddress: string;
  readonly quoteTokenAddress: string;
  readonly gasPriceGwei?: number;
  readonly nativeUsd?: number;
  readonly pythPriceId?: string;
  readonly addressBookSource?: string;
}

export interface MockShadowBotConfig extends BaseShadowBotConfig {
  readonly mode: 'mock';
  readonly scenarioName: string;
  readonly scenarioFile?: string;
}

export type ShadowBotConfig = ChainBackedConfig | MockShadowBotConfig;

export const isChainBackedConfig = (config: ShadowBotConfig): config is ChainBackedConfig =>
  config.mode === 'live' || config.mode === 'fork';

export interface HcOracleSample {
  readonly status: 'ok' | 'error';
  readonly reason: ErrorReason;
  readonly midWad?: bigint;
  readonly bidWad?: bigint;
  readonly askWad?: bigint;
  readonly spreadBps?: number;
  readonly ageSec?: number;
  readonly statusDetail?: string;
}

export interface PythOracleSample {
  readonly status: 'ok' | 'error';
  readonly reason: ErrorReason;
  readonly midWad?: bigint;
  readonly confBps?: number;
  readonly publishTimeSec?: number;
  readonly statusDetail?: string;
}

export interface OracleSnapshot {
  readonly hc: HcOracleSample;
  readonly pyth?: PythOracleSample;
  readonly observedAtMs: number;
}

export interface PoolTokens {
  readonly base: string;
  readonly quote: string;
  readonly baseDecimals: number;
  readonly quoteDecimals: number;
  readonly baseScale: bigint;
  readonly quoteScale: bigint;
}

export interface PoolConfig {
  readonly oracle: OracleConfigState;
  readonly inventory: InventoryConfigState;
  readonly fee: FeeConfigState;
  readonly maker: MakerConfigState;
  readonly featureFlags: FeatureFlagsState;
}

export interface PoolState {
  readonly baseReserves: bigint;
  readonly quoteReserves: bigint;
  readonly lastMidWad: bigint;
  readonly snapshotAgeSec?: number;
  readonly snapshotTimestamp?: number;
  readonly sigmaBps?: number;
}

export interface PreviewLadderRow {
  readonly sizeWad: bigint;
  readonly askFeeBps: number;
  readonly bidFeeBps: number;
  readonly askClamped: boolean;
  readonly bidClamped: boolean;
}

export interface PreviewLadderSnapshot {
  readonly rows: PreviewLadderRow[];
  readonly snapshotTimestamp: number;
  readonly snapshotMidWad: bigint;
}

export interface QuotePreviewResult {
  readonly amountOut: bigint;
  readonly midUsed: bigint;
  readonly feeBpsUsed: number;
  readonly partialFillAmountIn: bigint;
  readonly usedFallback: boolean;
  readonly reason: string;
}

export interface OracleConfigState {
  readonly maxAgeSec: number;
  readonly stallWindowSec: number;
  readonly confCapBpsSpot: number;
  readonly confCapBpsStrict: number;
  readonly divergenceBps: number;
  readonly allowEmaFallback: boolean;
  readonly confWeightSpreadBps: number;
  readonly confWeightSigmaBps: number;
  readonly confWeightPythBps: number;
  readonly sigmaEwmaLambdaBps: number;
  readonly divergenceAcceptBps: number;
  readonly divergenceSoftBps: number;
  readonly divergenceHardBps: number;
  readonly haircutMinBps: number;
  readonly haircutSlopeBps: number;
}

export interface InventoryConfigState {
  readonly targetBaseXstar: bigint;
  readonly floorBps: number;
  readonly recenterThresholdPct: number;
  readonly invTiltBpsPer1pct: number;
  readonly invTiltMaxBps: number;
  readonly tiltConfWeightBps: number;
  readonly tiltSpreadWeightBps: number;
}

export interface FeeConfigState {
  readonly baseBps: number;
  readonly alphaNumerator: number;
  readonly alphaDenominator: number;
  readonly betaInvDevNumerator: number;
  readonly betaInvDevDenominator: number;
  readonly capBps: number;
  readonly decayPctPerBlock: number;
  readonly gammaSizeLinBps: number;
  readonly gammaSizeQuadBps: number;
  readonly sizeFeeCapBps: number;
  readonly kappaLvrBps: number;
}

export interface MakerConfigState {
  readonly s0Notional: bigint;
  readonly ttlMs: number;
  readonly alphaBboBps: number;
  readonly betaFloorBps: number;
}

export interface FeatureFlagsState {
  readonly blendOn: boolean;
  readonly parityCiOn: boolean;
  readonly debugEmit: boolean;
  readonly enableSoftDivergence: boolean;
  readonly enableSizeFee: boolean;
  readonly enableBboFloor: boolean;
  readonly enableInvTilt: boolean;
  readonly enableAOMQ: boolean;
  readonly enableRebates: boolean;
  readonly enableAutoRecenter: boolean;
}

export const REGIME_BIT_VALUES = {
  AOMQ: 1 << 0,
  Fallback: 1 << 1,
  NearFloor: 1 << 2,
  SizeFee: 1 << 3,
  InvTilt: 1 << 4
} as const;

export type RegimeBitValue = (typeof REGIME_BIT_VALUES)[keyof typeof REGIME_BIT_VALUES];

export interface RegimeFlags {
  readonly bitmask: number;
  readonly asArray: RegimeFlag[];
}

export type RegimeFlag =
  | 'AOMQ'
  | 'Fallback'
  | 'NearFloor'
  | 'SizeFee'
  | 'InvTilt';

export interface ProbeQuote {
  readonly side: ProbeSide;
  readonly mode: ProbeMode;
  readonly sizeWad: bigint;
  readonly amountIn: bigint;
  readonly amountOut: bigint;
  readonly feeBps: number;
  readonly totalBps: number;
  readonly slippageBps: number;
  readonly minOutBps: number;
  readonly latencyMs: number;
  readonly clampFlags: string[];
  readonly riskBits: RegimeFlag[];
  readonly success: boolean;
  readonly status: ErrorReason;
  readonly usedFallback: boolean;
  readonly midReferenceWad?: bigint;
  readonly statusDetail?: string;
}

export interface CsvRowInput {
  readonly timestampMs: number;
  readonly probe: ProbeQuote;
  readonly midHc?: bigint;
  readonly midPyth?: bigint;
  readonly pythConfBps?: number;
  readonly bboSpreadBps?: number;
}

export interface PreviewSnapshotInfo {
  readonly timestamp: number;
  readonly ageSec: number;
  readonly midWad: bigint;
  readonly sigmaBps: number;
  readonly confBps: number;
  readonly divergenceBps: number;
}

export interface ProviderHealthSample {
  readonly success: boolean;
  readonly latencyMs: number;
  readonly method: string;
  readonly error?: Error;
}

export type ClampStatus = 'none' | 'aomq' | 'fallback' | 'size_fee';

export interface QuotePipelineResult {
  readonly feeBps: number;
  readonly totalBps: number;
  readonly slippageBps: number;
  readonly clampFlags: ClampStatus[];
  readonly reason: ErrorReason;
  readonly usedFallback: boolean;
  readonly riskFlags: RegimeFlag[];
}

export interface PoolClientAdapter {
  getTokens(force?: boolean): Promise<PoolTokens>;
  getConfig(force?: boolean): Promise<PoolConfig>;
  getState(): Promise<PoolState>;
  getPreviewLadder?(s0BaseWad: bigint): Promise<PreviewLadderSnapshot>;
  previewFees?(sizes: readonly bigint[]): Promise<{ ask: number[]; bid: number[] }>;
  quoteExactIn(amountIn: bigint, isBaseIn: boolean, oracleMode: number, oracleData: string): Promise<QuotePreviewResult>;
  computeRegimeFlags(params: {
    poolState: PoolState;
    config: PoolConfig;
    usedFallback: boolean;
    clampFlags: RegimeFlag[];
  }): RegimeFlags;
  computeGuaranteedMinOutBps(flags: RegimeFlags): number;
}

export interface AddressBookEntry {
  readonly chainId: number;
  readonly poolAddress: string;
  readonly pyth?: string;
  readonly hcPx?: string;
  readonly hcBbo?: string;
  readonly baseToken?: string;
  readonly quoteToken?: string;
  readonly baseDecimals?: number;
  readonly quoteDecimals?: number;
  readonly wsUrl?: string;
}

export interface AddressBookFile {
  readonly defaultChainId?: number;
  readonly deployments: Record<string, AddressBookEntry>;
}

export interface ChainClient {
  callContract(request: { to: string; data: string }, label: string): Promise<string>;
  request<T>(label: string, fn: () => Promise<T>): Promise<T>;
  getBlockNumber(label?: string): Promise<number>;
  getBlockTimestamp(label?: string): Promise<number>;
  getGasPrice(label?: string): Promise<bigint>;
  getRpcProvider(): import('ethers').JsonRpcProvider | undefined;
  getWebSocketProvider(): import('ethers').WebSocketProvider | undefined;
  on(event: 'close', handler: (code: number) => void): void;
  close(): Promise<void>;
}

export interface EventSubscription {
  readonly unsubscribe: () => void;
}

export interface RollingUptimeTracker {
  addSample(timestampMs: number, twoSided: boolean): void;
  getUptimePct(nowMs: number): number;
}

export interface QuotesCounterResult {
  readonly result: 'ok' | 'error' | 'fallback';
}

export type PoolSide = 'ask' | 'bid';

export interface SyntheticProbeInput {
  readonly mode: ProbeMode;
  readonly side: ProbeSide;
  readonly sizeWad: bigint;
}

export interface SyntheticProbeResult extends QuotePipelineResult {
  readonly amountIn: bigint;
  readonly amountOut: bigint;
  readonly latencyMs: number;
}

export interface LoopArtifacts {
  readonly oracle: OracleSnapshot;
  readonly poolState?: PoolState;
  readonly preview?: PreviewSnapshotInfo;
  readonly probes: ProbeQuote[];
  readonly timestampMs: number;
}

export interface OracleReaderAdapter {
  sample(): Promise<OracleSnapshot>;
}

// -----------------------------------------------------------------------------
// Multi-run benchmarking types
// -----------------------------------------------------------------------------

export type BenchmarkId = 'dnmm' | 'cpmm' | 'stableswap';

export const BENCHMARK_IDS: readonly BenchmarkId[] = ['dnmm', 'cpmm', 'stableswap'] as const;

export type FlowPatternId =
  | 'arb_constant'
  | 'toxic'
  | 'trend'
  | 'mean_revert'
  | 'benign_poisson'
  | 'mixed';

export type FlowSizeDistributionKind = 'lognormal' | 'pareto' | 'fixed';

interface FlowSizeDistributionBase {
  readonly kind: FlowSizeDistributionKind;
  readonly min: number;
  readonly max: number;
}

export interface FlowLognormalDistribution extends FlowSizeDistributionBase {
  readonly kind: 'lognormal';
  readonly mu: number;
  readonly sigma: number;
}

export interface FlowParetoDistribution extends FlowSizeDistributionBase {
  readonly kind: 'pareto';
  readonly mu: number;
  readonly sigma: number;
}

export interface FlowFixedDistribution extends FlowSizeDistributionBase {
  readonly kind: 'fixed';
}

export type FlowSizeDistribution =
  | FlowLognormalDistribution
  | FlowParetoDistribution
  | FlowFixedDistribution;

export interface FlowToxicityConfig {
  readonly oracleLeadMs: number;
  readonly edgeBpsMu: number;
  readonly edgeBpsSigma: number;
}

export interface FlowPatternConfig {
  readonly pattern: FlowPatternId;
  readonly seconds: number;
  readonly seed: number;
  readonly txnRatePerMin: number;
  readonly size: FlowSizeDistribution;
  readonly toxicity?: FlowToxicityConfig;
}

export interface LatencyProfile {
  readonly quoteToTxMs: number;
  readonly jitterMs: number;
}

export type RouterMinOutPolicy = 'preview' | 'preview_ladder' | 'fixed_margin';

export interface RouterConfig {
  readonly slippageBps: number;
  readonly ttlSec: number;
  readonly minOutPolicy: RouterMinOutPolicy;
}

export interface RunFeatureFlags {
  readonly enableSoftDivergence: boolean;
  readonly enableSizeFee: boolean;
  readonly enableBboFloor: boolean;
  readonly enableInvTilt: boolean;
  readonly enableAOMQ: boolean;
  readonly enableRebates: boolean;
  readonly enableLvrFee: boolean;
}

export interface RunMakerParams {
  readonly betaFloorBps: number;
  readonly alphaBboBps: number;
  readonly S0Notional: number;
  readonly ttlMs: number;
}

export interface RunInventoryParams {
  readonly invTiltBpsPer1pct: number;
  readonly invTiltMaxBps: number;
  readonly tiltConfWeightBps: number;
  readonly tiltSpreadWeightBps: number;
}

export interface RunAomqParams {
  readonly minQuoteNotional: number;
  readonly emergencySpreadBps: number;
  readonly floorEpsilonBps: number;
}

export interface RunFeeParams {
  readonly kappaLvrBps?: number;
}

export interface RunRebateParams {
  readonly allowlist: readonly string[];
  readonly bps: number;
}

export interface RunComparatorCpmmParams {
  readonly feeBps: number;
}

export interface RunComparatorStableSwapParams {
  readonly feeBps: number;
  readonly amplification: number;
}

export interface RunComparatorParams {
  readonly cpmm?: RunComparatorCpmmParams;
  readonly stableswap?: RunComparatorStableSwapParams;
}

export interface RunSettingDefinition {
  readonly id: string;
  readonly label: string;
  readonly sweepId?: string;
  readonly riskScenarioId?: string;
  readonly tradeFlowId?: string;
  readonly settingSweepIds?: readonly string[];
  readonly featureFlags: RunFeatureFlags;
  readonly makerParams: RunMakerParams;
  readonly inventoryParams: RunInventoryParams;
  readonly aomqParams: RunAomqParams;
  readonly flow: FlowPatternConfig;
  readonly latency: LatencyProfile;
  readonly router: RouterConfig;
  readonly fee?: RunFeeParams;
  readonly rebates?: RunRebateParams;
  readonly comparator?: RunComparatorParams;
}

export interface SettingsOracles {
  readonly hypercore?: string;
  readonly pyth?: string;
}

export interface SettingSweepDefinition {
  readonly id: string;
  readonly label?: string;
  readonly enableLvrFee?: boolean;
  readonly kappaLvrBps?: number;
  readonly enableAOMQ?: boolean;
  readonly enableRebates?: boolean;
  readonly maker?: Partial<RunMakerParams>;
  readonly comparator?: RunComparatorParams;
  readonly rebates?: Partial<RunRebateParams>;
}

export interface RiskScenarioDefinition {
  readonly id: string;
  readonly bboSpreadBps?: readonly [number, number];
  readonly sigmaBps?: readonly [number, number];
  readonly pythOutages?: { readonly bursts: number; readonly secsEach: number };
  readonly pythDropRate?: number;
  readonly durationMin?: number;
  readonly autopauseExpected?: boolean;
  readonly quoteLatencyMs?: number;
  readonly ttlExpiryRateTarget?: number;
  readonly bboSpreadBpsShift?: string;
}

export interface TradeFlowDefinition {
  readonly id: string;
  readonly sizeDist: string;
  readonly medianBase?: string;
  readonly heavyTail?: boolean;
  readonly modes?: readonly string[];
  readonly share?: Record<string, number>;
  readonly spikeSizes?: readonly string[];
  readonly intervalMin?: number;
  readonly sizeParams?: Record<string, unknown>;
  readonly pattern?: FlowPatternId;
}

export interface SettingsFileSchema {
  readonly version: string;
  readonly pair: string;
  readonly base?: string;
  readonly quote?: string;
  readonly baseSymbol?: string;
  readonly quoteSymbol?: string;
  readonly runs?: readonly RunSettingDefinition[];
  readonly settings?: readonly SettingSweepDefinition[];
  readonly riskScenarios?: readonly RiskScenarioDefinition[];
  readonly tradeFlows?: readonly TradeFlowDefinition[];
  readonly oracles?: SettingsOracles;
  readonly benchmarks?: readonly BenchmarkId[];
  readonly reports?: ReportsConfig;
}

export interface RunnerPaths {
  readonly runRoot: string;
  readonly tradesDir: string;
  readonly quotesDir: string;
  readonly scoreboardCsvPath: string;
  readonly scoreboardJsonPath: string;
  readonly scoreboardMarkdownPath: string;
  readonly analystSummaryPath: string;
  readonly checkpointPath: string;
}

export interface ChainRuntimeConfig {
  readonly mode: 'live' | 'fork';
  readonly rpcUrl: string;
  readonly wsUrl?: string;
  readonly chainId?: number;
  readonly poolAddress: string;
  readonly baseTokenAddress: string;
  readonly quoteTokenAddress: string;
  readonly baseDecimals: number;
  readonly quoteDecimals: number;
  readonly pythAddress?: string;
  readonly hcPxPrecompile: string;
  readonly hcBboPrecompile: string;
  readonly hcPxKey: number;
  readonly hcBboKey: number;
  readonly hcMarketType: 'spot' | 'perp';
  readonly hcSizeDecimals: number;
  readonly hcPxMultiplier: bigint;
  readonly pythPriceId?: string;
  readonly gasPriceGwei?: number;
  readonly nativeUsd?: number;
  readonly addressBookSource?: string;
}

export interface MockRuntimeConfig {
  readonly mode: 'mock';
}

export type RuntimeChainConfig = ChainRuntimeConfig | MockRuntimeConfig;

export interface MultiRunRuntimeConfig {
  readonly runId: string;
  readonly baseConfig: ShadowBotConfig;
  readonly chainConfig?: ChainBackedConfig;
  readonly mockConfig?: MockShadowBotConfig;
  readonly logLevel: 'info' | 'debug';
  readonly benchmarks: readonly BenchmarkId[];
  readonly maxParallel: number;
  readonly persistCsv: boolean;
  readonly promPort: number;
  readonly seedBase: number;
  readonly durationOverrideSec?: number;
  readonly checkpointMinutes: number;
  readonly pairLabels: ShadowBotLabels;
  readonly settings: SettingsFileSchema;
  readonly runs: readonly RunSettingDefinition[];
  readonly settingsConfig?: readonly SettingSweepDefinition[];
  readonly riskScenarios?: readonly RiskScenarioDefinition[];
  readonly tradeFlows?: readonly TradeFlowDefinition[];
  readonly paths: RunnerPaths;
  readonly runtime: RuntimeChainConfig;
  readonly addressBookPath?: string;
  readonly reports?: ReportsConfig;
}

export interface TradeIntent {
  readonly id: string;
  readonly timestampMs: number;
  readonly settingId: string;
  readonly pattern: FlowPatternId;
  readonly side: ProbeSide;
  readonly amountIn: number;
  readonly minOut?: number;
  readonly ttlMs: number;
  readonly slippageBps: number;
}

export interface BenchmarkTickContext {
  readonly timestampMs: number;
  readonly oracle: OracleSnapshot;
  readonly poolState: PoolState;
}

export interface QuoteCsvRecord {
  readonly tsIso: string;
  readonly settingId: string;
  readonly benchmark: BenchmarkId;
  readonly side: ProbeSide;
  readonly sizeBaseWad: string;
  readonly intentSizeBaseWad?: string;
  readonly feeBps: number;
  readonly feeLvrBps?: number;
  readonly rebateBps?: number;
  readonly floorBps?: number;
  readonly ttlMs?: number;
  readonly minOut?: string;
  readonly aomqFlags?: string;
  readonly mid: string;
  readonly spreadBps: number;
  readonly confBps?: number;
  readonly aomqActive: boolean;
}

export interface TradeCsvRecord {
  readonly tsIso: string;
  readonly settingId: string;
  readonly benchmark: BenchmarkId;
  readonly side: ProbeSide;
  readonly intentSize?: string;
  readonly appliedSize?: string;
  readonly isPartial?: boolean;
  readonly amountIn: string;
  readonly amountOut: string;
  readonly midUsed: string;
  readonly feeBpsUsed: number;
  readonly feeLvrBps?: number;
  readonly rebateBps?: number;
  readonly feePaid?: string;
  readonly feeLvrPaid?: string;
  readonly rebatePaid?: string;
  readonly floorBps?: number;
  readonly tiltBps?: number;
  readonly aomqClamped: boolean;
  readonly floorEnforced?: boolean;
  readonly aomqUsed?: boolean;
  readonly success?: boolean;
  readonly minOut?: string;
  readonly slippageBpsVsMid: number;
  readonly pnlQuote: number;
  readonly inventoryBase: string;
  readonly inventoryQuote: string;
}

export interface ScoreboardRow {
  readonly settingId: string;
  readonly benchmark: BenchmarkId;
  readonly trades: number;
  readonly pnlQuoteTotal: number;
  readonly pnlPerMmNotionalBps: number;
  readonly pnlPerRisk: number;
  readonly winRatePct: number;
  readonly routerWinRatePct: number;
  readonly avgFeeBps: number;
  readonly avgFeeAfterRebateBps: number;
  readonly avgSlippageBps: number;
  readonly twoSidedUptimePct: number;
  readonly rejectRatePct: number;
  readonly aomqClampsTotal: number;
  readonly aomqClampsRatePct: number;
  readonly lvrCaptureBps: number;
  readonly priceImprovementVsCpmmBps?: number;
  readonly previewStalenessRatioPct: number;
  readonly timeoutExpiryRatePct: number;
  readonly recenterCommitsTotal: number;
}

export interface ScoreboardAccumulatorSnapshot {
  readonly trades: number;
  readonly wins: number;
  readonly pnlTotal: number;
  readonly feeSum: number;
  readonly slippageSum: number;
  readonly rejects: number;
  readonly intents: number;
  readonly aomq: number;
  readonly recenter: number;
  readonly twoSidedSamples: number;
  readonly twoSidedSatisfied: number;
  readonly lvrBpsSum: number;
  readonly lvrCount: number;
  readonly effectiveFeeAfterRebateSum: number;
  readonly effectiveFeeCount: number;
  readonly previewStaleRejects: number;
  readonly timeoutRejects: number;
  readonly riskExposure: number;
  readonly sigmaSamples: number;
}

export interface IntentMatchSnapshot {
  readonly success: boolean;
  readonly price: number;
  readonly side: ProbeSide;
}

export interface ScoreboardAggregatorState {
  readonly buckets: Record<string, ScoreboardAccumulatorSnapshot>;
  readonly makerNotional: Record<string, number>;
  readonly intentComparisons: Record<string, Record<string, Record<BenchmarkId, IntentMatchSnapshot>>>;
}

export interface ReportsConfig {
  readonly analystSummaryMd?: AnalystSummaryConfig;
}

export interface AnalystSummaryConfig {
  readonly sections: readonly string[];
  readonly highlightRules?: readonly HighlightRule[];
}

export type HighlightRuleId =
  | 'pnl_per_risk_top'
  | 'preview_staleness_threshold'
  | 'uptime_floor';

export interface HighlightRule {
  readonly id: HighlightRuleId;
  readonly description: string;
  readonly params?: Record<string, number | string>;
}

export interface ScoreboardContext {
  readonly runId: string;
  readonly pair: string;
  readonly benchmarks: readonly BenchmarkId[];
}

export interface ScoreboardInputRow {
  readonly settingId: string;
  readonly benchmark: BenchmarkId;
  readonly executed: boolean;
  readonly pnlQuote: number;
  readonly feeBps: number;
  readonly slippageBps: number;
  readonly aomqClamped: boolean;
  readonly rejected: boolean;
  readonly twoSidedSnapshot: boolean;
}

export interface PrometheusLabelSet {
  readonly run_id: string;
  readonly setting_id: string;
  readonly benchmark: BenchmarkId;
  readonly pair: string;
}

export interface BenchmarkTradeResult {
  readonly intent: TradeIntent;
  readonly success: boolean;
  readonly amountIn: bigint;
  readonly amountOut: bigint;
  readonly midUsed: bigint;
  readonly feeBpsUsed: number;
  readonly feeLvrBps?: number;
  readonly rebateBps?: number;
  readonly feePaid?: bigint;
  readonly feeLvrPaid?: bigint;
  readonly rebatePaid?: bigint;
  readonly floorBps?: number;
  readonly tiltBps?: number;
  readonly aomqClamped: boolean;
  readonly floorEnforced?: boolean;
  readonly aomqUsed?: boolean;
  readonly minOut?: bigint;
  readonly slippageBpsVsMid: number;
  readonly pnlQuote: number;
  readonly inventoryBase: bigint;
  readonly inventoryQuote: bigint;
  readonly latencyMs: number;
  readonly rejectReason?: string;
  readonly isPartial?: boolean;
  readonly appliedAmountIn?: bigint;
  readonly timestampMs?: number;
  readonly intentBaseSizeWad?: bigint;
  readonly executedBaseSizeWad?: bigint;
  readonly sigmaBps?: number;
}

export interface BenchmarkQuoteSample {
  readonly timestampMs: number;
  readonly side: ProbeSide;
  readonly sizeBaseWad: bigint;
  readonly feeBps: number;
  readonly feeLvrBps?: number;
  readonly rebateBps?: number;
  readonly floorBps?: number;
  readonly ttlMs?: number;
  readonly latencyMs?: number;
  readonly minOut?: bigint;
  readonly aomqFlags?: string;
  readonly mid: bigint;
  readonly spreadBps: number;
  readonly confBps?: number;
  readonly aomqActive: boolean;
}

export interface BenchmarkAdapter {
  readonly id: BenchmarkId;
  init(): Promise<void>;
  prepareTick(context: BenchmarkTickContext): Promise<void>;
  sampleQuote(side: ProbeSide, sizeBaseWad: bigint): Promise<BenchmarkQuoteSample>;
  simulateTrade(intent: TradeIntent): Promise<BenchmarkTradeResult>;
  close(): Promise<void>;
}
