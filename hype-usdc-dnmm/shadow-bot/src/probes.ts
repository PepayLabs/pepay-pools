import {
  ErrorReason,
  OracleSnapshot,
  PoolClientAdapter,
  PoolConfig,
  PoolState,
  ProbeQuote,
  ProbeSide,
  RegimeFlag
} from './types.js';

const ONE = 10n ** 18n;
const ORACLE_MODE_SPOT = 0;

interface ProbeContext {
  readonly poolClient: PoolClientAdapter;
  readonly poolState: PoolState;
  readonly poolConfig: PoolConfig;
  readonly oracle: OracleSnapshot;
  readonly sizeGrid: readonly bigint[];
}

export async function runSyntheticProbes(context: ProbeContext): Promise<ProbeQuote[]> {
  const { poolClient, poolState, poolConfig, oracle, sizeGrid } = context;
  const results: ProbeQuote[] = [];
  const midReference = selectMidReference(oracle, poolState);

  for (const size of sizeGrid) {
    for (const side of ['base_in', 'quote_in'] as ProbeSide[]) {
      const quote = await probeSingle({
        poolClient,
        poolState,
        poolConfig,
        oracle,
        size,
        side,
        midReference
      });
      results.push(quote);
    }
  }

  return results;
}

interface ProbeSingleInput {
  readonly poolClient: PoolClientAdapter;
  readonly poolState: PoolState;
  readonly poolConfig: PoolConfig;
  readonly oracle: OracleSnapshot;
  readonly size: bigint;
  readonly side: ProbeSide;
  readonly midReference: bigint;
}

async function probeSingle(input: ProbeSingleInput): Promise<ProbeQuote> {
  const { poolClient, poolState, poolConfig, oracle, size, side, midReference } = input;
  const started = Date.now();

  const isBaseIn = side === 'base_in';
  const amountIn = computeAmountIn(size, midReference, isBaseIn);

  if (amountIn === 0n) {
    const regime = poolClient.computeRegimeFlags({
      poolState,
      config: poolConfig,
      usedFallback: false,
      clampFlags: []
    });
    return {
      side,
      mode: 'exact_in',
      sizeWad: size,
      amountIn,
      amountOut: 0n,
      feeBps: 0,
      totalBps: 0,
      slippageBps: 0,
      minOutBps: poolClient.computeGuaranteedMinOutBps(regime),
      latencyMs: Date.now() - started,
      clampFlags: [],
      riskBits: regime.asArray,
      success: false,
      status: 'ViewPathMismatch',
      usedFallback: false,
      midReferenceWad: midReference,
      statusDetail: 'mid reference unavailable'
    };
  }

  try {
    const result = await poolClient.quoteExactIn(amountIn, isBaseIn, ORACLE_MODE_SPOT, '0x');
    const latencyMs = Date.now() - started;
    const decodedReason = decodeReason(result.reason);

    const clampFlags = deriveClampFlags(decodedReason, result.usedFallback);
    const regime = poolClient.computeRegimeFlags({
      poolState,
      config: poolConfig,
      usedFallback: result.usedFallback,
      clampFlags
    });
    const expectedOut = computeExpectedOut(amountIn, midReference, isBaseIn);
    const slippageBps = computeSlippageBps(expectedOut, result.amountOut);
    const totalBps = result.feeBpsUsed + slippageBps;

    return {
      side,
      mode: 'exact_in',
      sizeWad: size,
      amountIn,
      amountOut: result.amountOut,
      feeBps: result.feeBpsUsed,
      totalBps,
      slippageBps,
      minOutBps: poolClient.computeGuaranteedMinOutBps(regime),
      latencyMs,
      clampFlags,
      riskBits: regime.asArray,
      success: true,
      status: 'OK',
      usedFallback: result.usedFallback,
      midReferenceWad: midReference,
      statusDetail: decodedReason || undefined
    };
  } catch (error) {
    const latencyMs = Date.now() - started;
    const mapped = mapErrorReason(error);
    const regime = poolClient.computeRegimeFlags({
      poolState,
      config: poolConfig,
      usedFallback: mapped.reason === 'FallbackMode',
      clampFlags: []
    });

    return {
      side,
      mode: 'exact_in',
      sizeWad: size,
      amountIn,
      amountOut: 0n,
      feeBps: 0,
      totalBps: 0,
      slippageBps: 0,
      minOutBps: poolClient.computeGuaranteedMinOutBps(regime),
      latencyMs,
      clampFlags: [],
      riskBits: regime.asArray,
      success: false,
      status: mapped.reason,
      usedFallback: false,
      midReferenceWad: midReference,
      statusDetail: mapped.detail
    };
  }
}

function selectMidReference(oracle: OracleSnapshot, poolState: PoolState): bigint {
  if (oracle.hc.status === 'ok' && oracle.hc.midWad && oracle.hc.midWad > 0n) {
    return oracle.hc.midWad;
  }
  if (oracle.pyth && oracle.pyth.status === 'ok' && oracle.pyth.midWad && oracle.pyth.midWad > 0n) {
    return oracle.pyth.midWad;
  }
  return poolState.lastMidWad;
}

function computeAmountIn(size: bigint, midReference: bigint, isBaseIn: boolean): bigint {
  if (isBaseIn) return size;
  if (midReference === 0n) return 0n;
  return (size * midReference) / ONE;
}

function computeExpectedOut(amountIn: bigint, midReference: bigint, isBaseIn: boolean): bigint {
  if (midReference === 0n) return 0n;
  if (isBaseIn) {
    return (amountIn * midReference) / ONE;
  }
  return (amountIn * ONE) / midReference;
}

function computeSlippageBps(expected: bigint, actual: bigint): number {
  if (expected === 0n) return 0;
  const diff = expected > actual ? expected - actual : actual - expected;
  return Number((diff * 10_000n) / expected);
}

function decodeReason(reasonHex: string): string {
  if (!reasonHex || reasonHex === '0x' || reasonHex === '0x0') return '';
  try {
    const trimmed = reasonHex.startsWith('0x') ? reasonHex.slice(2) : reasonHex;
    const buffer = Buffer.from(trimmed, 'hex');
    return buffer.toString('utf8').replace(/\u0000+$/g, '');
  } catch (error) {
    return reasonHex;
  }
}

function deriveClampFlags(reason: string, usedFallback: boolean): RegimeFlag[] {
  const flags = new Set<RegimeFlag>();
  if (usedFallback || reason.toLowerCase().includes('fallback')) {
    flags.add('Fallback');
  }
  if (reason.toLowerCase().includes('aomq')) {
    flags.add('AOMQ');
  }
  return Array.from(flags);
}

function mapErrorReason(error: unknown): { reason: ErrorReason; detail: string } {
  const detail = error instanceof Error ? error.message : String(error);
  if (/PreviewSnapshotStale/i.test(detail)) {
    return { reason: 'PreviewStale', detail };
  }
  if (/AOMQ/i.test(detail)) {
    return { reason: 'AOMQClamp', detail };
  }
  if (/fallback/i.test(detail)) {
    return { reason: 'FallbackMode', detail };
  }
  if (/precompile/i.test(detail)) {
    return { reason: 'PrecompileError', detail };
  }
  return { reason: 'PoolError', detail };
}
