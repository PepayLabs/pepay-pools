---
title: "DNMM A-Z Fork Runbook"
version: "1.0.0"
last_updated: "2025-10-07"
---

## Purpose
Guided procedure for compiling contracts, forking mainnet with Anvil, deploying DNMM pool + RFQ adapters, seeding the shadow bot configuration, and executing both the single-run and multi-run harnesses with guardrails.

## Audience & Prerequisites
- Operators and oncall engineers executing fork rehearsals or dry runs.
- Local toolchain with Foundry, Node.js 20+, `jq`, and Grafana access for dashboard validation.
- Read `ARCHITECTURE.md` (system layout) and `CONFIG_GUIDE.md` (env precedence) before running.

## Environment Inputs
Name | Default / Example | Notes
--- | --- | ---
`FORK_RPC_URL` | _(required)_ | HyperEVM endpoint used by Anvil fork.
`ANVIL_PORT` | `8545` | Override if port is busy; keep consistent with `.dnmmenv`.
`CHAIN_ID` | `1337` | Local fork chain id; mirrors Foundry default.
`PROM_PORT` | `9464` | Prometheus exporter for both runs.
`RUN_ID` | `${ISO_UTC_NOW}` | Timestamp slug for metrics (`run_<RUN_ID>`).
`CSV_ROOT` | `metrics/hype-metrics` | Root folder for exported CSVs.
`BOT_DIR` | `shadow-bot` | Relative path to the TypeScript harness.
`DEPLOY_OUT` | `deployments/fork.deploy.json` | Captures full `forge script` output.
`ADDRESS_BOOK` | `shadow-bot/address-book.json` | Downstream consumers look up pool + token metadata here.
`DNMM_POOL_LABEL` | `DnmPool` | Contract label emitted by the deploy script.
`QUOTE_RFQ_LABEL` | `QuoteRFQ` | Secondary contract label emitted by the deploy script.

> Tip: export variables in your shell session before starting (`export FORK_RPC_URL=...`).

## Preflight Checks
Command | Purpose
--- | ---
`forge --version` | Verifies Foundry install and toolchain hash before build.
`node -v && npm -v` | Confirms Node.js and npm versions match `package.json` expectations.
`jq --version` | Ensures JSON parsing utilities are available for template fills.

## Execution Flow
Follow the steps in order. Commands are copy-pastable; substitute environment values as required.

1. **Compile Contracts**
   ```bash
   forge build
   ```

2. **Start Forked Anvil (separate terminal or tmux pane)**
   ```bash
   anvil --fork-url "$FORK_RPC_URL" --port "${ANVIL_PORT:-8545}" --chain-id "${CHAIN_ID:-1337}"
   ```
   Wait until Anvil logs `Listening on 127.0.0.1`. Keep the process running for subsequent steps.

3. **Deploy Contracts to Fork**
   ```bash
   forge script script/Deploy.s.sol:Deploy \
     --rpc-url "http://127.0.0.1:${ANVIL_PORT:-8545}" \
     --broadcast \
     --json | tee "${DEPLOY_OUT:-deployments/fork.deploy.json}"
   ```
   - Timeout: 600s. Review stderr for reverted transactions.

4. **Extract Pool + RFQ Addresses for the Bot**
   ```bash
   jq -r '{
     pool: (.transactions[]? | select(.contractName=="'"${DNMM_POOL_LABEL:-DnmPool}"'") | .contractAddress),
     rfq: (.transactions[]? | select(.contractName=="'"${QUOTE_RFQ_LABEL:-QuoteRFQ}"'") | .contractAddress)
   }' "${DEPLOY_OUT:-deployments/fork.deploy.json}" > "${BOT_DIR:-shadow-bot}/fork.deploy.json"
   ```

5. **Write Shadow Bot Address Book**
   ```bash
   cat <<'JSON' > "${ADDRESS_BOOK:-shadow-bot/address-book.json}"
   {
     "defaultChainId": ${CHAIN_ID:-1337},
     "deployments": {
       "fork": {
         "chainId": ${CHAIN_ID:-1337},
         "poolAddress": "$(jq -r '.pool' "${BOT_DIR:-shadow-bot}/fork.deploy.json")",
         "baseToken": "$(jq -r '.baseToken' "${DEPLOY_OUT:-deployments/fork.deploy.json}")",
         "quoteToken": "$(jq -r '.quoteToken' "${DEPLOY_OUT:-deployments/fork.deploy.json}")",
         "pyth": "$(jq -r '.pyth' "${DEPLOY_OUT:-deployments/fork.deploy.json}")",
         "hcPx": "0x0000000000000000000000000000000000000807",
         "hcBbo": "0x000000000000000000000000000000000000080e",
         "hcSizeDecimals": 2
       }
     }
   }
   JSON
   ```
   - HyperCore precompile addresses align with governance defaults; update only if infra changes.

6. **Create `.dnmmenv` for Fork Mode**
   ```bash
   cat <<'ENV' > "${BOT_DIR:-shadow-bot}/.dnmmenv"
   MODE=fork
   RPC_URL=http://127.0.0.1:${ANVIL_PORT:-8545}
   PROM_PORT=${PROM_PORT:-9464}
   SETTINGS_FILE=settings/hype_settings.json
   FORK_DEPLOY_JSON=fork.deploy.json
   LOG_LEVEL=info
   INTERVAL_MS=5000
   ENV
   ```
   - Precedence follows `CONFIG_GUIDE.md`: `.dnmmenv.local` > `.dnmmenv` > exported vars.

7. **Install Dependencies**
   ```bash
   (cd "${BOT_DIR:-shadow-bot}" && npm ci)
   ```

8. **Build Shadow Bot**
   ```bash
   (cd "${BOT_DIR:-shadow-bot}" && npm run build)
   ```

9. **Run Legacy Single-Mode Bot (Quick Sanity)**
   ```bash
   (cd "${BOT_DIR:-shadow-bot}" && node dist/shadow-bot.js)
   ```
   - Timeout: 90s. Visit `http://127.0.0.1:${PROM_PORT:-9464}/metrics` to confirm `dnmm_*` series.

10. **Run Multi-Setting Harness**
    ```bash
    (cd "${BOT_DIR:-shadow-bot}" && node dist/multi-run.js \
      --settings settings/hype_settings.json \
      --run-id "${RUN_ID}" \
      --benchmarks dnmm,cpmm,stableswap \
      --max-parallel 3 \
      --duration-sec 15 \
      --prom-port "${PROM_PORT:-9464}")
    ```
    - Timeout: 180s. Metric labels must include `{run_id, setting_id, benchmark, pair}` per `MULTI_RUN_PIPELINE.md`.

11. **Assert CSV Outputs**
    ```bash
    test -s "${BOT_DIR:-shadow-bot}/${CSV_ROOT:-metrics/hype-metrics}/run_${RUN_ID}/scoreboard.csv"
    test -s "${BOT_DIR:-shadow-bot}/${CSV_ROOT:-metrics/hype-metrics}/run_${RUN_ID}/quotes"/*_dnmm.csv
    test -s "${BOT_DIR:-shadow-bot}/${CSV_ROOT:-metrics/hype-metrics}/run_${RUN_ID}/trades"/*_dnmm.csv
    ```

12. **Scrape Metrics Snapshot**
    ```bash
    curl -s "http://127.0.0.1:${PROM_PORT:-9464}/metrics" | tee /tmp/metrics.out
    ```

## Quality Gates
Gate | Check | Failure Message
--- | --- | ---
`preview-freshness` | `dnmm_snapshot_age_sec{...}` value in `/tmp/metrics.out` is `0.x` or `1.x`. | "Preview snapshot age not within expected 0-1s window."
`uptime` | `shadow_uptime_two_sided_pct{...}` equals `99.x`. | "Two-sided uptime under 99% in short run; inspect floors/AOMQ."
- Rerun offending benchmark if either gate fails. Review `metrics/hype-metrics/run_${RUN_ID}` CSVs plus `docs/OBSERVABILITY.md` alert guidance.

## Artifacts to Archive
- `${BOT_DIR}/${CSV_ROOT}/run_${RUN_ID}` (quotes, trades, scoreboard, Prometheus scrape).
- `${DEPLOY_OUT}` (raw deploy transcript).
- `${BOT_DIR}/fork.deploy.json` (contract addresses consumed by the bot).
- `${ADDRESS_BOOK}` (resolved addresses for other tools).

## Rollback / Cleanup
- Stop Anvil: `pkill -f 'anvil --fork-url' || true`.
- Remove temporary metrics if needed: `rm -rf ${BOT_DIR}/${CSV_ROOT}/run_${RUN_ID}` (only after copying to long-term storage).

## Cross-References
- `CONFIG_GUIDE.md` - environment precedence, `.dnmmenv` schema.
- `MULTI_RUN_PIPELINE.md` - runtime expectations, label semantics.
- `DASHBOARDS.md` - Grafana overlays for `dnmm_*` vs `shadow_*` series.
- `OBSERVABILITY.md` - KPI thresholds referenced by the gates above.

## Assumptions
- Metrics TTL: preview snapshots must stay within 0-1 s (`preview_max_age_sec = 1`).
- Aggregator rebates remain 3 bps fixed and accounted for post-cap; no additional tuning required in fork rehearsals.
- Sample duration (`--duration-sec 15`) is sufficient for smoke tests; expand for deep analysis per `RISK_SCENARIOS.md`.
