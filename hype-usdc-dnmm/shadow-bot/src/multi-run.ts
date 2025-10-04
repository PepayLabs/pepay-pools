import 'dotenv/config';
import { loadMultiRunConfig } from './config-multi.js';
import { runMultiSettings } from './runner/multiSettings.js';

async function main(): Promise<void> {
  const config = await loadMultiRunConfig();
  const result = await runMultiSettings(config);
  console.log(
    JSON.stringify({
      ts: new Date().toISOString(),
      level: 'info',
      msg: 'shadowbot.multi.completed',
      run_id: config.runId,
      settings: config.runs.length,
      scoreboard_rows: result.scoreboard.length
    })
  );
}

main().catch((error) => {
  const detail = error instanceof Error ? error.stack ?? error.message : String(error);
  console.error(
    JSON.stringify({
      ts: new Date().toISOString(),
      level: 'error',
      msg: 'shadowbot.multi.failed',
      detail
    })
  );
  process.exit(1);
});
