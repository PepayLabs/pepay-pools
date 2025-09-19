"""Lightweight parser for Lifinity BPF disassembly outputs."""
from __future__ import annotations

import argparse
import logging
import re
from pathlib import Path
from typing import Dict, List

import pandas as pd

from .config import ARTIFACTS_DIR, PROCESSED_DATA_DIR

INSTRUCTION_REGEX = re.compile(r"(?P<pc>0x[0-9a-f]+):\s+(?P<opcode>\w+).*")


def parse_disassembly(path: Path) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    for line in path.read_text().splitlines():
        match = INSTRUCTION_REGEX.match(line)
        if match:
            rows.append(match.groupdict())
    logging.info("Parsed %d instructions from %s", len(rows), path)
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract metadata from Lifinity disassembly")
    parser.add_argument(
        "--input",
        type=Path,
        default=Path(ARTIFACTS_DIR) / "lifinity_v2.disasm",
        help="Path to disassembly file",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(PROCESSED_DATA_DIR) / "disassembly_index.csv",
    )
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)

    if not args.input.exists():
        logging.error("Disassembly file not found: %s", args.input)
        return

    rows = parse_disassembly(args.input)
    df = pd.DataFrame(rows)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(args.output, index=False)
    logging.info("Disassembly index written to %s", args.output)


if __name__ == "__main__":
    main()
