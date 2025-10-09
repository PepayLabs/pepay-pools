#!/usr/bin/env bash
# DNMM A-Z Fork Orchestration Script
# Builds contracts, launches an Anvil fork, deploys DNMM pool + RFQ, seeds the shadow bot,
# executes both the legacy single-run and multi-run harnesses, and validates observability gates.

set -euo pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

log() {
  printf "%b[%s]%b %s\n" "$BLUE" "$(date -u +%H:%M:%S)" "$RESET" "$1"
}

warn() {
  printf "%b[%s]%b %s\n" "$YELLOW" "$(date -u +%H:%M:%S)" "$RESET" "$1"
}

fail() {
  printf "%b[%s]%b %s\n" "$RED" "$(date -u +%H:%M:%S)" "$RESET" "$1" >&2
  exit 1
}

# Resolve directories
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SHADOW_BOT_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
PROJECT_ROOT=$(cd "${SHADOW_BOT_ROOT}/.." && pwd)

cd "$PROJECT_ROOT"

# Environment & defaults
: "${FORK_RPC_URL:?FORK_RPC_URL must be set (e.g. https://mainnet-hyperevm.example)}"
ANVIL_PORT=${ANVIL_PORT:-8545}
CHAIN_ID=${CHAIN_ID:-1337}
PROM_PORT=${PROM_PORT:-9464}
RUN_ID_DEFAULT=$(date -u +%Y%m%dT%H%M%SZ)
RUN_ID=${RUN_ID:-$RUN_ID_DEFAULT}
RUN_ID=${RUN_ID//[^A-Za-z0-9_.-]/-}
CSV_ROOT=${CSV_ROOT:-metrics/hype-metrics}
BOT_DIR=${BOT_DIR:-shadow-bot}
DEPLOY_OUT=${DEPLOY_OUT:-deployments/fork.deploy.json}
ADDRESS_BOOK=${ADDRESS_BOOK:-shadow-bot/address-book.json}
DNMM_POOL_LABEL=${DNMM_POOL_LABEL:-DnmPool}
QUOTE_RFQ_LABEL=${QUOTE_RFQ_LABEL:-QuoteRFQ}
SETTINGS_FILE=${SETTINGS_FILE:-settings/hype_settings.json}
LOG_LEVEL=${LOG_LEVEL:-info}
ANVIL_START_TIMEOUT=${ANVIL_START_TIMEOUT:-30}
SINGLE_RUN_TIMEOUT=${SINGLE_RUN_TIMEOUT:-90}
MULTI_RUN_TIMEOUT=${MULTI_RUN_TIMEOUT:-180}

# Required deploy inputs
: "${DNMM_BASE_TOKEN:?DNMM_BASE_TOKEN must be exported for Deploy.s.sol}"
: "${DNMM_QUOTE_TOKEN:?DNMM_QUOTE_TOKEN must be exported for Deploy.s.sol}"
: "${DNMM_BASE_DECIMALS:?DNMM_BASE_DECIMALS must be exported for Deploy.s.sol}"
: "${DNMM_QUOTE_DECIMALS:?DNMM_QUOTE_DECIMALS must be exported for Deploy.s.sol}"
: "${DNMM_PYTH_CONTRACT:?DNMM_PYTH_CONTRACT must be exported for Deploy.s.sol}"
: "${DNMM_PYTH_PRICE_ID_HYPE_USD:?DNMM_PYTH_PRICE_ID_HYPE_USD must be exported for Deploy.s.sol}"
: "${DNMM_PYTH_PRICE_ID_USDC_USD:?DNMM_PYTH_PRICE_ID_USDC_USD must be exported for Deploy.s.sol}"

# Derived paths
DEPLOY_OUT_PATH="${PROJECT_ROOT}/${DEPLOY_OUT}"
DEPLOY_OUT_DIR=$(dirname "$DEPLOY_OUT_PATH")
BOT_PATH="${PROJECT_ROOT}/${BOT_DIR}"
ADDRESS_BOOK_PATH="${PROJECT_ROOT}/${ADDRESS_BOOK}"
CSV_PATH="${BOT_PATH}/${CSV_ROOT}"
FORK_DEPLOY_PATH="${BOT_PATH}/fork.deploy.json"
ANVIL_LOG=${ANVIL_LOG:-/tmp/anvil.log}
ANVIL_PID_FILE=${ANVIL_PID_FILE:-/tmp/anvil.pid}
METRICS_SNAPSHOT=${METRICS_SNAPSHOT:-/tmp/metrics.out}

: > "$ANVIL_LOG"

mkdir -p "$DEPLOY_OUT_DIR"
mkdir -p "$(dirname "$ADDRESS_BOOK_PATH")"
[[ -d "$BOT_PATH" ]] || fail "BOT_DIR path not found: $BOT_PATH"
mkdir -p "$CSV_PATH"

cleanup() {
  local status=$?
  local pid=""
  if [[ -f "$ANVIL_PID_FILE" ]]; then
    pid=$(cat "$ANVIL_PID_FILE" 2>/dev/null || true)
  elif [[ -n "${ANVIL_PID:-}" ]]; then
    pid=$ANVIL_PID
  fi
  if [[ -n "$pid" ]]; then
    if kill -0 "$pid" >/dev/null 2>&1; then
      warn "Stopping Anvil (pid ${pid})"
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$ANVIL_LOG" "$METRICS_SNAPSHOT" "$ANVIL_PID_FILE"
  if [[ $status -eq 0 ]]; then
    log "Completed successfully"
  else
    printf "%b[%s]%b Script failed with status %s\n" "$RED" "$(date -u +%H:%M:%S)" "$RESET" "$status" >&2
  fi
}
trap cleanup EXIT

ANVIL_PID=""

log "(0/12) Preflight toolchain"
for tool in forge anvil node npm jq curl; do
  command -v "$tool" >/dev/null || fail "$tool not found on PATH"
done
if ! command -v timeout >/dev/null; then
  warn "timeout not found on PATH; runs will not be forcibly stopped at ${SINGLE_RUN_TIMEOUT}/${MULTI_RUN_TIMEOUT}s"
fi

log "Preflight: forge --version"
forge --version
log "Preflight: node -v && npm -v"
node -v && npm -v
log "Preflight: jq --version"
jq --version

log "(1/12) forge build"
forge build

log "(2/12) Start Anvil fork on port ${ANVIL_PORT}"
nohup anvil --fork-url "$FORK_RPC_URL" \
  --port "$ANVIL_PORT" \
  --chain-id "$CHAIN_ID" \
  >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
echo "$ANVIL_PID" > "$ANVIL_PID_FILE"

for ((i=1; i<=ANVIL_START_TIMEOUT; i++)); do
  if grep -q "Listening on 127.0.0.1" "$ANVIL_LOG"; then
    log "Anvil ready (pid ${ANVIL_PID})"
    break
  fi
  sleep 1
done
if ! grep -q "Listening on 127.0.0.1" "$ANVIL_LOG"; then
  warn "Anvil log tail (last 40 lines):"
  tail -n 40 "$ANVIL_LOG" || true
  fail "Timed out waiting for Anvil to start within ${ANVIL_START_TIMEOUT}s"
fi

log "(3/12) Deploy contracts to fork"
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "http://127.0.0.1:${ANVIL_PORT}" \
  --broadcast \
  --json | tee "$DEPLOY_OUT_PATH"

log "(4/12) Extract pool and RFQ addresses"
jq \
  --arg pool_label "$DNMM_POOL_LABEL" \
  --arg rfq_label "$QUOTE_RFQ_LABEL" '
    {
      pool: (.transactions[]? | select(.contractName==$pool_label) | .contractAddress),
      rfq: (.transactions[]? | select(.contractName==$rfq_label) | .contractAddress)
    }
  ' "$DEPLOY_OUT_PATH" > "$FORK_DEPLOY_PATH"

POOL_ADDRESS=$(jq -er '.pool' "$FORK_DEPLOY_PATH") || fail "Pool address not found in deploy output"
RFQ_ADDRESS=$(jq -er '.rfq' "$FORK_DEPLOY_PATH") || fail "RFQ address not found in deploy output"

log "Pool address: $POOL_ADDRESS"
log "RFQ address: $RFQ_ADDRESS"

BASE_TOKEN=$(jq -r '(.baseToken // empty)' "$DEPLOY_OUT_PATH")
[[ -z "$BASE_TOKEN" || "$BASE_TOKEN" == "null" ]] && BASE_TOKEN="$DNMM_BASE_TOKEN"
QUOTE_TOKEN=$(jq -r '(.quoteToken // empty)' "$DEPLOY_OUT_PATH")
[[ -z "$QUOTE_TOKEN" || "$QUOTE_TOKEN" == "null" ]] && QUOTE_TOKEN="$DNMM_QUOTE_TOKEN"
PYTH_ADDRESS=$(jq -r '(.pyth // empty)' "$DEPLOY_OUT_PATH")
[[ -z "$PYTH_ADDRESS" || "$PYTH_ADDRESS" == "null" ]] && PYTH_ADDRESS="$DNMM_PYTH_CONTRACT"
log "Base token: $BASE_TOKEN"
log "Quote token: $QUOTE_TOKEN"
log "Pyth contract: $PYTH_ADDRESS"

log "(5/12) Write shadow bot address book"
cat > "$ADDRESS_BOOK_PATH" <<JSON
{
  "defaultChainId": ${CHAIN_ID},
  "deployments": {
    "fork": {
      "chainId": ${CHAIN_ID},
      "poolAddress": "${POOL_ADDRESS}",
      "baseToken": "${BASE_TOKEN}",
      "quoteToken": "${QUOTE_TOKEN}",
      "pyth": "${PYTH_ADDRESS}",
      "hcPx": "0x0000000000000000000000000000000000000807",
      "hcBbo": "0x000000000000000000000000000000000000080e",
      "hcSizeDecimals": 2
    }
  }
}
JSON

log "(6/12) Write .dnmmenv for fork mode"
cat > "${BOT_PATH}/.dnmmenv" <<ENV
MODE=fork
RPC_URL=http://127.0.0.1:${ANVIL_PORT}
PROM_PORT=${PROM_PORT}
SETTINGS_FILE=${SETTINGS_FILE}
FORK_DEPLOY_JSON=fork.deploy.json
LOG_LEVEL=${LOG_LEVEL}
INTERVAL_MS=5000
ENV

log "(7/12) npm ci (shadow bot)"
(cd "$BOT_PATH" && npm ci)

log "(8/12) npm run build (shadow bot)"
(cd "$BOT_PATH" && npm run build)

run_with_timeout() {
  local duration=$1
  shift
  if command -v timeout >/dev/null; then
    if ! timeout "$duration" "$@"; then
      local ec=$?
      if [[ $ec -eq 124 ]]; then
        warn "Command '$*' timed out after ${duration}; continuing for artifact checks"
      else
        fail "Command '$*' exited with status ${ec}"
      fi
    fi
  else
    warn "timeout command not found; running without limit for $duration"
    "$@"
  fi
}

log "(9/12) Run legacy single-mode bot"
run_with_timeout "${SINGLE_RUN_TIMEOUT}s" bash -lc "cd '$BOT_PATH' && node dist/shadow-bot.js"

log "(10/12) Run multi-setting harness"
run_with_timeout "${MULTI_RUN_TIMEOUT}s" bash -lc "cd '$BOT_PATH' && node dist/multi-run.js --settings ${SETTINGS_FILE} --run-id '${RUN_ID}' --benchmarks dnmm,cpmm,stableswap --max-parallel 3 --duration-sec 15 --prom-port ${PROM_PORT}"

log "(11/12) Assert CSV artifacts"
SCOREBOARD_PATH="${BOT_PATH}/${CSV_ROOT}/run_${RUN_ID}/scoreboard.csv"
QUOTES_GLOB="${BOT_PATH}/${CSV_ROOT}/run_${RUN_ID}/quotes"/*_dnmm.csv
TRADES_GLOB="${BOT_PATH}/${CSV_ROOT}/run_${RUN_ID}/trades"/*_dnmm.csv
[[ -s "$SCOREBOARD_PATH" ]] || fail "Missing scoreboard at $SCOREBOARD_PATH"
if ! compgen -G "$QUOTES_GLOB" >/dev/null; then
  fail "Missing quote CSVs in ${BOT_PATH}/${CSV_ROOT}/run_${RUN_ID}/quotes"
fi
if ! compgen -G "$TRADES_GLOB" >/dev/null; then
  fail "Missing trade CSVs in ${BOT_PATH}/${CSV_ROOT}/run_${RUN_ID}/trades"
fi

log "(12/12) Scrape metrics and evaluate gates"
curl -s "http://127.0.0.1:${PROM_PORT}/metrics" | tee "$METRICS_SNAPSHOT" >/dev/null

grep -Eq '^dnmm_snapshot_age_sec\{.*\} [01]\.\d+' "$METRICS_SNAPSHOT" || fail "preview-freshness gate failed: expected dnmm_snapshot_age_sec within 0-1s"
grep -Eq '^shadow_uptime_two_sided_pct\{.*\} 99\.\d+' "$METRICS_SNAPSHOT" || fail "uptime gate failed: expected shadow_uptime_two_sided_pct at 99.x"

log "Gates passed"

cat <<SUMMARY
${GREEN}Artifacts ready:${RESET}
- ${DEPLOY_OUT_PATH}
- ${FORK_DEPLOY_PATH}
- ${ADDRESS_BOOK_PATH}
- ${BOT_PATH}/${CSV_ROOT}/run_${RUN_ID}
SUMMARY
