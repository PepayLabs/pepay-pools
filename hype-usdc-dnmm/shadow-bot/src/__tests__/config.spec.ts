import { beforeEach, afterEach, describe, expect, test, vi } from 'vitest';
import { loadConfig } from '../config.js';

const ORIGINAL_ENV = { ...process.env };

describe('config loader', () => {
  beforeEach(() => {
    vi.resetModules();
    process.env = { ...ORIGINAL_ENV };
  });

  afterEach(() => {
    process.env = { ...ORIGINAL_ENV };
  });

  test('defaults to mock mode when MODE not provided', async () => {
    delete process.env.MODE;
    delete process.env.RPC_URL;
    const config = await loadConfig();
    expect(config.mode).toBe('mock');
    expect(config.intervalMs).toBeGreaterThan(0);
    expect(config.sizeGrid.length).toBeGreaterThan(0);
  });

});
