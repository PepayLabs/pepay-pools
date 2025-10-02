import fs from 'fs/promises';
import path from 'path';
import dayjs from 'dayjs';
import { buildAdapters } from './adapters.js';
import { buildQuotePlan, newRunId } from './quotePlan.js';
import { findChain } from '../registries/chains.js';
import { findToken } from '../registries/tokens.js';
import { logger } from '../utils/logger.js';
import { MetricsWriter } from './metricsWriter.js';
import { QuoteDirection } from '../types.js';
import { AggregatorAdapter } from '../adapters/aggregatorAdapter.js';
import { ethers } from 'ethers';
import { performance } from 'perf_hooks';

interface RunSummary {
  run_id: string;
  timestamp_iso: string;
  rows_written: number;
  adapters_attempted: number;
  adapters_with_success: string[];
  adapters_failed: Record<string, string[]>;
}

const RUN_LOG_PATH = path.resolve(process.cwd(), 'metrics/hype-metrics/run-logs.jsonl');

async function logRun(summary: RunSummary) {
  await fs.mkdir(path.dirname(RUN_LOG_PATH), { recursive: true });
  await fs.appendFile(RUN_LOG_PATH, JSON.stringify(summary) + '\n', 'utf-8');
}

function stableAmountIn(direction: QuoteDirection, usd: number, decimals: number): { tokens: string; wei: bigint } {
  if (direction === 'USDC->HYPE') {
    const tokens = usd.toFixed(6);
    const wei = BigInt(Math.round(usd * 1_000_000));
    return { tokens, wei };
  }
  const assumedPrice = 1; // Fallback assumption pending mid price discovery
  const tokensFloat = usd / assumedPrice;
  const tokens = tokensFloat.toFixed(Math.min(decimals, 6));
  const wei = ethers.parseUnits(tokens, decimals);
  return { tokens, wei };
}

export async function runEvaluation(): Promise<void> {
  const runId = newRunId();
  const timestamp = dayjs().toISOString();
  const chain = await findChain(999);
  if (!chain) {
    throw new Error('HyperEVM chain (id 999) missing from chains.json');
  }

  const tokenIn = await findToken('USDC', 999);
  const tokenOut = await findToken('WHYPE', 999);
  if (!tokenIn || !tokenOut) {
    throw new Error('Token registry missing USDC or WHYPE on HyperEVM');
  }

  const plan = buildQuotePlan();
  const adapters = buildAdapters();
  const metricsWriter = new MetricsWriter({ metricsDir: path.resolve(process.cwd(), 'metrics/hype-metrics') });

  const adaptersWithSuccess: string[] = [];
  const adaptersFailures: Record<string, string[]> = {};
  let rows = 0;

  for (const adapter of adapters) {
    logger.info({ adapter: adapter.name() }, 'Starting adapter run');
    const supports = await adapter.supports(chain.chain_id);
    if (!supports) {
      adaptersFailures[adapter.name()] = ['chain_not_supported'];
      continue;
    }

    for (const direction of plan.directions) {
      for (const amountUsd of plan.amounts_usd) {
        const tokens = direction === 'USDC->HYPE' ? tokenIn : tokenOut;
        const counter = direction === 'USDC->HYPE' ? tokenOut : tokenIn;
        const amountIn = stableAmountIn(direction, amountUsd, tokens.decimals);
        const start = performance.now();
        let quote;
        try {
          quote = await adapter.quote({
            direction,
            amount_in_tokens: amountIn.tokens,
            amount_in_wei: amountIn.wei,
            chain_id: chain.chain_id,
            slippage_tolerance_bps: plan.slippage_tolerance_bps,
          });
        } catch (error) {
          const reason = (error as Error).message;
          quote = {
            amount_out_tokens: '0',
            amount_out_wei: 0n,
            route_summary: null,
            fee_bps: null,
            gas_estimate: null,
            sdk_or_api_version: null,
            latency_ms: performance.now() - start,
            docs_url: null,
            success: false,
            failure_reason: reason,
          };
        }

        const latency = quote.latency_ms ?? performance.now() - start;

        if (!quote.success) {
          adaptersFailures[adapter.name()] = adaptersFailures[adapter.name()] ?? [];
          adaptersFailures[adapter.name()].push(quote.failure_reason ?? 'unknown_failure');
        } else {
          if (!adaptersWithSuccess.includes(adapter.name())) {
            adaptersWithSuccess.push(adapter.name());
          }
        }

        metricsWriter.addRow(
          {
            run_id: runId,
            timestamp_iso: timestamp,
            dex: adapter.name(),
            integration_kind: adapter instanceof AggregatorAdapter ? 'aggregator_http' : 'dex_adapter',
            docs_url: quote.docs_url ?? null,
            chain_id: chain.chain_id,
            chain_name: chain.name,
            direction,
            token_in_symbol: tokens.symbol,
            token_in_address: tokens.address,
            decimals_in: tokens.decimals,
            token_out_symbol: counter.symbol,
            token_out_address: counter.address,
            decimals_out: counter.decimals,
            amount_in_tokens: amountIn.tokens,
            amount_in_usd: amountUsd,
            amount_out_tokens: quote.amount_out_tokens ?? null,
            amount_out_usd: null,
            mid_price_out_per_in: null,
            effective_price_in_per_out: null,
            effective_price_usd_per_out: null,
            price_impact_bps: null,
            fee_bps: quote.fee_bps,
            gas_estimate: quote.gas_estimate ? quote.gas_estimate.toString() : null,
            gas_price: null,
            gas_cost_native: null,
            native_usd: null,
            gas_cost_usd: null,
            route_summary: quote.route_summary,
            sdk_or_api_version: quote.sdk_or_api_version,
            quote_latency_ms: latency,
            success: quote.success,
            failure_reason: quote.failure_reason ?? null,
          },
          {
            run_id: runId,
            timestamp_iso: timestamp,
            adapter: adapter.name(),
            direction,
            amount_usd: amountUsd,
            request: {
              amount_in_tokens: amountIn.tokens,
              chain_id: chain.chain_id,
            },
            response: quote,
          }
        );
        rows += 1;
      }
    }
  }

  await metricsWriter.flush(runId);

  const summary: RunSummary = {
    run_id: runId,
    timestamp_iso: timestamp,
    rows_written: rows,
    adapters_attempted: adapters.length,
    adapters_with_success: adaptersWithSuccess,
    adapters_failed: adaptersFailures,
  };
  await logRun(summary);
  logger.info(summary, 'Run complete');
}
