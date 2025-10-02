import fs from 'fs/promises';
import path from 'path';
import dayjs from 'dayjs';
import { TokenConfig, TokenConfigSchema } from '../types.js';
import { logger } from '../utils/logger.js';

const TOKENS_PATH = path.resolve(process.cwd(), 'tokens.json');

export async function loadTokens(): Promise<TokenConfig[]> {
  const raw = await fs.readFile(TOKENS_PATH, 'utf-8');
  const json = JSON.parse(raw);
  return TokenConfigSchema.parse(json);
}

export async function findToken(symbol: string, chainId: number): Promise<TokenConfig | null> {
  const tokens = await loadTokens();
  const token = tokens.find((t) => t.symbol === symbol && t.chain_id === chainId);
  if (!token) {
    logger.warn({ symbol, chainId }, 'Token not found');
    return null;
  }
  return token;
}

export async function upsertToken(entry: TokenConfig): Promise<void> {
  const tokens = await loadTokens();
  const existingIdx = tokens.findIndex((t) => t.symbol === entry.symbol && t.chain_id === entry.chain_id);
  const withUpdatedTimestamp = { ...entry, last_verified_at: dayjs().toISOString() };
  if (existingIdx >= 0) {
    tokens[existingIdx] = withUpdatedTimestamp;
  } else {
    tokens.push(withUpdatedTimestamp);
  }
  await fs.writeFile(TOKENS_PATH, JSON.stringify(tokens, null, 2));
}
