import {
  HcOracleSample,
  OracleReaderAdapter,
  OracleSnapshot,
  PythOracleSample,
  RiskScenarioDefinition
} from '../types.js';
import { createRng, hashStringToSeed } from '../utils/random.js';

const BPS = 10_000;

export interface SimOracleOptions {
  readonly baseMidWad?: bigint;
  readonly tickMs?: number;
  readonly seed?: number;
  readonly scenario?: RiskScenarioDefinition;
}

interface OutageState {
  remainingBursts: number;
  activeTicks: number;
  cooldownTicks: number;
}

export class SimOracleReader implements OracleReaderAdapter {
  private midWad: bigint;

  private readonly rng: () => number;

  private readonly spreadRange: readonly [number, number];

  private readonly sigmaRange: readonly [number, number];

  private readonly spreadShiftBps: number;

  private readonly pythDropRate: number;

  private readonly outage?: OutageState;

  private readonly outageDurationTicks: number;

  private readonly tickMs: number;

  private tickIndex = 0;

  constructor(options: SimOracleOptions = {}) {
    const baseMid = options.baseMidWad ?? 1_000_000_000_000_000_000n;
    const scenario = options.scenario;
    const seed = options.seed ?? hashStringToSeed(scenario?.id ?? 'sim_oracle');
    this.midWad = baseMid;
    this.rng = createRng(seed);
    this.spreadRange = scenario?.bboSpreadBps ?? [8, 25];
    this.sigmaRange = scenario?.sigmaBps ?? [5, 35];
    this.spreadShiftBps = parseSpreadShift(scenario?.bboSpreadBpsShift);
    this.pythDropRate = scenario?.pythDropRate ?? 0;
    this.tickMs = options.tickMs ?? 250;
    this.outageDurationTicks = scenario?.pythOutages
      ? Math.max(1, Math.round((scenario.pythOutages.secsEach * 1_000) / this.tickMs))
      : 0;
    this.outage = scenario?.pythOutages
      ? {
          remainingBursts: scenario.pythOutages.bursts,
          activeTicks: 0,
          cooldownTicks: 0
        }
      : undefined;
  }

  async sample(): Promise<OracleSnapshot> {
    this.tickIndex += 1;
    const sigmaBps = sampleRange(this.rng, this.sigmaRange);
    const spreadBps = sampleRange(this.rng, this.spreadRange) + this.spreadShiftBps;
    const mid = this.nextMid(sigmaBps);

    const hc: HcOracleSample = {
      status: 'ok',
      reason: 'OK',
      midWad: mid,
      spreadBps,
      bidWad: adjustBid(mid, spreadBps),
      askWad: adjustAsk(mid, spreadBps),
      ageSec: 0,
      sigmaBps
    };

    const pyth = this.samplePyth(mid, sigmaBps);

    return {
      hc,
      pyth,
      observedAtMs: Date.now()
    };
  }

  private nextMid(sigmaBps: number): bigint {
    const sigmaPct = sigmaBps / BPS;
    const shock = gaussian(this.rng) * sigmaPct * 0.25;
    const base = Number(this.midWad) / Number(10n ** 18n);
    const next = Math.max(0.01, base * (1 + shock));
    this.midWad = BigInt(Math.round(next * 1e18));
    return this.midWad;
  }

  private samplePyth(mid: bigint, sigmaBps: number): PythOracleSample {
    const dropout = this.pythDropRate > 0 && this.rng() < this.pythDropRate;
    const outageActive = this.advanceOutageState();
    if (dropout || outageActive) {
      return {
        status: 'error',
        reason: 'PythError',
        statusDetail: dropout ? 'synthetic_dropout' : 'synthetic_outage'
      };
    }
    const confBps = Math.max(5, Math.round(sigmaBps * 0.6));
    return {
      status: 'ok',
      reason: 'OK',
      midWad: mid,
      confBps,
      publishTimeSec: Math.floor(Date.now() / 1_000)
    };
  }

  private advanceOutageState(): boolean {
    if (!this.outage || this.outage.remainingBursts <= 0) {
      return false;
    }
    if (this.outage.activeTicks > 0) {
      this.outage.activeTicks -= 1;
      return true;
    }
    if (this.outage.cooldownTicks > 0) {
      this.outage.cooldownTicks -= 1;
      return false;
    }
    if (this.rng() < 0.003) {
      this.outage.activeTicks = this.outageDurationTicks;
      this.outage.cooldownTicks = Math.round((30_000 / this.tickMs) * (1 + this.rng()));
      this.outage.remainingBursts -= 1;
      return true;
    }
    return false;
  }
}

function sampleRange(rng: () => number, range: readonly [number, number]): number {
  const [min, max] = range;
  if (max <= min) return min;
  return Math.round(min + rng() * (max - min));
}

function gaussian(rng: () => number): number {
  const u1 = Math.max(rng(), Number.EPSILON);
  const u2 = rng();
  return Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
}

function adjustBid(mid: bigint, spreadBps: number): bigint {
  const spread = (mid * BigInt(Math.max(spreadBps, 0))) / BigInt(BPS);
  return mid - spread / 2n;
}

function adjustAsk(mid: bigint, spreadBps: number): bigint {
  const spread = (mid * BigInt(Math.max(spreadBps, 0))) / BigInt(BPS);
  return mid + spread / 2n;
}

function parseSpreadShift(shift?: string): number {
  if (!shift) return 0;
  const normalized = shift.trim();
  const value = Number(normalized.replace('+', ''));
  return Number.isFinite(value) ? value : 0;
}
