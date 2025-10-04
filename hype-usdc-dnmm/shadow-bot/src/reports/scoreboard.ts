import {
  BenchmarkId,
  HighlightRule,
  ReportsConfig,
  RiskScenarioDefinition,
  ScoreboardRow,
  ShadowBotLabels
} from '../types.js';

interface ScoreboardArtifactInput {
  readonly runId: string;
  readonly mode: string;
  readonly pair: ShadowBotLabels;
  readonly rows: readonly ScoreboardRow[];
  readonly benchmarks: readonly BenchmarkId[];
  readonly reports?: ReportsConfig;
  readonly scenarioMeta?: Record<string, RiskScenarioDefinition | undefined>;
}

interface ScoreboardJsonPayload {
  readonly runId: string;
  readonly generatedAt: string;
  readonly mode: string;
  readonly pair: ShadowBotLabels;
  readonly benchmarks: readonly BenchmarkId[];
  readonly statistics: {
    readonly totalRows: number;
    readonly totalSettings: number;
    readonly totalBenchmarks: number;
  };
  readonly rows: readonly ScoreboardRow[];
  readonly scenarioMeta?: Record<string, RiskScenarioDefinition | undefined>;
}

interface ScoreboardArtifacts {
  readonly scoreboardJson: ScoreboardJsonPayload;
  readonly scoreboardMarkdown: string;
  readonly summaryMarkdown: string;
}

type HighlightRuleInput = HighlightRule | string;

interface HighlightFinding {
  readonly ruleId: string;
  readonly description: string;
  readonly matches: readonly HighlightMatch[];
}

interface HighlightMatch {
  readonly settingId: string;
  readonly benchmark: BenchmarkId;
  readonly detail: string;
}

interface SummaryContext {
  readonly input: ScoreboardArtifactInput;
  readonly highlights: readonly HighlightFinding[];
  readonly baselineRouterWinRate?: number;
  readonly topPerBenchmark: Map<BenchmarkId, ScoreboardRow>;
  readonly aggregate: AggregateStats;
  readonly scenarioMeta: Record<string, RiskScenarioDefinition | undefined>;
  readonly scenarioInsights: ScenarioInsights;
}

interface AggregateStats {
  readonly avgPnlPerRisk: number;
  readonly avgRouterWinRate: number;
  readonly avgUptime: number;
  readonly avgRejectRate: number;
  readonly avgLvrCapture: number;
  readonly maxTimeoutRate: number;
  readonly avgEffectiveFee: number;
}

interface ScenarioInsights {
  readonly autopauseSettings: readonly string[];
  readonly ttlTargets: readonly {
    settingId: string;
    targetPct: number;
    observedPct?: number;
  }[];
}

export function generateScoreboardArtifacts(input: ScoreboardArtifactInput): ScoreboardArtifacts {
  const scoreboardJson: ScoreboardJsonPayload = {
    runId: input.runId,
    generatedAt: new Date().toISOString(),
    mode: input.mode,
    pair: input.pair,
    benchmarks: input.benchmarks,
    statistics: {
      totalRows: input.rows.length,
      totalSettings: new Set(input.rows.map((row) => row.settingId)).size,
      totalBenchmarks: new Set(input.rows.map((row) => row.benchmark)).size
    },
    rows: input.rows,
    scenarioMeta: input.scenarioMeta
  };

  const scoreboardMarkdown = buildScoreboardMarkdown(input.rows);
  const baselineRouterWinRate = findBaselineRouterWinRate(input.rows);
  const highlights = buildHighlights(input, baselineRouterWinRate);
  const topPerBenchmark = computeTopPerBenchmark(input.rows);
  const aggregate = computeAggregateStats(input.rows);
  const scenarioMeta = input.scenarioMeta ?? {};
  const scenarioInsights = computeScenarioInsights(input.rows, scenarioMeta);
  const summaryMarkdown = buildSummaryMarkdown({
    input,
    highlights,
    baselineRouterWinRate,
    topPerBenchmark,
    aggregate,
    scenarioMeta,
    scenarioInsights
  });

  return {
    scoreboardJson,
    scoreboardMarkdown,
    summaryMarkdown
  };
}

function buildScoreboardMarkdown(rows: readonly ScoreboardRow[]): string {
  const header = [
    'Setting',
    'Benchmark',
    'Trades',
    'PnL Total',
    'PnL / Risk',
    'Router Win %',
    'Uptime %',
    'Reject %',
    'LVR Capture (bps)',
    'Price Δ vs CPMM (bps)',
    'Preview Stale %',
    'Timeout %',
    'AOMQ Clamp %'
  ];
  const lines = rows.map((row) => [
    row.settingId,
    row.benchmark,
    row.trades.toString(),
    formatFixed(row.pnlQuoteTotal, 4),
    formatFixed(row.pnlPerRisk, 4),
    formatFixed(row.routerWinRatePct, 2),
    formatFixed(row.twoSidedUptimePct, 3),
    formatFixed(row.rejectRatePct, 3),
    formatFixed(row.lvrCaptureBps, 3),
    row.priceImprovementVsCpmmBps !== undefined ? formatFixed(row.priceImprovementVsCpmmBps, 3) : '—',
    formatFixed(row.previewStalenessRatioPct, 3),
    formatFixed(row.timeoutExpiryRatePct, 3),
    formatFixed(row.aomqClampsRatePct, 3)
  ]);
  const table = [
    `| ${header.join(' | ')} |`,
    `| ${header.map(() => '---').join(' | ')} |`,
    ...lines.map((cells) => `| ${cells.join(' | ')} |`)
  ];
  return ['## Scoreboard', '', ...table, ''].join('\n');
}

function buildSummaryMarkdown(context: SummaryContext): string {
  const summaryCfg = context.input.reports?.analystSummaryMd;
  const sections = summaryCfg?.sections?.length ? summaryCfg.sections : defaultSections();
  const content: string[] = ['# Analyst Summary', ''];
  for (const section of sections) {
    content.push(`## ${section}`);
    content.push(buildSectionBody(section, context));
    content.push('');
  }
  return content.join('\n').replace(/\n{3,}/g, '\n\n');
}

function buildSectionBody(section: string, context: SummaryContext): string {
  switch (section) {
    case 'Executive Summary':
      return buildExecutiveSummary(context);
    case 'Methodology & Scenarios':
      return buildMethodology(context);
    case 'Headline KPIs (by Setting & Benchmark)':
      return buildHeadlineKpis(context);
    case 'Volatility Regimes (Calm/Elevated/Crisis)':
      return 'Scenario-specific breakdowns are pending metrics instrumentation; current results aggregate across all configured flows.';
    case 'Size Buckets (≤S0, 2S0–5S0, ≥5S0)':
      return 'Size bucket analytics will be emitted once histogram exports are wired into the reporting layer.';
    case 'Edge Attribution: Size/InvTilt/LVR/Floor/Rebate':
      return buildEdgeAttribution(context);
    case 'Risk & Uptime':
      return buildRiskSection(context);
    case 'Recommendation & Next Canary':
      return buildRecommendation(context);
    default:
      return 'Section template recognised, but no automated narrative is defined yet.';
  }
}

function buildExecutiveSummary(context: SummaryContext): string {
  const { input, highlights } = context;
  const bullets: string[] = [];
  bullets.push(`- Run **${input.runId}** executed in ${input.mode.toUpperCase()} mode over ${new Set(input.rows.map((row) => row.settingId)).size} setting variants and ${new Set(input.rows.map((row) => row.benchmark)).size} benchmarks for pair ${input.pair.pair}.`);
  if (highlights.length > 0) {
    for (const highlight of highlights) {
      if (highlight.matches.length === 0) continue;
      bullets.push(`- ${highlight.description}: ${highlight.matches.map((match) => match.detail).join('; ')}`);
    }
  } else {
    bullets.push('- No highlight rules triggered for this run.');
  }
  if (context.scenarioInsights.autopauseSettings.length > 0) {
    bullets.push(
      `- Risk scenarios flagged autopause expectations on ${context.scenarioInsights.autopauseSettings.join(', ')}.`
    );
  }
  if (context.scenarioInsights.ttlTargets.length > 0) {
    const formatted = context.scenarioInsights.ttlTargets
      .map(({ settingId, targetPct, observedPct }) => {
        const observed = observedPct !== undefined ? `${formatFixed(observedPct, 2)}% observed` : 'obs N/A';
        return `${settingId}: ${formatFixed(targetPct, 2)}% target (${observed})`;
      })
      .join('; ');
    bullets.push(`- TTL pressure scenarios applied → ${formatted}.`);
  }
  return bullets.join('\n');
}

function buildMethodology(context: SummaryContext): string {
  const durationEstimateMinutes = estimateDurationMinutes(context.input.rows);
  return [
    `- Benchmarks evaluated: ${context.input.benchmarks.join(', ')}`,
    `- Aggregate unique settings: ${new Set(context.input.rows.map((row) => row.settingId)).size}`,
    `- Approximate simulated wall-clock duration: ~${durationEstimateMinutes.toFixed(1)} minutes per setting (derived from flow configurations).`
  ].join('\n');
}

function buildHeadlineKpis(context: SummaryContext): string {
  const lines: string[] = [];
  for (const [benchmark, row] of context.topPerBenchmark.entries()) {
    lines.push(`- **${benchmark}** → top PnL/Risk ${formatFixed(row.pnlPerRisk, 4)} from ${row.settingId} (router win ${formatFixed(row.routerWinRatePct, 2)}%).`);
  }
  if (lines.length === 0) {
    lines.push('- No scoreboard rows available.');
  }
  return lines.join('\n');
}

function buildEdgeAttribution(context: SummaryContext): string {
  return [
    `- Average router win rate: ${formatFixed(context.aggregate.avgRouterWinRate, 2)}% (mean across settings).`,
    `- Average effective fee after rebate: ${formatFixed(context.aggregate.avgEffectiveFee, 3)} bps; LVR capture averages ${formatFixed(context.aggregate.avgLvrCapture, 3)} bps.`,
    `- Observed price improvement vs CPMM (where comparable) peaks at ${formatFixed(maxPriceImprovement(context.input.rows), 3)} bps.`
  ].join('\n');
}

function buildRiskSection(context: SummaryContext): string {
  const lines = [
    `- Median two-sided uptime: ${formatFixed(context.aggregate.avgUptime, 3)}% (mean).`,
    `- Average reject rate: ${formatFixed(context.aggregate.avgRejectRate, 3)}%; worst-case timeout rate ${formatFixed(context.aggregate.maxTimeoutRate, 3)}%.`
  ];
  if (context.scenarioInsights.autopauseSettings.length > 0) {
    lines.push(
      `- Autopause guardrails expected on ${context.scenarioInsights.autopauseSettings.join(', ')}; monitor inventory decay to confirm.`
    );
  }
  if (context.scenarioInsights.ttlTargets.length > 0) {
    for (const { settingId, targetPct, observedPct } of context.scenarioInsights.ttlTargets) {
      const observed = observedPct !== undefined ? `${formatFixed(observedPct, 2)}%` : 'N/A';
      lines.push(`- TTL expiry for ${settingId}: target ${formatFixed(targetPct, 2)}%, observed ${observed}.`);
    }
  }
  return lines.join('\n');
}

function buildRecommendation(context: SummaryContext): string {
  const topRule = context.highlights.find((rule) => rule.ruleId === 'pnl_per_risk_top');
  if (topRule && topRule.matches.length > 0) {
    const candidate = topRule.matches[0];
    return `Recommend extending canary coverage to **${candidate.settingId} (${candidate.benchmark})** given strongest pnl_per_risk performance while clearing router win guardrails.`;
  }
  if (context.topPerBenchmark.size > 0) {
    const [benchmark, row] = Array.from(context.topPerBenchmark.entries())[0];
    return `Default recommendation: keep ${row.settingId} (${benchmark}) as control; expand monitoring on runners exceeding router win ${formatFixed(row.routerWinRatePct, 2)}%.`;
  }
  return 'No recommendation available (insufficient data).';
}

function buildHighlights(
  input: ScoreboardArtifactInput,
  baselineRouterWinRate?: number
): HighlightFinding[] {
  const rules = input.reports?.analystSummaryMd?.highlightRules ?? [];
  return rules.map((rule) => {
    const normalized = normalizeHighlightRule(rule);
    return evaluateRule(normalized.id, normalized.description, input.rows, baselineRouterWinRate, normalized.params);
  });
}

function evaluateRule(
  ruleId: string,
  description: string,
  rows: readonly ScoreboardRow[],
  baselineRouterWinRate: number | undefined,
  params: Record<string, number | string> | undefined
): HighlightFinding {
  switch (ruleId) {
    case 'pnl_per_risk_top':
      return evaluatePnlPerRiskTop(description, rows, baselineRouterWinRate, params);
    case 'preview_staleness_threshold':
      return evaluatePreviewStaleness(description, rows, params);
    case 'uptime_floor':
      return evaluateUptimeFloor(description, rows, params);
    default:
      return { description, ruleId, matches: [] };
  }
}

function evaluatePnlPerRiskTop(
  description: string,
  rows: readonly ScoreboardRow[],
  baselineRouterWinRate: number | undefined,
  params: Record<string, number | string> | undefined
): HighlightFinding {
  const top = typeof params?.top === 'number' && Number.isFinite(params.top) ? Number(params.top) : 2;
  const dnmmRows = rows.filter((row) => row.benchmark === 'dnmm');
  const sorted = [...dnmmRows].sort((a, b) => b.pnlPerRisk - a.pnlPerRisk);
  const matches: HighlightMatch[] = [];
  const baseline = baselineRouterWinRate ?? 0;
  for (const row of sorted.slice(0, Math.max(0, top))) {
    if (row.routerWinRatePct <= baseline) continue;
    matches.push({
      settingId: row.settingId,
      benchmark: row.benchmark,
      detail: `${row.settingId} (PnL/Risk ${formatFixed(row.pnlPerRisk, 4)}, Router ${formatFixed(row.routerWinRatePct, 2)}%)`
    });
  }
  return { ruleId: 'pnl_per_risk_top', description, matches };
}

function evaluatePreviewStaleness(
  description: string,
  rows: readonly ScoreboardRow[],
  params: Record<string, number | string> | undefined
): HighlightFinding {
  const threshold = typeof params?.thresholdPct === 'number' ? Number(params.thresholdPct) : 1;
  const matches = rows
    .filter((row) => row.previewStalenessRatioPct > threshold)
    .map((row) => ({
      settingId: row.settingId,
      benchmark: row.benchmark,
      detail: `${row.settingId}/${row.benchmark} staleness ${formatFixed(row.previewStalenessRatioPct, 2)}%`
    }));
  return { ruleId: 'preview_staleness_threshold', description, matches };
}

function evaluateUptimeFloor(
  description: string,
  rows: readonly ScoreboardRow[],
  params: Record<string, number | string> | undefined
): HighlightFinding {
  const threshold = typeof params?.thresholdPct === 'number' ? Number(params.thresholdPct) : 99.5;
  const matches = rows
    .filter((row) => row.twoSidedUptimePct < threshold)
    .map((row) => ({
      settingId: row.settingId,
      benchmark: row.benchmark,
      detail: `${row.settingId}/${row.benchmark} uptime ${formatFixed(row.twoSidedUptimePct, 3)}%`
    }));
  return { ruleId: 'uptime_floor', description, matches };
}

function normalizeHighlightRule(rule: HighlightRuleInput): HighlightRule {
  if (typeof rule !== 'string') {
    return rule;
  }
  const description = rule.trim();
  const lowered = description.toLowerCase();
  if (lowered.includes('preview_staleness')) {
    return {
      id: 'preview_staleness_threshold',
      description,
      params: { thresholdPct: extractPercentage(description) ?? 1 }
    };
  }
  if (lowered.includes('uptime') || lowered.includes('two_sided')) {
    return {
      id: 'uptime_floor',
      description,
      params: { thresholdPct: extractPercentage(description) ?? 99.5 }
    };
  }
  const topMatch = description.match(/top\s+(\d+)/i);
  return {
    id: 'pnl_per_risk_top',
    description,
    params: { top: topMatch ? Number(topMatch[1]) : 2 }
  };
}

function extractPercentage(text: string): number | undefined {
  const match = text.match(/([-+]?[0-9]*\.?[0-9]+)\s*%/);
  if (!match) return undefined;
  const value = Number(match[1]);
  return Number.isFinite(value) ? value : undefined;
}

function computeTopPerBenchmark(rows: readonly ScoreboardRow[]): Map<BenchmarkId, ScoreboardRow> {
  const result = new Map<BenchmarkId, ScoreboardRow>();
  for (const row of rows) {
    const current = result.get(row.benchmark);
    if (!current || row.pnlPerRisk > current.pnlPerRisk) {
      result.set(row.benchmark, row);
    }
  }
  return result;
}

function computeAggregateStats(rows: readonly ScoreboardRow[]): AggregateStats {
  if (rows.length === 0) {
    return {
      avgPnlPerRisk: 0,
      avgRouterWinRate: 0,
      avgUptime: 0,
      avgRejectRate: 0,
      avgLvrCapture: 0,
      maxTimeoutRate: 0,
      avgEffectiveFee: 0
    };
  }
  const sum = rows.reduce(
    (acc, row) => {
      acc.pnlPerRisk += row.pnlPerRisk;
      acc.routerWin += row.routerWinRatePct;
      acc.uptime += row.twoSidedUptimePct;
      acc.reject += row.rejectRatePct;
      acc.lvr += row.lvrCaptureBps;
      acc.effectiveFee += row.avgFeeAfterRebateBps;
      acc.timeout = Math.max(acc.timeout, row.timeoutExpiryRatePct);
      return acc;
    },
    { pnlPerRisk: 0, routerWin: 0, uptime: 0, reject: 0, lvr: 0, timeout: 0, effectiveFee: 0 }
  );
  return {
    avgPnlPerRisk: sum.pnlPerRisk / rows.length,
    avgRouterWinRate: sum.routerWin / rows.length,
    avgUptime: sum.uptime / rows.length,
    avgRejectRate: sum.reject / rows.length,
    avgLvrCapture: sum.lvr / rows.length,
    maxTimeoutRate: sum.timeout,
    avgEffectiveFee: sum.effectiveFee / rows.length
  };
}

function computeScenarioInsights(
  rows: readonly ScoreboardRow[],
  meta: Record<string, RiskScenarioDefinition | undefined>
): ScenarioInsights {
  const autopauseSettings: string[] = [];
  const ttlTargets: { settingId: string; targetPct: number; observedPct?: number }[] = [];
  const dnmmRows = new Map<string, ScoreboardRow>();
  for (const row of rows) {
    if (row.benchmark === 'dnmm') {
      dnmmRows.set(row.settingId, row);
    }
  }
  for (const [settingId, scenario] of Object.entries(meta)) {
    if (!scenario) continue;
    if (scenario.autopauseExpected) {
      autopauseSettings.push(settingId);
    }
    if (scenario.ttlExpiryRateTarget !== undefined && Number.isFinite(scenario.ttlExpiryRateTarget)) {
      const row = dnmmRows.get(settingId);
      ttlTargets.push({
        settingId,
        targetPct: Number(scenario.ttlExpiryRateTarget) * 100,
        observedPct: row?.timeoutExpiryRatePct
      });
    }
  }
  autopauseSettings.sort();
  return {
    autopauseSettings,
    ttlTargets
  };
}

function findBaselineRouterWinRate(rows: readonly ScoreboardRow[]): number | undefined {
  const baseline = rows.find((row) => row.settingId === 'dnmm_base' && row.benchmark === 'dnmm');
  return baseline?.routerWinRatePct;
}

function estimateDurationMinutes(rows: readonly ScoreboardRow[]): number {
  if (rows.length === 0) return 0;
  // Proxy: assume three simulated days per run per specification (~72h)
  const uniqueSettings = new Set(rows.map((row) => row.settingId)).size;
  const uniqueBenchmarks = new Set(rows.map((row) => row.benchmark)).size;
  const totalHours = 72 * uniqueSettings * (uniqueBenchmarks > 0 ? 1 : 0);
  return totalHours * 60;
}

function maxPriceImprovement(rows: readonly ScoreboardRow[]): number {
  return rows.reduce((max, row) => {
    if (row.priceImprovementVsCpmmBps === undefined) return max;
    return Math.max(max, row.priceImprovementVsCpmmBps);
  }, 0);
}

function defaultSections(): string[] {
  return [
    'Executive Summary',
    'Methodology & Scenarios',
    'Headline KPIs (by Setting & Benchmark)',
    'Volatility Regimes (Calm/Elevated/Crisis)',
    'Size Buckets (≤S0, 2S0–5S0, ≥5S0)',
    'Edge Attribution: Size/InvTilt/LVR/Floor/Rebate',
    'Risk & Uptime',
    'Recommendation & Next Canary'
  ];
}

function formatFixed(value: number, decimals: number): string {
  if (!Number.isFinite(value)) {
    return '0';
  }
  return value.toFixed(decimals);
}
