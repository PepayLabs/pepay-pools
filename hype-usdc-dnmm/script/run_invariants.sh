#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TEST="test/invariants/Invariant_NoRunDry.t.sol"

BUDGET_SECS="${BUDGET_SECS:-3600}"
IDLE_SECS="${IDLE_SECS:-600}"
TARGET_RUNS="${TARGET_RUNS:-20000}"
SAMPLE_RUNS="${SAMPLE_RUNS:-400}"
SHARDS="${SHARDS:-4}"
PROFILE_SHORT="${PROFILE_SHORT:-ci}"
PROFILE_LONG="${PROFILE_LONG:-long}"
SEED_BASE="${SEED_BASE:-123456}"
PARITY_REFRESH="${PARITY_REFRESH:-1}"
PARITY_TEST_PATH="${PARITY_TEST_PATH:-test/integration/ForkParity.t.sol}"
PARITY_TEST_NAME="${PARITY_TEST_NAME:-test_fork_parity_paths_and_metrics}"
CANARY_TEST_PATH="${CANARY_TEST_PATH:-test/integration/Scenario_CanaryShadow.t.sol}"

shopt -s nullglob

info() { printf '\033[1;34m%s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$1"; }

ANY_LONG_RUN=0

collect_tests() {
  if (( $# == 0 )); then
    printf '%s\n' "$DEFAULT_TEST"
    return
  fi

  local matches=()
  while (( $# > 0 )); do
    local pattern="$1"
    shift
    local expanded=( $pattern )
    if (( ${#expanded[@]} == 0 )); then
      warn "⚠️  No invariant tests matched pattern: ${pattern}"
      continue
    fi
    matches+=("${expanded[@]}")
  done

  if (( ${#matches[@]} == 0 )); then
    warn "⚠️  No invariant test files found; aborting"
    exit 1
  fi

  printf '%s\n' "${matches[@]}"
}

resolve_depth() {
  local profile="$1"
  awk -v profile="$profile" '
    $0 ~ "\\[profile\\." profile "\\.invariant\\]" { section=1; next }
    /^\[/ && section { exit }
    section && $1 == "depth" { print $3; exit }
  ' foundry.toml
}

slugify() {
  local file="$1"
  echo "${file//[^a-zA-Z0-9]/_}"
}

run_single_test() {
  local test_path="$1"

  info "═▶ Processing invariant suite: ${test_path}"

  info "🔧 Building (forge build)"
  FOUNDRY_PROFILE="$PROFILE_SHORT" forge build >/dev/null

  local depth
  depth=$(resolve_depth "$PROFILE_LONG")
  info "📋 Config ⇒ sample_profile=${PROFILE_SHORT} long_profile=${PROFILE_LONG} depth=${depth:-unknown} target_runs=${TARGET_RUNS} shards=${SHARDS} idle_secs=${IDLE_SECS}"
  info "🧾 Plan ⇒ profile_short=${PROFILE_SHORT} profile_long=${PROFILE_LONG} depth=${depth:-unknown} sample_runs=${sample_runs} seed_base=${SEED_BASE}"

  local sample_runs=$SAMPLE_RUNS
  if (( sample_runs < 1 )); then
    warn "⚠️  SAMPLE_RUNS < 1 supplied; coerce to 1"
    sample_runs=1
  fi

  info "⏱️  Sampling ${sample_runs} runs"
  local start
  start=$(date +%s)
  local sample_log
  sample_log="/tmp/invariant_sample_$(slugify "$test_path").log"
  FOUNDRY_PROFILE="$PROFILE_SHORT" FOUNDRY_INVARIANT_RUNS="$sample_runs" forge test \
    --match-path "$test_path" \
    -vv >"$sample_log" 2>&1 || true
  local end
  end=$(date +%s)

  local sample_secs=$(( end - start ))
  if (( sample_secs == 0 )); then sample_secs=1; fi
  local per_run_ms=$(( sample_secs * 1000 / sample_runs ))
  local est_secs=$(( per_run_ms * TARGET_RUNS / 1000 ))
  info "📈 Sample ${sample_secs}s ⇒ ~${per_run_ms}ms/run ⇒ est ${est_secs}s for ${TARGET_RUNS} runs"

  if (( est_secs > BUDGET_SECS )); then
    warn "⚠️  Skipping long run: estimate ${est_secs}s exceeds budget ${BUDGET_SECS}s"
    FOUNDRY_PROFILE="$PROFILE_SHORT" FOUNDRY_INVARIANT_RUNS=2000 forge test --match-path "$test_path" -vv
    return 0
  fi

  ANY_LONG_RUN=1

  local shard_count=$SHARDS
  if (( shard_count < 1 )); then
    warn "⚠️  SHARDS < 1 supplied; coerce to 1"
    shard_count=1
  fi
  local base_runs=$(( TARGET_RUNS / shard_count ))
  local remainder=$(( TARGET_RUNS % shard_count ))
  local max_runs_per_shard=$base_runs
  if (( remainder > 0 )); then
    max_runs_per_shard=$(( max_runs_per_shard + 1 ))
  fi
  local est_parallel_ms=$(( per_run_ms * max_runs_per_shard ))
  est_parallel_ms=$(( est_parallel_ms * 12 / 10 ))
  local est_parallel_secs=$(( est_parallel_ms / 1000 ))
  if (( est_parallel_secs == 0 && est_parallel_ms > 0 )); then
    est_parallel_secs=1
  fi
  info "🚀 Running ${TARGET_RUNS} runs across ${shard_count} shard(s) (~${base_runs} base, remainder ${remainder})"
  info "📊 Parallel ETA ≈ ${est_parallel_secs}s (sequential ${est_secs}s)"

  local -a shard_pids=()
  local -a shard_start=()
  local planned_runs
  for shard in $(seq 1 "$shard_count"); do
    local seed=$(( SEED_BASE + shard ))
    planned_runs=$base_runs
    if (( shard <= remainder )); then
      planned_runs=$(( planned_runs + 1 ))
    fi
    if (( planned_runs == 0 )); then
      info "▶️  Shard ${shard}/${shard_count} seed=${seed} runs_planned=0 (skipped)"
      continue
    fi
    local shard_budget=$(( BUDGET_SECS / shard_count + 120 ))
    info "▶️  Shard ${shard}/${shard_count} seed=${seed} runs_planned=${planned_runs}"
    shard_start[$shard]=$(date +%s)
    (
      FOUNDRY_PROFILE="$PROFILE_LONG" \
      FOUNDRY_INVARIANT_RUNS="$planned_runs" \
      timeout --signal=SIGINT --kill-after=30 "$shard_budget" \
        stdbuf -oL -eL forge test \
          --match-path "$test_path" \
          --fuzz-seed "$seed" -vv 2>&1 \
        | awk -v idle="$IDLE_SECS" 'BEGIN { last = systime(); } { print; fflush(); last = systime(); } (systime() - last) > idle { print "## idle timeout"; fflush(); exit 124 }'
    ) &
    shard_pids[$shard]=$!
  done

  local status=0
  for shard in $(seq 1 "$shard_count"); do
    local pid="${shard_pids[$shard]:-}"
    if [[ -z "$pid" ]]; then
      continue
    fi
    local exit_code=0
    if ! wait "$pid"; then
      exit_code=$?
      status=1
    fi
    local end_ts
    end_ts=$(date +%s)
    local start_ts=${shard_start[$shard]:-0}
    local duration=$(( end_ts - start_ts ))
    if (( duration < 0 )); then duration=0; fi
    info "✅ Shard ${shard}/${shard_count} finished status=${exit_code} duration=${duration}s"
  done

  return "$status"
}

refresh_parity() {
  if [[ "$PARITY_REFRESH" == "0" ]]; then
    info "ℹ️  Parity refresh disabled"
    return
  fi

  local parity_log
  parity_log="${PARITY_LOG_PATH:-/tmp/parity_refresh_$(date +%s).log}"
  info "🧮 Refreshing parity metrics (${PARITY_TEST_PATH} :: ${PARITY_TEST_NAME})"
  : >"$parity_log"

  if ! FOUNDRY_PROFILE="$PROFILE_SHORT" forge test \
    --match-path "$PARITY_TEST_PATH" \
    --match-test "$PARITY_TEST_NAME" \
    -vv | tee -a "$parity_log"; then
    warn "⚠️  Parity refresh failed"
    return 1
  fi

  if ! FOUNDRY_PROFILE="$PROFILE_SHORT" forge test \
    --match-path "$CANARY_TEST_PATH" \
    -vv | tee -a "$parity_log"; then
    warn "⚠️  Parity refresh failed"
    return 1
  fi

  if ! script/check_parity_metrics.sh --log "$parity_log"; then
    warn "⚠️  Parity freshness check failed"
    return 1
  fi

  info "✅ Parity metrics refreshed"
}

main() {
  mapfile -t suites < <(collect_tests "$@")
  local overall=0
  for suite in "${suites[@]}"; do
    if ! run_single_test "$suite"; then
      overall=1
    fi
  done

  if (( ANY_LONG_RUN == 1 )); then
    refresh_parity || overall=1
  else
    info "ℹ️  No long-run suites executed; parity refresh skipped"
  fi

  exit "$overall"
}

main "$@"
