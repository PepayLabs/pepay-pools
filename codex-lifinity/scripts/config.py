"""Shared configuration for Codex Lifinity research scripts."""
from __future__ import annotations

import os
from dataclasses import dataclass
from typing import List

LIFINITY_V2_PROGRAM_ID = "2wT8Yq49kHgDzXuPxZSaeLaH1qbmGXtEyPy64bL7aD3c"

DEFAULT_RPC_ENDPOINTS = [
    "https://api.mainnet-beta.solana.com",
    os.getenv("ALCHEMY_SOLANA_RPC"),
    os.getenv("ANKR_SOLANA_RPC"),
]

# Filter out None / empty values while preserving order
RPC_ENDPOINTS: List[str] = [endpoint for endpoint in DEFAULT_RPC_ENDPOINTS if endpoint]

# Fallback to public endpoint if nothing configured
if not RPC_ENDPOINTS:
    RPC_ENDPOINTS = ["https://api.mainnet-beta.solana.com"]

@dataclass(frozen=True)
class PoolTarget:
    """Represents a pool of interest for empirics."""

    name: str
    label: str
    mint_a: str | None = None
    mint_b: str | None = None

SCOPE_POOLS = [
    PoolTarget(name="SOL/USDC", label="sol_usdc"),
    PoolTarget(name="SOL/USDT", label="sol_usdt"),
    PoolTarget(name="mSOL/USDC", label="msol_usdc"),
    PoolTarget(name="JitoSOL/USDC", label="jitosol_usdc"),
    PoolTarget(name="bSOL/USDC", label="bsol_usdc"),
]

DATA_ROOT = os.path.join(os.path.dirname(__file__), "..", "data")
RAW_DATA_DIR = os.path.join(DATA_ROOT, "raw")
PROCESSED_DATA_DIR = os.path.join(DATA_ROOT, "processed")
ARTIFACTS_DIR = os.path.join(os.path.dirname(__file__), "..", "artifacts")

os.makedirs(RAW_DATA_DIR, exist_ok=True)
os.makedirs(PROCESSED_DATA_DIR, exist_ok=True)
os.makedirs(ARTIFACTS_DIR, exist_ok=True)

DEFAULT_HEADERS = {"User-Agent": "codex-lifinity-research/0.1"}

# Maximum transactions to pull per pool per batch for initial sampling
MAX_TX_SAMPLE = int(os.getenv("LIFINITY_MAX_TX_SAMPLE", "500"))
