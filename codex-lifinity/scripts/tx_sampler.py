"""Transaction sampler for Lifinity v2 swap activity."""
from __future__ import annotations

import argparse
import csv
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional

from solana.rpc.api import Client
from solders.pubkey import Pubkey

from .config import LIFINITY_V2_PROGRAM_ID, RAW_DATA_DIR, RPC_ENDPOINTS, MAX_TX_SAMPLE


@dataclass
class TxSample:
    signature: str
    slot: int
    block_time: Optional[int]
    succeeded: bool
    err: Optional[str]


def build_client(rpc_endpoint: str) -> Client:
    logging.info("RPC endpoint: %s", rpc_endpoint)
    return Client(rpc_endpoint, timeout=45)


def fetch_signatures(client: Client, limit: int) -> Iterable[TxSample]:
    """Fetch recent signatures for Lifinity program."""
    logging.info("Fetching up to %d signatures", limit)
    response = client.get_signatures_for_address(Pubkey.from_string(LIFINITY_V2_PROGRAM_ID), limit=limit)
    if response.get("error"):
        raise RuntimeError(response["error"])

    for entry in response.get("result", []):
        meta = entry.get("err")
        yield TxSample(
            signature=entry["signature"],
            slot=entry["slot"],
            block_time=entry.get("blockTime"),
            succeeded=meta is None,
            err=str(meta) if meta else None,
        )


def write_csv(samples: Iterable[TxSample], output_path: Path) -> int:
    count = 0
    with output_path.open("w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["signature", "slot", "block_time", "succeeded", "error"])
        for sample in samples:
            writer.writerow(
                [
                    sample.signature,
                    sample.slot,
                    sample.block_time or "",
                    1 if sample.succeeded else 0,
                    sample.err or "",
                ]
            )
            count += 1
    logging.info("Wrote %d entries to %s", count, output_path)
    return count


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Sample Lifinity swap transactions")
    parser.add_argument("--rpc", choices=RPC_ENDPOINTS, default=RPC_ENDPOINTS[0])
    parser.add_argument("--limit", type=int, default=MAX_TX_SAMPLE, help="Number of signatures to fetch")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(RAW_DATA_DIR) / "tx_signatures.csv",
        help="CSV path for output",
    )
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)

    client = build_client(args.rpc)
    samples = list(fetch_signatures(client, args.limit))
    if not samples:
        logging.warning("No signatures retrieved")
        return

    write_csv(samples, args.output)


if __name__ == "__main__":
    main()
