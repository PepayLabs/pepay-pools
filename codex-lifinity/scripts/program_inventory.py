"""Program inventory collection for Lifinity v2 pools."""
from __future__ import annotations

import argparse
import json
import logging
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Dict, List, Optional

from solana.rpc.api import Client

from .config import (
    LIFINITY_V2_PROGRAM_ID,
    PROCESSED_DATA_DIR,
    RPC_ENDPOINTS,
    SCOPE_POOLS,
    PoolTarget,
)


@dataclass
class PoolRecord:
    """Snapshot of a Lifinity pool PDA and its associated accounts."""

    address: str
    mint_a: Optional[str]
    mint_b: Optional[str]
    vault_a: Optional[str]
    vault_b: Optional[str]
    fee_vault_a: Optional[str]
    fee_vault_b: Optional[str]
    oracle_account: Optional[str]
    admin_authority: Optional[str]
    scope_tag: Optional[str] = None


@dataclass
class InventoryResult:
    """Aggregated inventory output."""

    rpc_endpoint: str
    total_accounts: int
    pool_records: List[PoolRecord]


def build_client(rpc_endpoint: str) -> Client:
    logging.info("Using RPC endpoint %s", rpc_endpoint)
    return Client(rpc_endpoint, timeout=30)


def fetch_program_accounts(client: Client) -> List[Dict]:
    """Return raw program accounts for Lifinity v2."""
    logging.debug("Fetching program accounts for %s", LIFINITY_V2_PROGRAM_ID)
    response = client.get_program_accounts(LIFINITY_V2_PROGRAM_ID, encoding="base64")
    if response.get("error"):
        raise RuntimeError(f"RPC error: {response['error']}")

    value = response.get("result", [])
    logging.info("Fetched %d accounts", len(value))
    return value


def infer_pool_records(accounts: List[Dict], scopes: List[PoolTarget]) -> List[PoolRecord]:
    """Lightweight inference of pool metadata from account owner filters.

    Full decoding requires struct layout knowledge; this function preserves placeholders
    until state layout recovery is complete.
    """
    records: List[PoolRecord] = []
    for account in accounts:
        pubkey = account.get("pubkey")
        lamports = account.get("account", {}).get("lamports", 0)
        data = account.get("account", {}).get("data", [])
        # Placeholder inference; enrich once state layout is mapped
        records.append(
            PoolRecord(
                address=pubkey,
                mint_a=None,
                mint_b=None,
                vault_a=None,
                vault_b=None,
                fee_vault_a=None,
                fee_vault_b=None,
                oracle_account=None,
                admin_authority=None,
                scope_tag=_match_scope(pubkey, scopes),
            )
        )
        logging.debug("Recorded pool %s (%s lamports, %d bytes)", pubkey, lamports, len(data))
    return records


def _match_scope(address: str, scopes: List[PoolTarget]) -> Optional[str]:
    for scope in scopes:
        if scope.name.upper().split("/")[0] in address.upper():
            return scope.label
    return None


def save_inventory(result: InventoryResult, output_path: Path) -> None:
    payload = {
        "rpc_endpoint": result.rpc_endpoint,
        "total_accounts": result.total_accounts,
        "pool_records": [asdict(record) for record in result.pool_records],
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2))
    logging.info("Inventory written to %s", output_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Collect Lifinity v2 program inventory")
    parser.add_argument(
        "--rpc",
        dest="rpc_endpoint",
        choices=RPC_ENDPOINTS,
        default=RPC_ENDPOINTS[0],
        help="RPC endpoint to query",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(PROCESSED_DATA_DIR) / "program_inventory.json",
        help="Output JSON path",
    )
    parser.add_argument("--verbose", action="store_true", help="Enable debug logging")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)

    client = build_client(args.rpc_endpoint)
    accounts = fetch_program_accounts(client)
    records = infer_pool_records(accounts, scopes=SCOPE_POOLS)

    result = InventoryResult(
        rpc_endpoint=args.rpc_endpoint,
        total_accounts=len(accounts),
        pool_records=records,
    )
    save_inventory(result, args.output)


if __name__ == "__main__":
    main()
