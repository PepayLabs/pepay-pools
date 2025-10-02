import { config } from 'dotenv';
import path from 'path';

const cwdEnvPath = path.resolve(process.cwd(), '.env');
config({ path: cwdEnvPath, override: false });

export function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

export function optionalEnv(name: string): string | null {
  const value = process.env[name];
  return value === undefined ? null : value;
}
