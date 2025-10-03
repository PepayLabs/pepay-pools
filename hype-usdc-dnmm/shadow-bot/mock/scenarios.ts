import fs from 'fs/promises';
import path from 'path';
import {
  BuiltinScenarioName,
  ScenarioDefinition,
  ScenarioFileSchema,
  ScenarioName,
  ScenarioParams
} from './types.js';

const BUILTIN_SCENARIOS: Record<BuiltinScenarioName, ScenarioDefinition> = {
  CALM: {
    name: 'CALM',
    description: 'HC≈Pyth, small spread, low conf, no AOMQ',
    params: {
      mid: 1.0,
      delta_bps: 10,
      spread_bps: 10,
      conf_bps: 20
    }
  },
  DELTA_SOFT: {
    name: 'DELTA_SOFT',
    description: 'delta in (accept, soft] ⇒ haircuts',
    params: {
      mid: 1.0,
      delta_bps: 40,
      spread_bps: 20,
      conf_bps: 40
    }
  },
  DELTA_HARD: {
    name: 'DELTA_HARD',
    description: 'delta > hard ⇒ reject/AOMQ',
    params: {
      mid: 1.0,
      delta_bps: 120,
      spread_bps: 50,
      conf_bps: 80,
      aomq: true
    }
  },
  STALE_PYTH: {
    name: 'STALE_PYTH',
    description: 'HC healthy; Pyth stale ⇒ fallback/strict caps',
    params: {
      mid: 1.0,
      delta_bps: 20,
      spread_bps: 30,
      conf_bps: 120,
      pyth_stale: true,
      fallback: true
    }
  },
  NEAR_FLOOR: {
    name: 'NEAR_FLOOR',
    description: 'inventory near floor to exercise partial fill',
    params: {
      mid: 1.0,
      delta_bps: 10,
      spread_bps: 15,
      conf_bps: 30,
      inventory_dev_pct: 8
    }
  },
  AOMQ_ON: {
    name: 'AOMQ_ON',
    description: 'trigger AOMQ clamps & emergency spread',
    params: {
      mid: 1.0,
      delta_bps: 55,
      spread_bps: 25,
      conf_bps: 60,
      aomq: true
    }
  },
  REBALANCE_JUMP: {
    name: 'REBALANCE_JUMP',
    description: 'mid jumps +8%; check targetBaseXstar glide',
    params: {
      mid: 1.08,
      delta_bps: 15,
      spread_bps: 20,
      conf_bps: 35,
      rebalance_jump: true
    }
  }
};

function normalizeScenarioName(raw: string): ScenarioName {
  const upper = raw.toUpperCase();
  if (upper in BUILTIN_SCENARIOS) {
    return upper as BuiltinScenarioName;
  }
  return 'CUSTOM';
}

async function readScenarioFile(filePath: string): Promise<ScenarioFileSchema> {
  const resolved = path.resolve(filePath);
  const text = await fs.readFile(resolved, 'utf8');
  const parsed = JSON.parse(text) as ScenarioFileSchema;
  if (parsed.timeline) {
    parsed.timeline = parsed.timeline
      .map((frame) => ({ ...frame }))
      .sort((a, b) => a.t_sec - b.t_sec);
  }
  return parsed;
}

function mergeParams(base: ScenarioParams, override?: Partial<ScenarioParams>): ScenarioParams {
  if (!override) return base;
  return {
    ...base,
    ...override
  };
}

function selectFrame(params: ScenarioFileSchema, elapsedMs: number): Partial<ScenarioParams> | undefined {
  const { timeline } = params;
  if (!timeline || timeline.length === 0) return undefined;
  const elapsedSec = Math.max(0, Math.floor(elapsedMs / 1000));
  const terminal = timeline[timeline.length - 1].t_sec;
  const loop = params.loop === true && terminal > 0;
  const effectiveSec = loop ? elapsedSec % (terminal + 1) : elapsedSec;
  for (let i = timeline.length - 1; i >= 0; i -= 1) {
    if (effectiveSec >= timeline[i].t_sec) {
      const frame = timeline[i];
      return {
        mid: frame.mid,
        delta_bps: frame.delta_bps,
        spread_bps: frame.spread_bps,
        conf_bps: frame.conf_bps,
        pyth_stale: frame.pyth_stale,
        aomq: frame.aomq,
        inventory_dev_pct: frame.inventory_dev_pct
      };
    }
  }
  return undefined;
}

export class ScenarioEngine {
  private readonly baseline: ScenarioParams;
  private readonly schema?: ScenarioFileSchema;
  private readonly startMs: number;

  constructor(definition: ScenarioDefinition, startTimestampMs: number, schema?: ScenarioFileSchema) {
    this.baseline = definition.params;
    this.schema = schema;
    this.startMs = startTimestampMs;
  }

  getParams(timestampMs: number): ScenarioParams {
    const elapsedMs = Math.max(0, timestampMs - this.startMs);
    const override = this.schema ? selectFrame(this.schema, elapsedMs) : undefined;
    return mergeParams(this.baseline, override);
  }
}

export async function createScenarioEngine(
  rawName: string,
  startTimestampMs: number,
  scenarioFile?: string
): Promise<{ engine: ScenarioEngine; definition: ScenarioDefinition; source: string }> {
  const normalized = normalizeScenarioName(rawName);
  const baseDefinition = normalized === 'CUSTOM'
    ? {
        name: 'CUSTOM' as ScenarioName,
        description: 'custom scenario loaded from file',
        params: BUILTIN_SCENARIOS.CALM.params
      }
    : BUILTIN_SCENARIOS[normalized as BuiltinScenarioName];

  if (normalized !== 'CUSTOM' && !scenarioFile) {
    return {
      engine: new ScenarioEngine(baseDefinition, startTimestampMs),
      definition: baseDefinition,
      source: 'builtin'
    };
  }

  if (!scenarioFile) {
    throw new Error('CUSTOM scenario requires SCENARIO_FILE to be provided');
  }

  const schema = await readScenarioFile(scenarioFile);
  const resolvedDefinition: ScenarioDefinition =
    normalized === 'CUSTOM'
      ? {
          name: 'CUSTOM',
          description: `custom scenario from ${path.basename(scenarioFile)}`,
          params: mergeParams(baseDefinition.params, schema.timeline?.[0] as Partial<ScenarioParams>)
        }
      : baseDefinition;

  return {
    engine: new ScenarioEngine(resolvedDefinition, startTimestampMs, schema),
    definition: resolvedDefinition,
    source: normalized === 'CUSTOM' ? 'custom' : 'builtin+override'
  };
}

export { BUILTIN_SCENARIOS };
