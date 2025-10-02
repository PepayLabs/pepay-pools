import fs from 'fs/promises';
import path from 'path';
import dayjs from 'dayjs';
import { DexDocsEntry, DexDocsSchema } from '../types.js';

const DOCS_PATH = path.resolve(process.cwd(), 'dex-docs.json');

export async function loadDexDocs(): Promise<DexDocsEntry[]> {
  const raw = await fs.readFile(DOCS_PATH, 'utf-8');
  const json = JSON.parse(raw);
  return DexDocsSchema.parse(json);
}

export async function upsertDexDoc(entry: DexDocsEntry): Promise<void> {
  const docs = await loadDexDocs();
  const idx = docs.findIndex((d) => d.name === entry.name);
  const withTimestamp = { ...entry, last_checked_at: dayjs().toISOString() };
  if (idx >= 0) {
    docs[idx] = withTimestamp;
  } else {
    docs.push(withTimestamp);
  }
  await fs.writeFile(DOCS_PATH, JSON.stringify(docs, null, 2));
}
