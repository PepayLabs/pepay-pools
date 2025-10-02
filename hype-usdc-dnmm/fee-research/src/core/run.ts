import fs from 'fs/promises';
import path from 'path';
import dayjs from 'dayjs';
import { buildAdapters } from './adapters.js';
import { buildQuotePlan, newRunId } from './quotePlan.js';
import { findChain } from '../registries/chains.js';
import { findToken } from '../registries/tokens.js';
import { loadDexDocs } from '../registries/dexDocs.js';
import { logger } from '../utils/logger.js';
import { MetricsWriter } from './metricsWriter.js';
import { QuoteDirection } from '../types.js';
import { computeEffectivePriceInPerOut, computeEffectivePriceUsdPerOut, computePriceImpactBps } from '../utils/math.js';
import { ethers } from 'ethers';
import { performance } from 'perf_hooks';
import { createRateLimitedQueue } from '../utils/concurrency.js';

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

const USD_SCALE = 1_000_000n;

export function amountInForDirection(
  direction: QuoteDirection,
  usdNotional: number,
  decimals: number,
  midPriceOutPerIn: number | null
): { tokens: string; wei: bigint } {
  if (direction === 'USDC->HYPE') {
    const wei = BigInt(Math.floor(usdNotional * Number(USD_SCALE)));
    if (wei <= 0n) {
      throw new Error('Amount in wei computed as zero for USDC direction');
    }
    const tokens = ethers.formatUnits(wei, decimals);
    return { tokens, wei };
  }

  if (!midPriceOutPerIn || midPriceOutPerIn <= 0) {
    throw new Error('Missing mid price to convert USD to HYPE amount');
  }

  const usdMicro = BigInt(Math.floor(usdNotional * Number(USD_SCALE)));
  const priceScaled = BigInt(Math.floor(midPriceOutPerIn * Number(USD_SCALE)));
  if (priceScaled === 0n) {
    throw new Error('Mid price scaled resolved to zero');
  }

  const scale = 10n ** BigInt(decimals);
  const wei = (usdMicro * scale) / priceScaled;
  if (wei <= 0n) {
    throw new Error('Amount in wei computed as zero for HYPE direction');
  }
  const tokens = ethers.formatUnits(wei, decimals);
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
  const dexDocs = await loadDexDocs();
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

    const midCache: Record<QuoteDirection, number | null> = {
      'USDC->HYPE': null,
      'HYPE->USDC': null,
    };

    if (typeof adapter.midPrice === 'function') {
      for (const direction of ['USDC->HYPE', 'HYPE->USDC'] as QuoteDirection[]) {
        try {
          midCache[direction] = await adapter.midPrice(direction);
        } catch (error) {
          logger.warn({ adapter: adapter.name(), direction, error: (error as Error).message }, 'Failed to precompute mid price');
          midCache[direction] = null;
        }
      }
    }

    const enqueue = createRateLimitedQueue(6);
    const tasks: Promise<void>[] = [];

    for (const direction of plan.directions) {
      for (const amountUsd of plan.amounts_usd) {
        tasks.push(
          enqueue(async () => {
            const tokens = direction === 'USDC->HYPE' ? tokenIn : tokenOut;
            const counter = direction === 'USDC->HYPE' ? tokenOut : tokenIn;
            const integrationKind = adapter.integrationKind();
            let amountIn;
            try {
              const conversionMid = direction === 'HYPE->USDC' ? midCache['HYPE->USDC'] : midCache['USDC->HYPE'];
              amountIn = amountInForDirection(direction, amountUsd, tokens.decimals, conversionMid);
            } catch (error) {
              adaptersFailures[adapter.name()] = adaptersFailures[adapter.name()] ?? [];
              adaptersFailures[adapter.name()].push((error as Error).message);
              metricsWriter.addRow(
                {
                  run_id: runId,
                  timestamp_iso: timestamp,
                  dex: adapter.name(),
                  integration_kind: integrationKind,
                  docs_url: null,
                  chain_id: chain.chain_id,
                  chain_name: chain.name,
                  direction,
                  token_in_symbol: tokens.symbol,
                  token_in_address: tokens.address,
                  decimals_in: tokens.decimals,
                  token_out_symbol: counter.symbol,
                  token_out_address: counter.address,
                  decimals_out: counter.decimals,
                  amount_in_tokens: '0',
                  amount_in_usd: amountUsd,
                  amount_out_tokens: null,
                  amount_out_usd: null,
                  mid_price_out_per_in: null,
                  effective_price_in_per_out: null,
                  effective_price_usd_per_out: null,
                  price_impact_bps: null,
                  fee_bps: null,
                  gas_estimate: null,
                  gas_price: null,
                  gas_cost_native: null,
                  native_usd: null,
                  gas_cost_usd: null,
                  route_summary: null,
                  sdk_or_api_version: null,
                  quote_latency_ms: 0,
                  success: false,
                  failure_reason: (error as Error).message,
                },
                {
                  run_id: runId,
                  timestamp_iso: timestamp,
                  adapter: adapter.name(),
                  direction,
                  amount_usd: amountUsd,
                  request: null,
                  response: { error: (error as Error).message },
                }
              );
              rows += 1;
              return;
            }

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
                mid_price_out_per_in: midCache[direction],
              };
            }

            const latency = quote.latency_ms ?? performance.now() - start;

            const amountInTokensNumber = parseFloat(amountIn.tokens);
            const amountOutTokensNumber = quote.success && quote.amount_out_tokens
              ? parseFloat(quote.amount_out_tokens)
              : 0;
            const directionMid = quote.mid_price_out_per_in ?? midCache[direction];
            const idealOutAtMid = directionMid && quote.success ? amountInTokensNumber * directionMid : null;
            const priceImpact = directionMid && quote.success && idealOutAtMid
              ? computePriceImpactBps({
                  amountInTokens: amountInTokensNumber,
                  amountOutTokens: amountOutTokensNumber,
                  idealOutTokens: idealOutAtMid,
                })
              : null;
            const effectivePrice = quote.success
              ? computeEffectivePriceInPerOut(amountInTokensNumber, amountOutTokensNumber)
              : null;
            const effectiveUsdPrice = quote.success
              ? computeEffectivePriceUsdPerOut(amountUsd, 0, amountOutTokensNumber)
              : null;
            let amountOutUsd: number | null = null;
            if (quote.success) {
              if (direction === 'USDC->HYPE') {
                const hypeUsd = midCache['HYPE->USDC'];
                amountOutUsd = hypeUsd ? amountOutTokensNumber * hypeUsd : null;
              } else {
                amountOutUsd = amountOutTokensNumber;
              }
            }

            if (!quote.success) {
              adaptersFailures[adapter.name()] = adaptersFailures[adapter.name()] ?? [];
              adaptersFailures[adapter.name()].push(quote.failure_reason ?? 'unknown_failure');
            } else if (!adaptersWithSuccess.includes(adapter.name())) {
              adaptersWithSuccess.push(adapter.name());
            }

            metricsWriter.addRow(
              {
                run_id: runId,
                timestamp_iso: timestamp,
                dex: adapter.name(),
                integration_kind: integrationKind,
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
                amount_out_tokens: quote.success ? quote.amount_out_tokens : null,
                amount_out_usd: amountOutUsd,
                mid_price_out_per_in: directionMid ?? null,
                effective_price_in_per_out: effectivePrice,
                effective_price_usd_per_out: effectiveUsdPrice,
                price_impact_bps: priceImpact,
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

        if (quote.success && quote.legs && quote.legs.length > 0) {
          for (const leg of quote.legs) {
            const portion = Number(leg.portion);
            const portionSafe = Number.isFinite(portion) ? Math.max(portion, 0) : 0;
            const legDocs = dexDocs.find((d) => d.name.toLowerCase() === leg.dex.toLowerCase());
            const legDocsUrl = legDocs?.official_docs_url ?? legDocs?.http_quote_base_url ?? null;
            const amountInTokensLeg = amountInTokensNumber * portionSafe;
            const amountInUsdLeg = amountUsd * portionSafe;
            const amountOutTokensLeg = parseFloat(leg.amount_out_tokens);
            const effectivePriceLeg = amountOutTokensLeg > 0 ? amountInTokensLeg / amountOutTokensLeg : null;
            const effectiveUsdPriceLeg = amountOutTokensLeg > 0 ? amountInUsdLeg / amountOutTokensLeg : null;
            const priceImpactLeg = directionMid && amountOutTokensLeg > 0
              ? computePriceImpactBps({
                  amountInTokens: amountInTokensLeg,
                  amountOutTokens: amountOutTokensLeg,
                  idealOutTokens: amountInTokensLeg * directionMid,
                })
              : null;

            metricsWriter.addRow(
              {
                run_id: runId,
                timestamp_iso: timestamp,
                dex: leg.dex,
                integration_kind: 'dex_via_hypertrade',
                docs_url: legDocsUrl,
                chain_id: chain.chain_id,
                chain_name: chain.name,
                direction,
                token_in_symbol: tokens.symbol,
                token_in_address: tokens.address,
                decimals_in: tokens.decimals,
                token_out_symbol: counter.symbol,
                token_out_address: counter.address,
                decimals_out: counter.decimals,
                amount_in_tokens: amountInTokensLeg.toString(),
                amount_in_usd: amountInUsdLeg,
                amount_out_tokens: leg.amount_out_tokens,
                amount_out_usd: null,
                mid_price_out_per_in: directionMid ?? null,
                effective_price_in_per_out: effectivePriceLeg,
                effective_price_usd_per_out: effectiveUsdPriceLeg,
                price_impact_bps: priceImpactLeg,
                fee_bps: leg.fee_bps,
                gas_estimate: null,
                gas_price: null,
                gas_cost_native: null,
                native_usd: null,
                gas_cost_usd: null,
                route_summary: leg.pool_address ? `${leg.dex} pool ${leg.pool_address}` : leg.dex,
                sdk_or_api_version: quote.sdk_or_api_version,
                quote_latency_ms: latency,
                success: true,
                failure_reason: null,
              },
              {
                run_id: runId,
                timestamp_iso: timestamp,
                adapter: leg.dex,
                direction,
                amount_usd: amountInUsdLeg,
                leg,
              }
            );
            rows += 1;
          }
        }
      })
    );
  }
    }

    await Promise.all(tasks);
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
