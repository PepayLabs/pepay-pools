"""Aggregate fee accrual metrics for Lifinity pools."""
from __future__ import annotations

import argparse
import logging
from datetime import datetime
from pathlib import Path

import pandas as pd

from .config import PROCESSED_DATA_DIR


def load_swap_data(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    required = {"timestamp", "pool", "fee_applied", "token_in"}
    missing = sorted(required - set(df.columns))
    if missing:
        raise ValueError(f"Missing columns {missing} in {path}")
    df["timestamp"] = pd.to_datetime(df["timestamp"], unit="s", errors="coerce")
    df = df.dropna(subset=["timestamp"])
    return df


def aggregate_fees(df: pd.DataFrame, window: str) -> pd.DataFrame:
    df = df.copy()
    df.set_index("timestamp", inplace=True)
    grouped = (
        df.groupby("pool")["fee_applied"]
        .resample(window)
        .sum()
        .reset_index()
        .rename(columns={"fee_applied": f"fees_{window}"})
    )
    return grouped


def build_report(df: pd.DataFrame) -> pd.DataFrame:
    windows = {"24h": "1D", "7d": "7D", "30d": "30D"}
    results = []
    for label, resample_window in windows.items():
        agg = aggregate_fees(df, resample_window)
        agg["window"] = label
        results.append(agg)
    combined = pd.concat(results, ignore_index=True)
    return combined


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate fee accrual time series")
    parser.add_argument("input", type=Path, help="CSV with swap-level fees")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(PROCESSED_DATA_DIR) / "fees_timeseries.csv",
    )
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)
    df = load_swap_data(args.input)
    report = build_report(df)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report.to_csv(args.output, index=False)
    logging.info("Fees timeseries written to %s", args.output)


if __name__ == "__main__":
    main()
