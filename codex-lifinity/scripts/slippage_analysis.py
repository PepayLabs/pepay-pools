"""Build realized slippage curves from swap samples."""
from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path
from typing import Dict, List

import pandas as pd

from .config import PROCESSED_DATA_DIR


EXPECTED_COLUMNS = {
    "tx_id",
    "timestamp",
    "slot",
    "pool",
    "p_oracle",
    "amount_in",
    "amount_out",
    "token_in",
    "token_out",
}


def load_samples(path: Path) -> pd.DataFrame:
    if not path.exists():
        raise FileNotFoundError(f"Swap sample file missing: {path}")
    df = pd.read_csv(path)
    missing = sorted(EXPECTED_COLUMNS - set(df.columns))
    if missing:
        raise ValueError(f"Missing columns {missing} in {path}")
    return df


def compute_slippage(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df["mid_output"] = df["amount_in"] * df["p_oracle"]
    df["realized_slippage_bps"] = (df["mid_output"] - df["amount_out"]) / df["mid_output"] * 10_000
    grouped = (
        df.groupby(["pool", "token_in"])
        .apply(
            lambda group: group.assign(
                trade_size=group["amount_in"],
                realized_slippage_bps=group["realized_slippage_bps"],
            )[["pool", "token_in", "trade_size", "realized_slippage_bps"]]
        )
        .reset_index(drop=True)
    )
    return grouped


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compute slippage curves from swap dataset")
    parser.add_argument("input", type=Path, help="Path to enriched swap CSV")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(PROCESSED_DATA_DIR) / "slippage_curve.csv",
    )
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)
    df = load_samples(args.input)
    slippage_df = compute_slippage(df)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    slippage_df.to_csv(args.output, index=False)
    logging.info("Slippage curve written to %s", args.output)


if __name__ == "__main__":
    main()
