import fs from 'fs/promises';
import path from 'path';
import { stringify } from 'csv-stringify/sync';
import stringifyStable from 'fast-json-stable-stringify';
import dayjs from 'dayjs';
import { logger } from '../utils/logger.js';

export interface MetricsRow {
  run_id: string;
  timestamp_iso: string;
  dex: string;
  integration_kind: string;
  docs_url: string | null;
  chain_id: number;
  chain_name: string;
  direction: string;
  token_in_symbol: string;
  token_in_address: string;
  decimals_in: number;
  token_out_symbol: string;
  token_out_address: string;
  decimals_out: number;
  amount_in_tokens: string;
  amount_in_usd: number;
  amount_out_tokens: string | null;
  amount_out_usd: number | null;
  mid_price_out_per_in: number | null;
  effective_price_in_per_out: number | null;
  effective_price_usd_per_out: number | null;
  price_impact_bps: number | null;
  fee_bps: number | null;
  gas_estimate: string | null;
  gas_price: string | null;
  gas_cost_native: string | null;
  native_usd: number | null;
  gas_cost_usd: number | null;
  route_summary: string | null;
  sdk_or_api_version: string | null;
  quote_latency_ms: number;
  success: boolean;
  failure_reason: string | null;
}

interface WriterOptions {
  metricsDir: string;
}

export class MetricsWriter {
  private readonly rows: MetricsRow[] = [];
  private readonly jsonlRecords: Record<string, unknown>[] = [];
  private readonly metricsDir: string;

  constructor(options: WriterOptions) {
    this.metricsDir = options.metricsDir;
  }

  addRow(row: MetricsRow, raw: Record<string, unknown>): void {
    this.rows.push(row);
    this.jsonlRecords.push(sanitizeRecord(raw));
  }

  async flush(runId: string): Promise<void> {
    if (this.rows.length === 0) {
      logger.warn({ runId }, 'No metrics rows to flush');
      return;
    }
    await fs.mkdir(this.metricsDir, { recursive: true });
    const isoDate = dayjs().format('YYYY-MM-DD');
    const csvPath = path.join(this.metricsDir, `hype-usdc-quotes__${isoDate}__${runId}.csv`);
    const jsonlPath = path.join(this.metricsDir, `hype-usdc-quotes__${isoDate}__${runId}.jsonl`);

    const csv = stringify(this.rows, { header: true });
    await fs.writeFile(csvPath, csv, 'utf-8');

    const jsonl = this.jsonlRecords.map((r) => stringifyStable(r)).join('\n');
    await fs.writeFile(jsonlPath, jsonl + '\n', 'utf-8');

    logger.info({ csvPath, jsonlPath, rows: this.rows.length }, 'Metrics flushed');
  }
}

function sanitizeValue(value: unknown): unknown {
  if (typeof value === 'bigint') {
    return value.toString();
  }
  if (Array.isArray(value)) {
    return value.map((item) => sanitizeValue(item));
  }
  if (value && typeof value === 'object') {
    return sanitizeRecord(value as Record<string, unknown>);
  }
  return value;
}

function sanitizeRecord(record: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(record).map(([key, val]) => [key, sanitizeValue(val)])
  );
}
