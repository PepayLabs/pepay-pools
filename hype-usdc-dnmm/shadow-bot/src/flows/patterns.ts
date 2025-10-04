import {
  FlowPatternConfig,
  FlowPatternId,
  FlowSizeDistribution,
  FlowToxicityConfig,
  TradeIntent
} from '../types.js';
import { createRng } from '../utils/random.js';

const TICK_MS = 250;

export interface FlowEngineOptions {
  readonly settingId: string;
  readonly durationMs: number;
  readonly routerTtlMs: number;
  readonly routerSlippageBps: number;
  readonly startTimestampMs: number;
}

interface FlowEngineState {
  readonly startMs: number;
  tickIndex: number;
  trendSign: number;
  lastPattern?: FlowPatternId;
}

export interface FlowEngine {
  readonly pattern: FlowPatternId;
  readonly durationMs: number;
  next(timestampMs: number): TradeIntent[];
  isComplete(timestampMs: number): boolean;
}

export function createFlowEngine(config: FlowPatternConfig, options: FlowEngineOptions): FlowEngine {
  const rng = createRng(config.seed);
  const state: FlowEngineState = {
    startMs: options.startTimestampMs,
    tickIndex: 0,
    trendSign: rng() > 0.5 ? 1 : -1
  };

  const baseSampler = buildSizeSampler(config.size, rng);
  const poissonLambda = config.txnRatePerMin / (60_000 / TICK_MS);

  function next(timestampMs: number): TradeIntent[] {
    const intents: TradeIntent[] = [];
    const tradesThisTick = samplePoisson(Math.max(poissonLambda, 0), rng);
    const currentPattern = pickActivePattern(config.pattern, state, rng);

    for (let i = 0; i < tradesThisTick; i += 1) {
      const amount = clampAmount(baseSampler());
      const side = pickSide(currentPattern, state, config.toxicity, rng);
      const intent: TradeIntent = {
        id: `${options.settingId}-${currentPattern}-${state.tickIndex}-${i}`,
        timestampMs,
        settingId: options.settingId,
        pattern: currentPattern,
        side,
        amountIn: amount,
        minOut: undefined,
        ttlMs: options.routerTtlMs,
        slippageBps: options.routerSlippageBps
      };
      intents.push(intent);
    }

    state.tickIndex += 1;
    return intents;
  }

  function isComplete(timestampMs: number): boolean {
    return timestampMs - state.startMs >= options.durationMs;
  }

  return {
    pattern: config.pattern,
    durationMs: options.durationMs,
    next,
    isComplete
  };

  function clampAmount(amount: number): number {
    const { min, max } = config.size;
    if (Number.isNaN(amount) || !Number.isFinite(amount)) {
      return min;
    }
    return Math.max(min, Math.min(max, amount));
  }
}

export function defaultTickMs(): number {
  return TICK_MS;
}

function buildSizeSampler(distribution: FlowSizeDistribution, rng: () => number): () => number {
  switch (distribution.kind) {
    case 'lognormal':
      return () => sampleLogNormal(distribution.mu, distribution.sigma, distribution.min, distribution.max, rng);
    case 'pareto':
      return () => samplePareto(distribution.mu, distribution.sigma || 1, distribution.min, distribution.max, rng);
    case 'fixed':
    default:
      return () => distribution.min;
  }
}

function pickActivePattern(
  configuredPattern: FlowPatternId,
  state: FlowEngineState,
  rng: () => number
): FlowPatternId {
  if (configuredPattern !== 'mixed') {
    state.lastPattern = configuredPattern;
    return configuredPattern;
  }
  const patterns: FlowPatternId[] = ['arb_constant', 'toxic', 'trend', 'mean_revert', 'benign_poisson'];
  const previous = state.lastPattern ?? patterns[Math.floor(rng() * patterns.length)];
  if (rng() < 0.1) {
    const nextIndex = Math.floor(rng() * patterns.length);
    state.lastPattern = patterns[nextIndex];
    return patterns[nextIndex];
  }
  state.lastPattern = previous;
  return previous;
}

function pickSide(
  pattern: FlowPatternId,
  state: FlowEngineState,
  toxicity: FlowToxicityConfig | undefined,
  rng: () => number
): 'base_in' | 'quote_in' {
  switch (pattern) {
    case 'arb_constant':
      return rng() > 0.5 ? 'base_in' : 'quote_in';
    case 'toxic':
      return rng() < 0.75 ? 'base_in' : 'quote_in';
    case 'trend': {
      if (rng() < 0.1) {
        state.trendSign = state.trendSign * (rng() > 0.5 ? 1 : -1);
      }
      return state.trendSign > 0 ? 'base_in' : 'quote_in';
    }
    case 'mean_revert': {
      if (rng() < 0.2) {
        state.trendSign *= -1;
      }
      return state.trendSign > 0 ? 'quote_in' : 'base_in';
    }
    case 'benign_poisson':
    default:
      return rng() > 0.5 ? 'base_in' : 'quote_in';
  }
}

function sampleLogNormal(
  mu: number,
  sigma: number,
  min: number,
  max: number,
  rng: () => number
): number {
  const u1 = Math.max(rng(), Number.EPSILON);
  const u2 = rng();
  const z0 = Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math.PI * u2);
  const value = Math.exp(mu + sigma * z0);
  return Math.max(min, Math.min(max, value));
}

function samplePareto(
  alpha: number,
  scale: number,
  min: number,
  max: number,
  rng: () => number
): number {
  const u = 1 - rng();
  const value = scale / Math.pow(u, 1 / alpha);
  return Math.max(min, Math.min(max, value));
}

function samplePoisson(lambda: number, rng: () => number): number {
  const L = Math.exp(-lambda);
  let p = 1;
  let k = 0;
  while (p > L) {
    k += 1;
    p *= rng();
  }
  return Math.max(0, k - 1);
}
