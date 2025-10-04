import 'dotenv/config';
import { loadConfig } from './config.js';
import { runMultiSettings } from './runner/multiSettings.js';

async function main(): Promise<void> {
  const config = await loadConfig();
  const result = await runMultiSettings(config);
  console.log(
    JSON.stringify({
      ts: new Date().toISOString(),
      level: 'info',
      msg: 'shadowbot.completed',
      scoreboard_rows: result.scoreboard.length
    })
  );
}

main().catch((error) => {
  const detail = error instanceof Error ? error.stack ?? error.message : String(error);
  console.error(
    JSON.stringify({ ts: new Date().toISOString(), level: 'error', msg: 'shadowbot.failed', detail })
  );
  process.exit(1);
});
