import dayjs from 'dayjs';
import { QuotePlan, QuoteDirection } from '../types.js';
import { computeLogBuckets } from '../utils/math.js';

const EXPLICIT_AMOUNTS = [1, 10, 25, 50, 100, 200, 500, 1000, 2500, 5000, 7500, 10000];

export function buildQuotePlan(): QuotePlan {
  const logBuckets = computeLogBuckets(1, 10000, 6);
  const deduped = Array.from(new Set([...EXPLICIT_AMOUNTS, ...logBuckets])).sort((a, b) => a - b);
  return {
    amounts_usd: deduped,
    directions: ['USDC->HYPE', 'HYPE->USDC'] as QuoteDirection[],
    slippage_tolerance_bps: 50,
  };
}

export function newRunId(): string {
  return `${dayjs().toISOString()}__${Math.random().toString(36).slice(2, 8)}`;
}
