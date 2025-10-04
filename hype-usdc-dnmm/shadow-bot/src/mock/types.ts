export type BuiltinScenarioName =
  | 'CALM'
  | 'DELTA_SOFT'
  | 'DELTA_HARD'
  | 'STALE_PYTH'
  | 'NEAR_FLOOR'
  | 'AOMQ_ON'
  | 'REBALANCE_JUMP';

export type ScenarioName = BuiltinScenarioName | 'CUSTOM';

export interface ScenarioParams {
  mid: number;
  delta_bps: number;
  spread_bps: number;
  conf_bps: number;
  pyth_stale?: boolean;
  aomq?: boolean;
  inventory_dev_pct?: number;
  rebalance_jump?: boolean;
  fallback?: boolean;
}

export interface ScenarioDefinition {
  name: ScenarioName;
  description: string;
  params: ScenarioParams;
}

export interface ScenarioTimelineFrame {
  t_sec: number;
  mid?: number;
  delta_bps?: number;
  spread_bps?: number;
  conf_bps?: number;
  pyth_stale?: boolean;
  aomq?: boolean;
  inventory_dev_pct?: number;
}

export interface ScenarioRandomWalkConfig {
  sigma_bps: number;
  step_ms: number;
}

export interface ScenarioFileSchema {
  timeline?: ScenarioTimelineFrame[];
  loop?: boolean;
  random_walk?: ScenarioRandomWalkConfig;
}

export interface ScenarioRuntimeState {
  frameIndex: number;
  elapsedMs: number;
  looping: boolean;
  randomWalk?: ScenarioRandomWalkConfig;
}

export interface ScenarioRuntime {
  definition: ScenarioDefinition;
  timeline: ScenarioTimelineFrame[];
  state: ScenarioRuntimeState;
}

export interface MockOracleInputs {
  params: ScenarioParams;
  baseDecimals: number;
  quoteDecimals: number;
  timestampMs: number;
}

export interface MockPoolInputs {
  params: ScenarioParams;
  baseDecimals: number;
  quoteDecimals: number;
}
