import fs from 'fs/promises';
import path from 'path';
import { formatUnits } from 'ethers';
import { CsvRowInput, LoopArtifacts, ProbeQuote, ShadowBotConfig } from './types.js';

const HEADER = [
  'ts',
  'size_wad',
  'side',
  'ask_fee_bps',
  'bid_fee_bps',
  'total_bps',
  'clamp_flags',
  'risk_bits',
  'min_out_bps',
  'mid_hc',
  'mid_pyth',
  'conf_bps',
  'bbo_spread_bps',
  'success',
  'status_detail',
  'latency_ms'
].join(',');

interface CsvLogger {
  error(message: string, meta?: Record<string, unknown>): void;
  debug?(message: string, meta?: Record<string, unknown>): void;
}

async function ensureDir(directory: string): Promise<void> {
  await fs.mkdir(directory, { recursive: true });
}

function toDateKey(timestampMs: number): string {
  const date = new Date(timestampMs);
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, '0');
  const day = String(date.getUTCDate()).padStart(2, '0');
  return `${year}${month}${day}`;
}

function formatWad(value?: bigint): string {
  if (value === undefined) return '';
  return formatUnits(value, 18);
}

function formatClampFlags(flags: string[]): string {
  return flags.join('|');
}

function formatRiskBits(bits: string[]): string {
  return bits.join('|');
}

function formatRow(row: CsvRowInput): string {
  const askFee = row.probe.side === 'quote_in' ? row.probe.feeBps : '';
  const bidFee = row.probe.side === 'base_in' ? row.probe.feeBps : '';
  return [
    new Date(row.timestampMs).toISOString(),
    formatUnits(row.probe.sizeWad, 18),
    row.probe.side,
    askFee,
    bidFee,
    row.probe.totalBps,
    formatClampFlags(row.probe.clampFlags),
    formatRiskBits(row.probe.riskBits),
    row.probe.minOutBps,
    formatWad(row.midHc),
    formatWad(row.midPyth),
    row.pythConfBps ?? '',
    row.bboSpreadBps ?? '',
    row.probe.success ? '1' : '0',
    row.probe.statusDetail ?? row.probe.status,
    row.probe.latencyMs
  ].join(',');
}

export class CsvWriter {
  private currentFile?: string;
  private headerWritten = false;

  constructor(
    private readonly config: ShadowBotConfig,
    private readonly logger: CsvLogger = { error: () => {} }
  ) {}

  private async ensureHeaderState(filePath: string): Promise<void> {
    try {
      const existing = await fs.readFile(filePath, 'utf8');
      this.headerWritten = existing.startsWith(HEADER);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        this.headerWritten = false;
        return;
      }
      throw error;
    }
  }

  async appendRows(rows: CsvRowInput[]): Promise<void> {
    if (rows.length === 0) return;
    try {
      await ensureDir(this.config.csvDirectory);
      const dateKey = toDateKey(rows[0].timestampMs);
      const filePath = path.join(this.config.csvDirectory, `dnmm_shadow_${dateKey}.csv`);
      if (this.currentFile !== filePath) {
        this.currentFile = filePath;
        await this.ensureHeaderState(filePath);
      }

      const lines = rows.map(formatRow);
      const payload = `${this.headerWritten ? '' : `${HEADER}\n`}${lines.join('\n')}\n`;
      await fs.appendFile(filePath, payload, 'utf8');
      this.headerWritten = true;
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      this.logger.error('csv.append.failed', { detail });
    }
  }

  async writeSummary(summary: LoopArtifacts): Promise<void> {
    try {
      await ensureDir(path.dirname(this.config.jsonSummaryPath));
      await fs.writeFile(this.config.jsonSummaryPath, JSON.stringify(summary, (_key, value) => {
        if (typeof value === 'bigint') {
          return value.toString();
        }
        return value;
      }, 2));
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      this.logger.error('csv.summary.failed', { detail });
    }
  }
}

export function createCsvWriter(config: ShadowBotConfig, logger?: CsvLogger): CsvWriter {
  return new CsvWriter(config, logger);
}

export function buildCsvRows(probes: ProbeQuote[], timestampMs: number, meta: {
  midHc?: bigint;
  midPyth?: bigint;
  confBps?: number;
  spreadBps?: number;
}): CsvRowInput[] {
  return probes.map((probe) => ({
    timestampMs,
    probe,
    midHc: meta.midHc,
    midPyth: meta.midPyth,
    pythConfBps: meta.confBps,
    bboSpreadBps: meta.spreadBps
  }));
}
