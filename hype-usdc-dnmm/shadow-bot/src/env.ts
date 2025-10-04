import fs from 'fs';
import path from 'path';

export interface LoadEnvOptions {
  readonly cwd?: string;
  readonly envFile?: string;
  readonly override?: boolean;
}

const DEFAULT_FILES = ['.dnmmenv.local', '.dnmmenv'];

export function loadEnv(options: LoadEnvOptions = {}): Record<string, string> {
  const cwd = options.cwd ?? process.cwd();
  const targets = options.envFile ? [options.envFile] : DEFAULT_FILES;
  const parsed: Record<string, string> = {};

  for (const candidate of targets) {
    const filePath = path.resolve(cwd, candidate);
    if (!fs.existsSync(filePath)) continue;
    const fileContent = fs.readFileSync(filePath, 'utf8');
    const entries = parseEnvFile(fileContent);
    for (const [key, value] of Object.entries(entries)) {
      if (!options.override && process.env[key] !== undefined) continue;
      process.env[key] = value;
      parsed[key] = value;
    }
  }

  return parsed;
}

function parseEnvFile(contents: string): Record<string, string> {
  const result: Record<string, string> = {};
  const lines = contents.split(/\r?\n/);
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const equalsIndex = line.indexOf('=');
    if (equalsIndex === -1) continue;
    const key = line.slice(0, equalsIndex).trim();
    let value = line.slice(equalsIndex + 1).trim();
    if (!key) continue;
    if (value.startsWith('"') && value.endsWith('"')) {
      value = value.slice(1, -1).replace(/\\n/g, '\n').replace(/\\r/g, '\r');
    } else if (value.startsWith("'") && value.endsWith("'")) {
      value = value.slice(1, -1);
    }
    result[key] = value;
  }
  return result;
}
