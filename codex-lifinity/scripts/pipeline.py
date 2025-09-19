"""High-level orchestration helpers for the portability study."""
from __future__ import annotations

import argparse
import logging
import subprocess
from pathlib import Path
from typing import List

from . import config

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = PROJECT_ROOT / "scripts"


def run_step(command: List[str]) -> None:
    logging.info("Running %s", " ".join(command))
    subprocess.run(command, check=True)


def cmd_inventory(args: argparse.Namespace) -> None:
    run_step([
        "python3",
        str(SCRIPTS_DIR / "program_inventory.py"),
        "--rpc",
        args.rpc,
        "--output",
        str(PROJECT_ROOT / "data" / "processed" / "program_inventory.json"),
    ])


def cmd_sample(args: argparse.Namespace) -> None:
    run_step([
        "python3",
        str(SCRIPTS_DIR / "tx_sampler.py"),
        "--rpc",
        args.rpc,
        "--limit",
        str(args.limit),
    ])
    run_step([
        "python3",
        str(SCRIPTS_DIR / "tx_decoder.py"),
        "--rpc",
        args.rpc,
        "--limit",
        str(args.decode_limit),
    ])


def cmd_empirics(args: argparse.Namespace) -> None:
    run_step([
        "python3",
        str(SCRIPTS_DIR / "slippage_analysis.py"),
        str(args.swap_csv),
    ])
    run_step([
        "python3",
        str(SCRIPTS_DIR / "fees_tracker.py"),
        str(args.swap_csv),
    ])


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Codex Lifinity research pipeline")
    parser.add_argument("--rpc", default=config.RPC_ENDPOINTS[0], help="RPC endpoint to use")

    sub = parser.add_subparsers(dest="command", required=True)

    inventory = sub.add_parser("inventory", help="Collect program account inventory")
    inventory.set_defaults(func=cmd_inventory)

    sample = sub.add_parser("sample", help="Sample and decode recent transactions")
    sample.add_argument("--limit", type=int, default=config.MAX_TX_SAMPLE, help="Signatures to fetch")
    sample.add_argument("--decode-limit", type=int, default=250, help="Transactions to decode in detail")
    sample.set_defaults(func=cmd_sample)

    empirics = sub.add_parser("empirics", help="Recompute slippage and fee aggregates")
    empirics.add_argument("swap_csv", type=Path, help="Path to enriched swap dataset")
    empirics.set_defaults(func=cmd_empirics)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
    args.func(args)


if __name__ == "__main__":
    main()
