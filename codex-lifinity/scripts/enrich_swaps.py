"""Parse decoded Solana transactions to extract Lifinity swap metadata."""
from __future__ import annotations

import argparse
import base64
import json
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional

import pandas as pd

from .config import LIFINITY_V2_PROGRAM_ID, PROCESSED_DATA_DIR, RAW_DATA_DIR


@dataclass
class InstructionRecord:
    tx_id: str
    slot: int
    block_time: Optional[int]
    is_inner: bool
    instruction_index: int
    discriminator: str
    accounts: List[str]


def normalise_account_keys(account_keys: List) -> List[str]:
    normalised: List[str] = []
    for entry in account_keys:
        if isinstance(entry, str):
            normalised.append(entry)
        elif isinstance(entry, dict):
            normalised.append(entry.get("pubkey", ""))
        else:
            normalised.append(str(entry))
    return normalised


def decode_discriminator(data_field: str) -> str:
    if not data_field:
        return ""
    try:
        raw = base64.b64decode(data_field)
    except Exception as exc:  # noqa: BLE001
        logging.debug("Failed to decode instruction data: %s", exc)
        return ""
    if len(raw) < 8:
        return raw.hex()
    return raw[:8].hex()


def extract_from_instruction(
    instruction: Dict,
    account_keys: List[str],
    tx_id: str,
    slot: int,
    block_time: Optional[int],
    is_inner: bool,
    base_index: int,
) -> Optional[InstructionRecord]:
    program_index = instruction.get("programIdIndex")
    if program_index is None:
        return None
    try:
        program_id = account_keys[program_index]
    except IndexError:
        logging.debug("Program index out of bounds for tx %s", tx_id)
        return None
    if program_id != LIFINITY_V2_PROGRAM_ID:
        return None
    data_field = instruction.get("data", "")
    discriminator = decode_discriminator(data_field)
    accounts_idx = instruction.get("accounts", [])
    accounts = []
    for idx in accounts_idx:
        try:
            accounts.append(account_keys[idx])
        except IndexError:
            accounts.append("<out_of_bounds>")
    return InstructionRecord(
        tx_id=tx_id,
        slot=slot,
        block_time=block_time,
        is_inner=is_inner,
        instruction_index=base_index,
        discriminator=discriminator,
        accounts=accounts,
    )


def iterate_instructions(tx: Dict) -> Iterable[InstructionRecord]:
    tx_meta = tx.get("meta") or {}
    if tx_meta.get("err") is not None:
        return

    transaction = tx.get("transaction") or {}
    message = transaction.get("message") or {}
    account_keys = normalise_account_keys(message.get("accountKeys") or [])
    slot = tx.get("slot", 0)
    block_time = tx.get("blockTime")
    signatures = transaction.get("signatures") or []
    tx_sig = signatures[0] if signatures else ""

    for idx, instruction in enumerate(message.get("instructions") or []):
        record = extract_from_instruction(
            instruction,
            account_keys,
            tx_sig,
            slot,
            block_time,
            is_inner=False,
            base_index=idx,
        )
        if record:
            yield record

    inner_instructions = tx_meta.get("innerInstructions") or []
    for inner in inner_instructions:
        parent_index = inner.get("index", -1)
        for offset, instruction in enumerate(inner.get("instructions", []) or []):
            record = extract_from_instruction(
                instruction,
                account_keys,
                tx_sig,
                slot,
                block_time,
                is_inner=True,
                base_index=parent_index * 1000 + offset if parent_index >= 0 else offset,
            )
            if record:
                yield record


def load_transactions(path: Path) -> List[Dict]:
    if not path.exists():
        raise FileNotFoundError(f"Decoded transaction file not found: {path}")
    with path.open() as fh:
        payload = json.load(fh)
        if isinstance(payload, list):
            return payload
        raise ValueError("Expected JSON array from tx_decoder output")


def build_dataframe(records: Iterable[InstructionRecord]) -> pd.DataFrame:
    rows = []
    for record in records:
        rows.append(
            {
                "tx_id": record.tx_id,
                "slot": record.slot,
                "block_time": record.block_time,
                "is_inner": int(record.is_inner),
                "instruction_index": record.instruction_index,
                "discriminator": record.discriminator,
                "accounts": ",".join(record.accounts),
            }
        )
    return pd.DataFrame(rows)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Enrich Lifinity swap transactions")
    parser.add_argument(
        "--input",
        type=Path,
        default=Path(RAW_DATA_DIR) / "tx_samples.json",
        help="Decoded transaction JSON",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(PROCESSED_DATA_DIR) / "lifinity_instructions.csv",
        help="Output CSV capturing Lifinity instructions",
    )
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)
    transactions = load_transactions(args.input)
    records = list(
        record
        for tx in transactions
        for record in iterate_instructions(tx)
    )
    if not records:
        logging.warning("No Lifinity instructions found in %s", args.input)
        return

    df = build_dataframe(records)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(args.output, index=False)
    logging.info("Extracted %d Lifinity instructions to %s", len(df), args.output)


if __name__ == "__main__":
    main()
