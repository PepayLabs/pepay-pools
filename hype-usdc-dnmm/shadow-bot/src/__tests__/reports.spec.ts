import { strict as assert } from 'node:assert';
import { describe, it } from 'node:test';
import { generateScoreboardArtifacts } from '../reports/scoreboard.js';
import { ScoreboardRow } from '../types.js';

const MOCK_ROWS: ScoreboardRow[] = [
  {
    settingId: 'dnmm_base',
    benchmark: 'dnmm',
    trades: 120,
    pnlQuoteTotal: 152.45,
    pnlPerMmNotionalBps: 8.2,
    pnlPerRisk: 1.42,
    winRatePct: 55,
    routerWinRatePct: 98.6,
    avgFeeBps: 25,
    avgFeeAfterRebateBps: 21,
    avgSlippageBps: 14,
    twoSidedUptimePct: 99.8,
    rejectRatePct: 0.4,
    aomqClampsTotal: 2,
    aomqClampsRatePct: 1.6,
    lvrCaptureBps: 12,
    priceImprovementVsCpmmBps: 18,
    previewStalenessRatioPct: 0.2,
    timeoutExpiryRatePct: 0.05,
    recenterCommitsTotal: 1
  },
  {
    settingId: 'dnmm_lvr_800',
    benchmark: 'dnmm',
    trades: 118,
    pnlQuoteTotal: 210.11,
    pnlPerMmNotionalBps: 12.5,
    pnlPerRisk: 1.87,
    winRatePct: 61,
    routerWinRatePct: 99.1,
    avgFeeBps: 27,
    avgFeeAfterRebateBps: 22,
    avgSlippageBps: 11,
    twoSidedUptimePct: 99.2,
    rejectRatePct: 0.6,
    aomqClampsTotal: 3,
    aomqClampsRatePct: 2.5,
    lvrCaptureBps: 18,
    priceImprovementVsCpmmBps: 24,
    previewStalenessRatioPct: 1.6,
    timeoutExpiryRatePct: 0.8,
    recenterCommitsTotal: 1
  },
  {
    settingId: 'cpmm_30bps',
    benchmark: 'cpmm',
    trades: 102,
    pnlQuoteTotal: 75,
    pnlPerMmNotionalBps: 4.1,
    pnlPerRisk: 0.9,
    winRatePct: 48,
    routerWinRatePct: 94,
    avgFeeBps: 30,
    avgFeeAfterRebateBps: 30,
    avgSlippageBps: 22,
    twoSidedUptimePct: 97,
    rejectRatePct: 1.4,
    aomqClampsTotal: 0,
    aomqClampsRatePct: 0,
    lvrCaptureBps: 0,
    priceImprovementVsCpmmBps: 0,
    previewStalenessRatioPct: 0.1,
    timeoutExpiryRatePct: 0.2,
    recenterCommitsTotal: 0
  }
];

describe('generateScoreboardArtifacts', () => {
  it('produces JSON, markdown scoreboard, and analyst summary with highlights', () => {
    const artifacts = generateScoreboardArtifacts({
      runId: 'test-run',
      mode: 'fork',
      pair: { pair: 'HYPE/USDC', chain: 'HypeEVM', baseSymbol: 'HYPE', quoteSymbol: 'USDC' },
      benchmarks: ['dnmm', 'cpmm'],
      rows: MOCK_ROWS,
      reports: {
        analystSummaryMd: {
          sections: ['Executive Summary', 'Recommendation & Next Canary'],
          highlightRules: [
            { id: 'pnl_per_risk_top', description: 'Highlight top pnl_per_risk performers', params: { top: 1 } },
            'Flag settings with preview_staleness_ratio > 1%'
          ]
        }
      }
    });

    assert.equal(artifacts.scoreboardJson.runId, 'test-run');
    assert.equal(artifacts.scoreboardJson.rows.length, MOCK_ROWS.length);

    assert.match(artifacts.scoreboardMarkdown, /\| Setting \| Benchmark \|/);
    assert.match(artifacts.summaryMarkdown, /## Executive Summary/);
    assert.match(artifacts.summaryMarkdown, /dnmm_lvr_800/);
    assert.match(artifacts.summaryMarkdown, /preview_staleness_ratio/);
  });
});
