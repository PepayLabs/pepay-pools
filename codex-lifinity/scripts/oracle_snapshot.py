"""Oracle account snapshot utility."""
from __future__ import annotations

import argparse
import json
import logging
from datetime import datetime
from pathlib import Path
from typing import Dict

from solana.rpc.api import Client

from .config import RAW_DATA_DIR, RPC_ENDPOINTS


def fetch_oracle_account(client: Client, address: str) -> Dict:
    response = client.get_account_info(address, encoding="base64")
    if response.get("error"):
        raise RuntimeError(response["error"])
    return response.get("result", {})


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Snapshot oracle account for Lifinity pools")
    parser.add_argument("address", help="Oracle account pubkey")
    parser.add_argument("--rpc", choices=RPC_ENDPOINTS, default=RPC_ENDPOINTS[0])
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(RAW_DATA_DIR) / "oracle_accounts",
        help="Directory for snapshots",
    )
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)
    args.output.mkdir(parents=True, exist_ok=True)

    client = Client(args.rpc, timeout=45)
    snapshot = fetch_oracle_account(client, args.address)

    timestamp = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    output_path = args.output / f"{args.address}_{timestamp}.json"
    output_path.write_text(json.dumps(snapshot, indent=2))
    logging.info("Oracle snapshot saved to %s", output_path)


if __name__ == "__main__":
    main()
