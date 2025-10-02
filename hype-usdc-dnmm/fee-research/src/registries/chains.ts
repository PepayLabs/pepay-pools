import fs from 'fs/promises';
import path from 'path';
import { ChainConfig, ChainConfigSchema } from '../types.js';
import { logger } from '../utils/logger.js';

const CHAINS_PATH = path.resolve(process.cwd(), 'chains.json');

export async function loadChains(): Promise<ChainConfig[]> {
  const raw = await fs.readFile(CHAINS_PATH, 'utf-8');
  const json = JSON.parse(raw);
  const parsed = ChainConfigSchema.parse(json);
  return parsed;
}

export async function findChain(chainId: number): Promise<ChainConfig | undefined> {
  const chains = await loadChains();
  const chain = chains.find((c) => c.chain_id === chainId);
  if (!chain) {
    logger.warn({ chainId }, 'Chain not found in registry');
  }
  return chain;
}
