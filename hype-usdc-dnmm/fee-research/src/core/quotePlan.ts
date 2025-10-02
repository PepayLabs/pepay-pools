import dayjs from 'dayjs';
import { QuotePlan, QuoteDirection } from '../types.js';
import { computeLogBuckets } from '../utils/math.js';

const EXPLICIT_AMOUNTS = [1, 10, 25, 50, 100, 200, 500, 1000, 2500, 5000, 7500, 10000];

const FAST_AMOUNTS = [1, 10, 100, 1000];

export function buildQuotePlan(): QuotePlan {
  const fastMode = process.env.FAST_QUOTE_PLAN === '1' || process.env.FAST_MODE === '1';
  const baseAmounts = fastMode ? FAST_AMOUNTS : EXPLICIT_AMOUNTS;
  const logBuckets = fastMode ? [] : computeLogBuckets(1, 10000, 6);
  const deduped = Array.from(new Set([...baseAmounts, ...logBuckets])).sort((a, b) => a - b);
  return {
    amounts_usd: deduped,
    directions: ['USDC->HYPE', 'HYPE->USDC'] as QuoteDirection[],
    slippage_tolerance_bps: 50,
  };
}

export function newRunId(): string {
  return `${dayjs().toISOString()}__${Math.random().toString(36).slice(2, 8)}`;
}
