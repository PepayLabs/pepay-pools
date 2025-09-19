"""Backtesting framework for Lifinity v1 vs v2 mechanics."""
from __future__ import annotations

import argparse
import json
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional

import numpy as np
import pandas as pd

from .config import PROCESSED_DATA_DIR


@dataclass
class SimulationParams:
    c: float
    z: float
    theta_bps: float
    fee_bps: float


@dataclass
class SimulationResult:
    mode: str
    fees_collected: float
    inventory_value: float
    pnl_vs_hodl: float
    trade_count: int


def load_price_series(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    required = {"timestamp", "price"}
    missing = sorted(required - set(df.columns))
    if missing:
        raise ValueError(f"Price series missing columns {missing}")
    df["timestamp"] = pd.to_datetime(df["timestamp"], unit="s", errors="coerce")
    df = df.dropna(subset=["timestamp"])
    return df.sort_values("timestamp")


def load_swap_flows(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path)
    required = {"timestamp", "amount_in", "direction"}
    missing = sorted(required - set(df.columns))
    if missing:
        raise ValueError(f"Swap flows missing columns {missing}")
    df["timestamp"] = pd.to_datetime(df["timestamp"], unit="s", errors="coerce")
    df = df.dropna(subset=["timestamp"])
    return df.sort_values("timestamp")


def simulate_mode(
    mode: str,
    price_series: pd.DataFrame,
    swaps: pd.DataFrame,
    params: SimulationParams,
) -> SimulationResult:
    """Placeholder simulation core. Implement oracle-anchored AMM math here."""
    logging.debug("Running %s simulation with params %s", mode, params)
    # TODO: Implement oracle anchoring, inventory-aware adjustments, and rebalance logic
    fees_collected = swaps["amount_in"].sum() * (params.fee_bps / 10_000)
    inventory_value = price_series["price"].iloc[-1] if not price_series.empty else 0.0
    pnl_vs_hodl = 0.0  # Placeholder until full model implemented
    return SimulationResult(
        mode=mode,
        fees_collected=fees_collected,
        inventory_value=inventory_value,
        pnl_vs_hodl=pnl_vs_hodl,
        trade_count=len(swaps),
    )


def export_results(results: List[SimulationResult], output_path: Path) -> None:
    rows = [result.__dict__ for result in results]
    output_path.parent.mkdir(parents=True, exist_ok=True)
    pd.DataFrame(rows).to_csv(output_path, index=False)
    logging.info("Backtest results written to %s", output_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Backtest Lifinity mechanics")
    parser.add_argument("price_series", type=Path, help="Oracle price series CSV")
    parser.add_argument("swap_flows", type=Path, help="Swap flow CSV")
    parser.add_argument("--c", type=float, default=100.0, help="Concentration parameter")
    parser.add_argument("--z", type=float, default=0.5, help="Inventory exponent")
    parser.add_argument("--theta-bps", type=float, default=25.0, help="v2 threshold in bps")
    parser.add_argument("--fee-bps", type=float, default=10.0, help="Swap fee in bps")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(PROCESSED_DATA_DIR) / "backtest_results.csv",
    )
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)

    price_series = load_price_series(args.price_series)
    swap_flows = load_swap_flows(args.swap_flows)

    params = SimulationParams(c=args.c, z=args.z, theta_bps=args.theta_bps, fee_bps=args.fee_bps)

    v1_result = simulate_mode("v1_continuous", price_series, swap_flows, params)
    v2_result = simulate_mode("v2_threshold", price_series, swap_flows, params)

    export_results([v1_result, v2_result], args.output)


if __name__ == "__main__":
    main()
