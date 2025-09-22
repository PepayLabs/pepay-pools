#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

CSV_REQUIREMENTS = {
    "metrics/mid_event_vs_precompile_mid_bps.csv": 2,
    "metrics/canary_deltas.csv": 2,
}

ANSI_PATTERN = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def strip_ansi(text: str) -> str:
    return ANSI_PATTERN.sub("", text)


def parse_log(log_path: Path) -> dict:
    if not log_path.exists():
        raise FileNotFoundError(f"Log file not found: {log_path}")

    with log_path.open("r", encoding="utf-8", errors="ignore") as handle:
        lines = [strip_ansi(line.rstrip("\n")) for line in handle]

    report = {
        "decision": "unknown",
        "sample": None,
        "estimate_secs": None,
        "target_runs": None,
        "eta_parallel_secs": None,
        "eta_sequential_secs": None,
        "shards": [],
        "suite_runs": [],
        "durations": [],
    }

    if any("Skipping long run" in line for line in lines):
        report["decision"] = "skip"
    elif any("🚀 Running" in line or re.search(r"Running\\s+\\d+\\s+runs", line) for line in lines):
        report["decision"] = "run"

    sample_line = next((line for line in lines if "Sample" in line and "ms/run" in line), None)
    if sample_line:
        match = re.search(r"Sample\s+(\d+)s\s+⇒\s+~(\d+)ms/run\s+⇒\s+est\s+(\d+)s\s+for\s+(\d+)\s+runs", sample_line)
        if match:
            sample_secs, per_run_ms, est_secs, target_runs = match.groups()
            report["sample"] = {
                "seconds": int(sample_secs),
                "ms_per_run": int(per_run_ms),
            }
            report["estimate_secs"] = int(est_secs)
            report["target_runs"] = int(target_runs)

    eta_line = next((line for line in lines if "Parallel ETA" in line), None)
    if eta_line:
        eta_match = re.search(r"Parallel ETA ≈\s+(\d+)s.*sequential\s+(\d+)s", eta_line)
        if eta_match:
            report["eta_parallel_secs"] = int(eta_match.group(1))
            report["eta_sequential_secs"] = int(eta_match.group(2))

    shard_lines = [line for line in lines if line.startswith("▶️  Shard")]
    for line in shard_lines:
        match = re.search(r"Shard\s+(\d+)/(\d+)\s+seed=(\d+)\s+runs_planned=(\d+)(?:\s+\(skipped\))?", line)
        bool_skipped = "(skipped)" in line
        if match:
            shard_idx, shard_total, seed, planned = match.groups()
            planned_int = int(planned)
        else:
            legacy = re.search(r"Shard\s+(\d+)/(\d+)\s+seed=(\d+)\s+runs=(\d+)", line)
            if not legacy:
                continue
            shard_idx, shard_total, seed, planned = legacy.groups()
            planned_int = int(planned)
            bool_skipped = planned_int == 0
        report["shards"].append({
            "index": int(shard_idx),
            "total": int(shard_total),
            "seed": int(seed),
            "planned_runs": planned_int,
            "skipped": bool_skipped,
        })

    suite_stats: dict[str, dict[str, int]] = {}
    current_test_path: str | None = None
    shard_results_iter = iter([s for s in report["shards"] if not s.get("skipped") and s.get("planned_runs", 0) > 0])

    for line in lines:
        if line.startswith("Ran 1 test for "):
            match = re.search(r"Ran 1 test for\s+([^:]+):", line)
            if match:
                current_test_path = match.group(1)
            continue

        if "[PASS]" in line and "runs:" in line and "reverts:" in line:
            match = re.search(r"runs:\s*(\d+).*reverts:\s*(\d+)", line)
            if not match:
                continue
            runs_val, reverts_val = match.groups()
            runs_int = int(runs_val)
            reverts_int = int(reverts_val)

            try:
                shard_entry = next(shard_results_iter)
                shard_entry["result"] = {"runs": runs_int, "reverts": reverts_int}
            except StopIteration:
                pass

            if current_test_path:
                stats = suite_stats.setdefault(
                    current_test_path,
                    {"executions": 0, "runs": 0, "reverts": 0},
                )
                stats["executions"] += 1
                stats["runs"] += runs_int
                stats["reverts"] += reverts_int
            current_test_path = None

        if "Suite result" in line and "finished in" in line:
            match = re.search(r"finished in\s+([0-9.]+)s", line)
            if match:
                report["durations"].append(float(match.group(1)))

    suite_summary = []
    for path, stats in suite_stats.items():
        runs = stats["runs"]
        reverts = stats["reverts"]
        rate_bps = 0
        if runs:
            rate_bps = (reverts * 10_000) // runs
        suite_summary.append(
            {
                "path": path,
                "executions": stats["executions"],
                "runs": runs,
                "reverts": reverts,
                "revert_rate_bps": rate_bps,
            }
        )

    report["suite_runs"] = suite_summary

    return report


def collect_csv_stats(fresh_minutes: int) -> dict:
    now = time.time()
    stats = {}
    for path, min_rows in CSV_REQUIREMENTS.items():
        csv_path = Path(path)
        entry = {
            "exists": csv_path.exists(),
            "rows": 0,
            "data_rows": 0,
            "age_minutes": None,
            "min_rows": min_rows,
            "fresh": False,
        }
        if csv_path.exists():
            mtime = csv_path.stat().st_mtime
            entry["age_minutes"] = int((now - mtime + 59) // 60)
            with csv_path.open("r", encoding="utf-8", errors="ignore") as handle:
                row_count = sum(1 for _ in handle)
            entry["rows"] = row_count
            entry["data_rows"] = max(row_count - 1, 0)
            entry["fresh"] = (
                entry["age_minutes"] is not None and entry["age_minutes"] <= fresh_minutes
            )
        stats[path] = entry
    return stats


def main() -> int:
    parser = argparse.ArgumentParser(description="Summarize invariant run logs into JSON")
    parser.add_argument("log", type=Path, help="Invariant run log file")
    parser.add_argument("--output", type=Path, default=Path("reports/invariants_run.json"))
    parser.add_argument("--fresh-minutes", type=int, default=int(os.getenv("FRESHNESS_MINUTES", "30")))
    args = parser.parse_args()

    try:
        report = parse_log(args.log)
    except FileNotFoundError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    csv_stats = collect_csv_stats(args.fresh_minutes)

    planned_total = 0
    executed_total = 0
    revert_total = 0
    for shard in report["shards"]:
        planned_total += shard.get("planned_runs", 0)
        result = shard.get("result")
        if result:
            executed_total += result.get("runs", 0)
            revert_total += result.get("reverts", 0)

    revert_rate_bps = 0
    if executed_total:
        revert_rate_bps = (revert_total * 10_000) // executed_total

    output = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "log_path": str(args.log),
        "decision": report["decision"],
        "sample": report["sample"],
        "estimate_secs": report["estimate_secs"],
        "eta_parallel_secs": report["eta_parallel_secs"],
        "eta_sequential_secs": report["eta_sequential_secs"],
        "target_runs": report["target_runs"],
        "shards": report["shards"],
        "suite_runs": report["suite_runs"],
        "durations_secs": report["durations"],
        "csv": csv_stats,
        "freshness_minutes": args.fresh_minutes,
        "totals": {
            "runs_planned": planned_total,
            "runs_executed": executed_total,
            "reverts": revert_total,
            "revert_rate_bps": revert_rate_bps,
        },
    }

    output_path = args.output
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("w", encoding="utf-8") as handle:
        json.dump(output, handle, indent=2)
        handle.write("\n")

    print(f"Wrote {output_path} ({output_path.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
