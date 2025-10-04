import fs from 'fs/promises';
import path from 'path';
import {
  MultiRunRuntimeConfig,
  QuoteCsvRecord,
  ScoreboardRow,
  TradeCsvRecord
} from './types.js';

const TRADE_HEADER = [
  'ts_iso',
  'setting_id',
  'benchmark',
  'side',
  'amount_in',
  'amount_out',
  'mid_used',
  'fee_bps_used',
  'floor_bps',
  'tilt_bps',
  'aomq_clamped',
  'minOut',
  'slippage_bps_vs_mid',
  'pnl_quote',
  'inventory_base',
  'inventory_quote'
];

const QUOTE_HEADER = [
  'ts_iso',
  'setting_id',
  'benchmark',
  'side',
  'size_base_wad',
  'fee_bps',
  'mid',
  'spread_bps',
  'conf_bps',
  'aomq_active'
];

const SCOREBOARD_HEADER = [
  'setting_id',
  'benchmark',
  'trades',
  'pnl_quote_total',
  'pnl_per_mm_notional_bps',
  'win_rate_pct',
  'avg_fee_bps',
  'avg_slippage_bps',
  'two_sided_uptime_pct',
  'reject_rate_pct',
  'aomq_clamps_total',
  'recenter_commits_total'
];

export class CsvWriter {
  private readonly tradesDir: string;
  private readonly quotesDir: string;
  private readonly scoreboardPath: string;
  private readonly persist: boolean;
  private readonly headerCache = new Set<string>();

  constructor(config: MultiRunRuntimeConfig) {
    this.tradesDir = config.paths.tradesDir;
    this.quotesDir = config.paths.quotesDir;
    this.scoreboardPath = config.paths.scoreboardPath;
    this.persist = config.persistCsv;
  }

  async init(): Promise<void> {
    if (!this.persist) return;
    await fs.mkdir(this.tradesDir, { recursive: true });
    await fs.mkdir(this.quotesDir, { recursive: true });
  }

  async appendTrades(records: readonly TradeCsvRecord[]): Promise<void> {
    if (!this.persist || records.length === 0) return;
    await Promise.all(records.map((record) => this.appendRow(this.tradesDir, record.settingId, record.benchmark, TRADE_HEADER, tradeRow(record))));
  }

  async appendQuotes(records: readonly QuoteCsvRecord[]): Promise<void> {
    if (!this.persist || records.length === 0) return;
    await Promise.all(records.map((record) => this.appendRow(this.quotesDir, record.settingId, record.benchmark, QUOTE_HEADER, quoteRow(record))));
  }

  async writeScoreboard(rows: readonly ScoreboardRow[]): Promise<void> {
    const content = [SCOREBOARD_HEADER.join(','), ...rows.map(scoreboardRow)].join('\n');
    await fs.mkdir(path.dirname(this.scoreboardPath), { recursive: true });
    await fs.writeFile(this.scoreboardPath, `${content}\n`, 'utf8');
  }

  async close(): Promise<void> {
    // no file handles to clean up
  }

  private async appendRow(
    directory: string,
    settingId: string,
    benchmark: string,
    header: readonly string[],
    row: string
  ): Promise<void> {
    const filePath = path.join(directory, `${settingId}_${benchmark}.csv`);
    if (!this.headerCache.has(filePath)) {
      await fs.mkdir(path.dirname(filePath), { recursive: true });
      await fs.appendFile(filePath, `${header.join(',')}\n`);
      this.headerCache.add(filePath);
    }
    await fs.appendFile(filePath, `${row}\n`);
  }
}

function tradeRow(record: TradeCsvRecord): string {
  return [
    record.tsIso,
    record.settingId,
    record.benchmark,
    record.side,
    record.amountIn,
    record.amountOut,
    record.midUsed,
    String(record.feeBpsUsed),
    record.floorBps !== undefined ? String(record.floorBps) : '',
    record.tiltBps !== undefined ? String(record.tiltBps) : '',
    record.aomqClamped ? 'true' : 'false',
    record.minOut ?? '',
    record.slippageBpsVsMid.toFixed(6),
    record.pnlQuote.toFixed(6),
    record.inventoryBase,
    record.inventoryQuote
  ].join(',');
}

function quoteRow(record: QuoteCsvRecord): string {
  return [
    record.tsIso,
    record.settingId,
    record.benchmark,
    record.side,
    record.sizeBaseWad,
    String(record.feeBps),
    record.mid,
    String(record.spreadBps),
    record.confBps !== undefined ? String(record.confBps) : '',
    record.aomqActive ? 'true' : 'false'
  ].join(',');
}

function scoreboardRow(row: ScoreboardRow): string {
  return [
    row.settingId,
    row.benchmark,
    String(row.trades),
    row.pnlQuoteTotal.toFixed(6),
    row.pnlPerMmNotionalBps.toFixed(6),
    row.winRatePct.toFixed(4),
    row.avgFeeBps.toFixed(4),
    row.avgSlippageBps.toFixed(4),
    row.twoSidedUptimePct.toFixed(4),
    row.rejectRatePct.toFixed(4),
    String(row.aomqClampsTotal),
    String(row.recenterCommitsTotal)
  ].join(',');
}

export function createCsvWriter(config: MultiRunRuntimeConfig): CsvWriter {
  return new CsvWriter(config);
}
