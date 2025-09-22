#!/usr/bin/env bash
set -euo pipefail

TEST_PATH="${1:-test/invariants/Invariant_NoRunDry.t.sol}"

BUDGET_SECS="${BUDGET_SECS:-3600}"
IDLE_SECS="${IDLE_SECS:-600}"
TARGET_RUNS="${TARGET_RUNS:-20000}"
SAMPLE_RUNS="${SAMPLE_RUNS:-400}"
SHARDS="${SHARDS:-4}"
PROFILE_SHORT="${PROFILE_SHORT:-ci}"
PROFILE_LONG="${PROFILE_LONG:-long}"
SEED_BASE="${SEED_BASE:-123456}"

info() { printf '\033[1;34m%s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$1"; }

info "🔧 Building (forge build)"
FOUNDRY_PROFILE="$PROFILE_SHORT" forge build >/dev/null

info "⏱️  Sampling ${SAMPLE_RUNS} runs"
start=$(date +%s)
FOUNDRY_PROFILE="$PROFILE_SHORT" FOUNDRY_INVARIANT_RUNS="$SAMPLE_RUNS" forge test \
  --match-path "$TEST_PATH" \
  -vv >/tmp/invariant_sample.log 2>&1 || true
end=$(date +%s)

sample_secs=$(( end - start ))
if (( sample_secs == 0 )); then sample_secs=1; fi
per_run_ms=$(( sample_secs * 1000 / SAMPLE_RUNS ))
est_secs=$(( per_run_ms * TARGET_RUNS / 1000 ))
info "📈 Sample ${sample_secs}s ⇒ ~${per_run_ms}ms/run ⇒ est ${est_secs}s for ${TARGET_RUNS} runs"

if (( est_secs > BUDGET_SECS )); then
  warn "⚠️  Skipping long run: estimate ${est_secs}s exceeds budget ${BUDGET_SECS}s"
  FOUNDRY_PROFILE="$PROFILE_SHORT" FOUNDRY_INVARIANT_RUNS=2000 forge test --match-path "$TEST_PATH" -vv
  exit 0
fi

runs_per_shard=$(( TARGET_RUNS / SHARDS ))
if (( runs_per_shard == 0 )); then runs_per_shard=$TARGET_RUNS; SHARDS=1; fi
info "🚀 Running ${TARGET_RUNS} runs across ${SHARDS} shard(s) (~${runs_per_shard} each)"

pids=()
for shard in $(seq 1 "$SHARDS"); do
  seed=$(( SEED_BASE + shard ))
  shard_budget=$(( BUDGET_SECS / SHARDS + 120 ))
  info "▶️  Shard ${shard}/${SHARDS} seed=${seed}"
  (
    FOUNDRY_PROFILE="$PROFILE_LONG" \
    FOUNDRY_INVARIANT_RUNS="$runs_per_shard" \
    timeout --signal=SIGINT --kill-after=30 "$shard_budget" \
      stdbuf -oL -eL forge test \
        --match-path "$TEST_PATH" \
        --fuzz-seed "$seed" -vv 2>&1 \
      | awk -v idle="$IDLE_SECS" 'BEGIN { last = systime(); } { print; fflush(); last = systime(); } (systime() - last) > idle { print "## idle timeout"; fflush(); exit 124 }'
  ) &
  pids+=($!)
done

status=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    status=1
  fi
done

exit "$status"
