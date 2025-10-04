import fs from 'fs/promises';
import path from 'path';
import { MultiRunRuntimeConfig, QuoteCsvRecord, ScoreboardRow, TradeCsvRecord } from '../types.js';

const TRADE_HEADER = [
  'ts_iso',
  'setting_id',
  'benchmark',
  'side',
  'intent_size',
  'applied_size',
  'is_partial',
  'amount_in',
  'amount_out',
  'fee_paid',
  'fee_lvr_paid',
  'rebate_paid',
  'fee_bps_used',
  'fee_lvr_bps',
  'rebate_bps',
  'floor_enforced',
  'aomq_used',
  'success',
  'min_out',
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
  'mid',
  'spread_bps',
  'conf_bps',
  'fee_bps',
  'fee_lvr_bps',
  'floor_bps',
  'aomq_flags',
  'rebate_bps',
  'ttl_ms',
  'min_out'
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

export interface MultiCsvWriter {
  init(): Promise<void>;
  appendTrades(records: readonly TradeCsvRecord[]): Promise<void>;
  appendQuotes(records: readonly QuoteCsvRecord[]): Promise<void>;
  writeScoreboard(rows: readonly ScoreboardRow[]): Promise<void>;
  close(): Promise<void>;
}

export function createMultiCsvWriter(config: MultiRunRuntimeConfig): MultiCsvWriter {
  const headerCache = new Set<string>();
  const tradesDir = config.paths.tradesDir;
  const quotesDir = config.paths.quotesDir;
  const scoreboardPath = config.paths.scoreboardPath;
  const persist = config.persistCsv;

  return {
    async init(): Promise<void> {
      if (!persist) return;
      await fs.mkdir(tradesDir, { recursive: true });
      await fs.mkdir(quotesDir, { recursive: true });
    },
    async appendTrades(records: readonly TradeCsvRecord[]): Promise<void> {
      if (!persist || records.length === 0) return;
      await Promise.all(
        records.map((record) =>
          appendRow(tradesDir, record.settingId, record.benchmark, TRADE_HEADER, tradeRow(record), headerCache)
        )
      );
    },
    async appendQuotes(records: readonly QuoteCsvRecord[]): Promise<void> {
      if (!persist || records.length === 0) return;
      await Promise.all(
        records.map((record) =>
          appendRow(quotesDir, record.settingId, record.benchmark, QUOTE_HEADER, quoteRow(record), headerCache)
        )
      );
    },
    async writeScoreboard(rows: readonly ScoreboardRow[]): Promise<void> {
      const content = [SCOREBOARD_HEADER.join(','), ...rows.map(scoreboardRow)].join('\n');
      await fs.mkdir(path.dirname(scoreboardPath), { recursive: true });
      await fs.writeFile(scoreboardPath, `${content}\n`, 'utf8');
    },
    async close(): Promise<void> {
      // no resources to release
    }
  };
}

async function appendRow(
  directory: string,
  settingId: string,
  benchmark: string,
  header: readonly string[],
  row: string,
  cache: Set<string>
): Promise<void> {
  const filePath = path.join(directory, `${settingId}_${benchmark}.csv`);
  if (!cache.has(filePath)) {
    await fs.mkdir(path.dirname(filePath), { recursive: true });
    await fs.writeFile(filePath, `${header.join(',')}\n`, { flag: 'w' });
    cache.add(filePath);
  }
  await fs.appendFile(filePath, `${row}\n`);
}

function tradeRow(record: TradeCsvRecord): string {
  const formatBool = (value: boolean | undefined): string =>
    value === undefined ? '' : value ? 'true' : 'false';
  return [
    record.tsIso,
    record.settingId,
    record.benchmark,
    record.side,
    record.intentSize ?? '',
    record.appliedSize ?? '',
    formatBool(record.isPartial),
    record.amountIn,
    record.amountOut,
    record.feePaid ?? '',
    record.feeLvrPaid ?? '',
    record.rebatePaid ?? '',
    String(record.feeBpsUsed),
    record.feeLvrBps !== undefined ? String(record.feeLvrBps) : '',
    record.rebateBps !== undefined ? String(record.rebateBps) : '',
    formatBool(record.floorEnforced ?? (record.floorBps !== undefined && record.floorBps > 0)),
    formatBool(record.aomqUsed ?? record.aomqClamped),
    formatBool(record.success),
    record.minOut ?? '',
    record.slippageBpsVsMid.toFixed(6),
    record.pnlQuote.toFixed(6),
    record.inventoryBase,
    record.inventoryQuote
  ].join(',');
}

function quoteRow(record: QuoteCsvRecord): string {
  const aomqFlags = record.aomqFlags ?? (record.aomqActive ? 'active' : '');
  return [
    record.tsIso,
    record.settingId,
    record.benchmark,
    record.side,
    record.sizeBaseWad,
    record.mid,
    String(record.spreadBps),
    record.confBps !== undefined ? String(record.confBps) : '',
    String(record.feeBps),
    record.feeLvrBps !== undefined ? String(record.feeLvrBps) : '',
    record.floorBps !== undefined ? String(record.floorBps) : '',
    aomqFlags,
    record.rebateBps !== undefined ? String(record.rebateBps) : '',
    record.ttlMs !== undefined ? String(record.ttlMs) : '',
    record.minOut ?? ''
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
