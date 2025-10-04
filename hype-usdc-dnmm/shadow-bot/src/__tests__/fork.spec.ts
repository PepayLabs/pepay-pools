import { beforeEach, afterEach, describe, expect, test, vi } from 'vitest';
import os from 'os';
import path from 'path';
import { mkdtemp, rm, writeFile } from 'fs/promises';
import { loadConfig } from '../config.js';

const ORIGINAL_ENV = { ...process.env };

describe('fork mode config', () => {
  beforeEach(() => {
    vi.resetModules();
    process.env = { ...ORIGINAL_ENV };
  });

  afterEach(async () => {
    process.env = { ...ORIGINAL_ENV };
  });

  test('uses deploy output json overrides', async () => {
    const tmpDir = await mkdtemp(path.join(os.tmpdir(), 'fork-config-'));
    const jsonPath = path.join(tmpDir, 'deploy.json');
    const overrides = {
      chainId: 31337,
      poolAddress: '0x0000000000000000000000000000000000000Aaa',
      hypeAddress: '0x0000000000000000000000000000000000000Bbb',
      usdcAddress: '0x0000000000000000000000000000000000000Ccc',
      pythAddress: '0x0000000000000000000000000000000000000Ddd',
      hcPxPrecompile: '0x0000000000000000000000000000000000000Eee',
      hcBboPrecompile: '0x0000000000000000000000000000000000000Fff',
      hcPxKey: 111,
      hcBboKey: 222,
      baseDecimals: 18,
      quoteDecimals: 6
    };
    await writeFile(jsonPath, JSON.stringify(overrides), 'utf8');

    process.env.MODE = 'fork';
    process.env.RPC_URL = 'http://127.0.0.1:8545';
    process.env.FORK_DEPLOY_JSON = jsonPath;

    const config = await loadConfig();
    expect(config.mode).toBe('fork');
    expect(config.chainId).toBe(31337);
    expect(config.poolAddress).toBe(overrides.poolAddress);
    expect(config.baseTokenAddress).toBe(overrides.hypeAddress);
    expect(config.hcBboPrecompile).toBe(overrides.hcBboPrecompile);

    await rm(tmpDir, { recursive: true, force: true });
  });
});
