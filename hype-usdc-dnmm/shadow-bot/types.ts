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

export interface ShadowBotConfig {
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
  readonly baseDecimals: number;
  readonly quoteDecimals: number;
  readonly labels: ShadowBotLabels;
  readonly sizeGrid: bigint[];
  readonly intervalMs: number;
  readonly snapshotMaxAgeSec: number;
  readonly gasPriceGwei?: number;
  readonly nativeUsd?: number;
  readonly histogramBuckets: HistogramBuckets;
  readonly promPort: number;
  readonly logLevel: 'info' | 'debug';
  readonly csvDirectory: string;
  readonly jsonSummaryPath: string;
  readonly sizesSource: string;
  readonly guaranteedMinOut: {
    readonly calmBps: number;
    readonly fallbackBps: number;
    readonly clampMin: number;
    readonly clampMax: number;
  };
  readonly sampling: {
    readonly intervalLabel: string;
    readonly timeoutMs: number;
    readonly retryBackoffMs: number;
    readonly retryAttempts: number;
  };
  readonly pythPriceId?: string;
  readonly addressBookSource?: string;
}

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

export interface ProviderClients {
  readonly rpc: import('ethers').JsonRpcProvider;
  readonly ws?: import('ethers').WebSocketProvider;
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
