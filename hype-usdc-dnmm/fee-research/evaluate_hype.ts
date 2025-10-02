/* AUTO-DOCS: Do not edit by hand. Sources and SDKs recorded from dex-docs.json at 2025-10-02T12:00:00.000Z. */

import { runEvaluation } from './src/core/run.js';
import { logger } from './src/utils/logger.js';

async function main() {
  try {
    await runEvaluation();
  } catch (error) {
    logger.error({ error }, 'HYPE evaluation failed');
    process.exitCode = 1;
  }
}

void main();
