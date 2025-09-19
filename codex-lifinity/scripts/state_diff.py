"""State snapshot and diff utility for Lifinity pools."""
from __future__ import annotations

import argparse
import json
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List

from solana.rpc.api import Client

from .config import RAW_DATA_DIR, PROCESSED_DATA_DIR, RPC_ENDPOINTS


@dataclass
class AccountSnapshot:
    slot: int
    lamports: int
    data_base64: str


def fetch_account_snapshot(client: Client, address: str) -> AccountSnapshot:
    response = client.get_account_info(address, encoding="base64")
    if response.get("error"):
        raise RuntimeError(response["error"])
    result = response.get("result", {})
    value = result.get("value")
    if value is None:
        raise ValueError(f"Account {address} not found")
    return AccountSnapshot(
        slot=result.get("context", {}).get("slot", 0),
        lamports=value.get("lamports", 0),
        data_base64=value.get("data", [""])[0],
    )


def save_snapshot(snapshot: AccountSnapshot, output_path: Path) -> None:
    payload = {
        "slot": snapshot.slot,
        "lamports": snapshot.lamports,
        "data_base64": snapshot.data_base64,
    }
    output_path.write_text(json.dumps(payload, indent=2))
    logging.debug("Snapshot saved to %s", output_path)


def diff_snapshots(before: AccountSnapshot, after: AccountSnapshot) -> Dict:
    return {
        "slot_before": before.slot,
        "slot_after": after.slot,
        "lamports_delta": after.lamports - before.lamports,
        "data_equal": before.data_base64 == after.data_base64,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Capture and diff Lifinity pool states")
    parser.add_argument("address", help="Pool PDA address")
    parser.add_argument("--rpc", choices=RPC_ENDPOINTS, default=RPC_ENDPOINTS[0])
    parser.add_argument(
        "--before",
        type=Path,
        help="Optional path to existing pre-swap snapshot JSON",
    )
    parser.add_argument(
        "--after",
        type=Path,
        help="Optional path to existing post-swap snapshot JSON",
    )
    parser.add_argument(
        "--diff-output",
        type=Path,
        default=Path(PROCESSED_DATA_DIR) / "state_diffs.json",
    )
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)

    client = Client(args.rpc, timeout=45)

    before_snapshot = (
        AccountSnapshot(**json.loads(args.before.read_text()))
        if args.before and args.before.exists()
        else fetch_account_snapshot(client, args.address)
    )
    save_snapshot(before_snapshot, Path(RAW_DATA_DIR) / f"{args.address}_before.json")

    logging.info("Waiting for post-swap snapshot... run script again with --after once captured")

    if args.after:
        after_snapshot = AccountSnapshot(**json.loads(args.after.read_text()))
    else:
        after_snapshot = fetch_account_snapshot(client, args.address)
        save_snapshot(after_snapshot, Path(RAW_DATA_DIR) / f"{args.address}_after.json")

    diff = diff_snapshots(before_snapshot, after_snapshot)
    args.diff_output.write_text(json.dumps(diff, indent=2))
    logging.info("Diff written to %s", args.diff_output)


if __name__ == "__main__":
    main()
