#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVARIANTS_JSON="$ROOT_DIR/reports/invariants_run.json"
FRESHNESS_JSON="$ROOT_DIR/reports/metrics/freshness_report.json"

jq_check() {
  local filter="$1"
  local description="$2"
  local file="$3"
  if ! jq -e "$filter" "$file" > /dev/null; then
    echo "[FAIL] $description" >&2
    exit 1
  fi
}

if [[ ! -f "$INVARIANTS_JSON" ]]; then
  echo "[FAIL] invariants report missing: $INVARIANTS_JSON" >&2
  exit 1
fi

jq_check '.totals.runs_planned == .totals.runs_executed' \
  "runs_planned != runs_executed" "$INVARIANTS_JSON"

jq_check '.totals.revert_rate_bps <= 1000' \
  "revert rate above threshold" "$INVARIANTS_JSON"

if [[ ! -f "$FRESHNESS_JSON" ]]; then
  echo "[FAIL] freshness report missing: $FRESHNESS_JSON" >&2
  exit 1
fi

if ! jq -e '(.entries | map(select(.status == "pass")) | length) == (.entries | length)' \
  "$FRESHNESS_JSON" > /dev/null; then
  echo "[FAIL] metrics freshness gate failed" >&2
  jq '.entries' "$FRESHNESS_JSON"
  exit 1
fi

echo "[OK] invariants and parity freshness checks passed"
