#!/usr/bin/env bash
set -euo pipefail

FRESHNESS_MINUTES="${FRESHNESS_MINUTES:-30}"
STRICT_INVARIANTS="${STRICT_INVARIANTS:-0}"
LOG_PATH=""

usage() {
  cat <<USAGE
Usage: $0 [--log <path>] [--fresh-minutes <minutes>]

Ensures parity CSV artifacts are fresh and populated when the long invariant run executes.

Options:
  --log <path>          Invariant run log to disambiguate run vs skip decisions.
  --fresh-minutes <n>   Override freshness threshold (default: ${FRESHNESS_MINUTES}).
  -h, --help            Show this message.
USAGE
}

info() { printf '\033[1;34m%s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$1"; }
err() { printf '\033[1;31m%s\033[0m\n' "$1"; }

while (( $# > 0 )); do
  case "$1" in
    --log)
      LOG_PATH="$2"
      shift 2
      ;;
    --fresh-minutes)
      FRESHNESS_MINUTES="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

FILES=(
  "metrics/mid_event_vs_precompile_mid_bps.csv"
  "metrics/canary_deltas.csv"
)
MIN_ROWS=(2 2)

normalize_minutes() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
    return
  fi
  err "Freshness minutes must be numeric"
  exit 2
}

FRESHNESS_MINUTES=$(normalize_minutes "$FRESHNESS_MINUTES")

determine_run_state() {
  local did_run=1
  local skip_reason=""

  if [[ -n "$LOG_PATH" && -f "$LOG_PATH" ]]; then
    if LC_ALL=C grep -aq "Skipping long run" "$LOG_PATH"; then
      did_run=0
      skip_reason="log indicates skip"
    fi
    if LC_ALL=C grep -aq "🚀 Running" "$LOG_PATH"; then
      did_run=1
      skip_reason=""
    fi
  fi

  echo "$did_run:$skip_reason"
}

read_state=$(determine_run_state)
did_run=${read_state%%:*}
skip_reason=${read_state#*:}

if [[ -n "$LOG_PATH" ]]; then
  info "Using invariant log: ${LOG_PATH}"
fi

if [[ "$did_run" -eq 0 ]]; then
  warn "Long-run invariants skipped (${skip_reason:-no reason captured})."
  if [[ "$STRICT_INVARIANTS" == "1" ]]; then
    err "STRICT_INVARIANTS=1 requires long-run execution; aborting."
    exit 1
  fi
  info "Parity metric freshness checks bypassed."
  for path in "${FILES[@]}"; do
    if [[ -f "$path" ]]; then
      info "Present: $path (age: $(date -r "$path" '+%Y-%m-%d %H:%M:%S%z'))"
    else
      warn "Missing artifact (skip tolerated): $path"
    fi
  done
  exit 0
fi

status=0
now=$(date +%s)

for idx in "${!FILES[@]}"; do
  path="${FILES[$idx]}"
  min_rows="${MIN_ROWS[$idx]}"

  if [[ ! -f "$path" ]]; then
    err "Missing required artifact: $path"
    status=1
    continue
  fi

  mtime=$(stat -c %Y "$path")
  age_minutes=$(( (now - mtime + 59) / 60 ))

  lines=$(wc -l < "$path")
  if (( lines == 0 )); then
    err "Empty CSV: $path"
    status=1
    continue
  fi

  data_rows=$(( lines - 1 ))

  info "${path}: age=${age_minutes}m rows=${data_rows} (min=${min_rows})"

  if (( age_minutes > FRESHNESS_MINUTES )); then
    err "Stale CSV (>${FRESHNESS_MINUTES}m): $path"
    status=1
  fi

  if (( data_rows < min_rows )); then
    err "Insufficient rows (${data_rows} < ${min_rows}): $path"
    status=1
  fi
done

if (( status != 0 )); then
  err "Parity metric checks failed"
  exit "$status"
fi

info "Parity metric checks passed"
exit 0
