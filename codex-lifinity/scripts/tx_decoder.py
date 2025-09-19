"""Decode transaction details for sampled Lifinity signatures."""
from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path
from typing import Dict, List

from solana.rpc.api import Client
from solana.rpc.types import TokenAccountOpts

from .config import LIFINITY_V2_PROGRAM_ID, RAW_DATA_DIR, RPC_ENDPOINTS


def load_signatures(path: Path) -> List[str]:
    if not path.exists():
        raise FileNotFoundError(f"Signature file not found: {path}")
    with path.open() as fh:
        next(fh)  # skip header
        return [line.split(",", 1)[0].strip() for line in fh if line.strip()]


def decode_transactions(client: Client, signatures: List[str]) -> List[Dict]:
    results: List[Dict] = []
    for sig in signatures:
        logging.debug("Fetching transaction %s", sig)
        response = client.get_transaction(sig, encoding="json", max_supported_transaction_version=0)
        if response.get("error"):
            logging.warning("Error fetching %s: %s", sig, response["error"])
            continue
        tx = response.get("result")
        if not tx:
            continue
        results.append(tx)
    logging.info("Decoded %d/%d transactions", len(results), len(signatures))
    return results


def dump_raw_transactions(transactions: List[Dict], output_path: Path) -> None:
    output_path.write_text(json.dumps(transactions, indent=2))
    logging.info("Wrote transactions to %s", output_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Decode Lifinity transactions into JSON")
    parser.add_argument("--rpc", choices=RPC_ENDPOINTS, default=RPC_ENDPOINTS[0])
    parser.add_argument(
        "--signatures",
        type=Path,
        default=Path(RAW_DATA_DIR) / "tx_signatures.csv",
        help="CSV of sampled signatures",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(RAW_DATA_DIR) / "tx_samples.json",
        help="Destination JSON path",
    )
    parser.add_argument("--limit", type=int, default=250, help="Optional limit on decoded transactions")
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)

    signatures = load_signatures(args.signatures)
    if args.limit:
        signatures = signatures[: args.limit]

    client = Client(args.rpc, timeout=45)
    transactions = decode_transactions(client, signatures)
    dump_raw_transactions(transactions, args.output)


if __name__ == "__main__":
    main()
