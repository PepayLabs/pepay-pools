#!/usr/bin/env python3
"""
Lifinity V2 AMM Reverse Engineering Tool
Portability-focused analysis for EVM re-implementation feasibility
"""

import asyncio
import json
import struct
import hashlib
import base64
import time
from typing import Dict, List, Tuple, Optional, Any
from dataclasses import dataclass, field
from datetime import datetime, timedelta
import os
import sys
import pandas as pd
import numpy as np
from solana.rpc.api import Client
from solana.rpc.websocket_api import connect
from solders.pubkey import Pubkey
from solders.signature import Signature
from solders.transaction import Transaction
from solders.instruction import Instruction, AccountMeta
from solana.transaction import Signature as SolanaSignature
import requests
from concurrent.futures import ThreadPoolExecutor

# Lifinity V2 Program ID
PROGRAM_ID = "2wT8Yq49kHgDzXuPxZSaeLaH1qbmGXtEyPy64bL7aD3c"

# Known Pyth oracle accounts for main pairs
PYTH_ORACLES = {
    "SOL/USD": "J83w4HKfqxwcq3BEMMkPFSppX3gqekLyLJBexebFVkix",
    "USDC/USD": "Gnt27xtC473ZT2Mw5u8wZ68Z3gULkSTb5DuxJy7eJotD",
    "USDT/USD": "3vxLXJqLqF3JG5TCbYycbKWRBbCJQLxQmBGCkyqEEefL"
}

# Scope pools for empirical analysis
SCOPE_POOLS = [
    "SOL/USDC",
    "SOL/USDT",
    "mSOL/USDC",
    "JitoSOL/USDC",
    "bSOL/USDC"
]

@dataclass
class SwapInstruction:
    """Decoded swap instruction data"""
    discriminator: bytes
    account_metas: List[AccountMeta]
    data: bytes
    timestamp: datetime
    slot: int
    tx_id: str
    amount_in: Optional[int] = None
    amount_out: Optional[int] = None
    oracle_price: Optional[float] = None
    oracle_confidence: Optional[float] = None
    oracle_age: Optional[int] = None

@dataclass
class PoolState:
    """Pool state layout"""
    address: str
    token_a_mint: str
    token_b_mint: str
    token_a_vault: str
    token_b_vault: str
    fee_bps: int
    oracle_account: str
    last_oracle_slot: int
    concentration_param: Optional[float] = None  # c parameter
    inventory_exponent: Optional[float] = None  # z parameter
    rebalance_threshold: Optional[float] = None  # θ parameter
    last_rebalance_price: Optional[float] = None  # p* parameter
    authority: str
    reserves_a: int = 0
    reserves_b: int = 0
    virtual_reserves_a: Optional[int] = None
    virtual_reserves_b: Optional[int] = None

@dataclass
class OracleData:
    """Oracle price data"""
    price: float
    confidence: float
    publish_slot: int
    timestamp: datetime

class LifinityAnalyzer:
    """Main analyzer for Lifinity V2 AMM reverse engineering"""

    def __init__(self, rpc_url="https://api.mainnet-beta.solana.com"):
        self.client = Client(rpc_url)
        self.program_id = Pubkey.from_string(PROGRAM_ID)
        self.instructions_map = {}  # discriminator -> instruction name
        self.pool_states = {}  # pool address -> PoolState
        self.swap_samples = []
        self.oracle_cache = {}

    async def analyze_program(self):
        """Main analysis pipeline"""
        print(f"[*] Starting Lifinity V2 analysis for program {PROGRAM_ID}")

        # Phase 1: Collect recent transactions
        print("[*] Phase 1: Collecting recent transactions...")
        await self.collect_recent_transactions(limit=1000)

        # Phase 2: Map instruction discriminators
        print("[*] Phase 2: Mapping instruction discriminators...")
        await self.map_instructions()

        # Phase 3: Reconstruct state layouts
        print("[*] Phase 3: Reconstructing state layouts...")
        await self.reconstruct_state_layouts()

        # Phase 4: Derive algorithms
        print("[*] Phase 4: Deriving swap algorithms...")
        await self.derive_algorithms()

        # Phase 5: Analyze rebalancing
        print("[*] Phase 5: Analyzing rebalancing mechanics...")
        await self.analyze_rebalancing()

        # Phase 6: Collect empirical data
        print("[*] Phase 6: Collecting empirical data...")
        await self.collect_empirical_data()

        # Phase 7: Generate reports
        print("[*] Phase 7: Generating reports...")
        await self.generate_reports()

    async def collect_recent_transactions(self, limit=1000):
        """Collect recent transactions for the program"""
        try:
            # Get recent signatures
            response = self.client.get_signatures_for_address(
                self.program_id,
                limit=limit
            )

            signatures = response.value
            print(f"  Found {len(signatures)} recent transactions")

            # Fetch transaction details in batches
            batch_size = 10
            for i in range(0, len(signatures), batch_size):
                batch = signatures[i:i+batch_size]
                await self.process_transaction_batch(batch)

        except Exception as e:
            print(f"  Error collecting transactions: {e}")

    async def process_transaction_batch(self, signatures):
        """Process a batch of transactions"""
        for sig_info in signatures:
            try:
                tx_response = self.client.get_transaction(
                    sig_info.signature,
                    max_supported_transaction_version=0
                )

                if not tx_response or not tx_response.value:
                    continue

                tx = tx_response.value

                # Extract instructions for our program
                if tx.transaction and tx.transaction.transaction:
                    message = tx.transaction.transaction.message

                    for idx, ix in enumerate(message.instructions):
                        if message.account_keys[ix.program_id_index] == self.program_id:
                            await self.process_instruction(
                                ix,
                                message.account_keys,
                                sig_info.signature,
                                sig_info.slot,
                                sig_info.block_time
                            )

            except Exception as e:
                print(f"    Error processing transaction {sig_info.signature}: {e}")

    async def process_instruction(self, ix, account_keys, signature, slot, timestamp):
        """Process and store instruction data"""
        try:
            # Get instruction data
            data = bytes(ix.data)

            # Extract discriminator (first 8 bytes)
            if len(data) >= 8:
                discriminator = data[:8]

                # Store instruction
                swap_ix = SwapInstruction(
                    discriminator=discriminator,
                    account_metas=[
                        AccountMeta(
                            pubkey=account_keys[acc_idx],
                            is_signer=acc_idx in (ix.accounts if hasattr(ix, 'accounts') else []),
                            is_writable=True  # Simplified, need to check actual flags
                        )
                        for acc_idx in ix.accounts
                    ],
                    data=data,
                    timestamp=datetime.fromtimestamp(timestamp) if timestamp else datetime.now(),
                    slot=slot,
                    tx_id=str(signature)
                )

                self.swap_samples.append(swap_ix)

                # Map discriminator
                disc_hex = discriminator.hex()
                if disc_hex not in self.instructions_map:
                    self.instructions_map[disc_hex] = self.infer_instruction_type(ix, data)

        except Exception as e:
            print(f"    Error processing instruction: {e}")

    def infer_instruction_type(self, ix, data):
        """Infer instruction type from data patterns"""
        data_len = len(data)

        # Common patterns for different instruction types
        if data_len == 8:
            return "admin_operation"  # No additional data
        elif data_len == 16:
            return "swap_exact_input"  # 8 byte discriminator + 8 byte amount
        elif data_len == 24:
            return "swap_exact_output"  # More data for output amount + slippage
        elif data_len > 32:
            return "initialize_pool"  # Lots of config data
        else:
            return f"unknown_{data_len}"

    async def map_instructions(self):
        """Map all instruction discriminators to names"""
        print(f"  Mapped {len(self.instructions_map)} unique instructions:")
        for disc, name in sorted(self.instructions_map.items()):
            print(f"    {disc}: {name}")

    async def reconstruct_state_layouts(self):
        """Reconstruct pool state layouts from account data"""
        # Find pool PDAs
        pool_addresses = await self.find_pool_pdas()

        for pool_addr in pool_addresses[:5]:  # Analyze first 5 pools
            try:
                # Fetch account data
                response = self.client.get_account_info(Pubkey.from_string(pool_addr))

                if response and response.value:
                    data = response.value.data

                    # Parse state (this is simplified - actual parsing needs proper layout)
                    state = self.parse_pool_state(pool_addr, data)
                    self.pool_states[pool_addr] = state

                    print(f"  Parsed pool {pool_addr[:8]}...")

            except Exception as e:
                print(f"  Error parsing pool {pool_addr}: {e}")

    async def find_pool_pdas(self):
        """Find pool PDA addresses"""
        # This would query for accounts owned by the program
        # For now returning empty list as this requires more complex RPC calls
        return []

    def parse_pool_state(self, address, data):
        """Parse pool state from account data"""
        # Simplified state parsing - actual implementation needs proper struct layout
        state = PoolState(
            address=address,
            token_a_mint="",
            token_b_mint="",
            token_a_vault="",
            token_b_vault="",
            fee_bps=30,  # Common 0.3% fee
            oracle_account="",
            last_oracle_slot=0,
            authority=""
        )

        # Parse bytes (this is pseudocode - needs actual layout)
        if len(data) >= 256:
            # Typical layout might be:
            # 0-32: token_a_mint
            # 32-64: token_b_mint
            # 64-96: token_a_vault
            # 96-128: token_b_vault
            # 128-136: reserves_a (u64)
            # 136-144: reserves_b (u64)
            # etc...
            pass

        return state

    async def derive_algorithms(self):
        """Derive swap algorithms from on-chain data"""
        print("  Analyzing swap patterns...")

        # Group swaps by similar sizes to detect slippage curves
        if self.swap_samples:
            df = pd.DataFrame([
                {
                    'discriminator': s.discriminator.hex(),
                    'slot': s.slot,
                    'timestamp': s.timestamp
                }
                for s in self.swap_samples
            ])

            # Analyze instruction frequency
            inst_counts = df['discriminator'].value_counts()
            print(f"  Top instructions by frequency:")
            for disc, count in inst_counts.head(5).items():
                name = self.instructions_map.get(disc, "unknown")
                print(f"    {disc[:16]}... ({name}): {count} calls")

    async def analyze_rebalancing(self):
        """Analyze v2 rebalancing mechanics"""
        print("  Analyzing rebalancing patterns...")

        # Look for state changes that indicate rebalancing
        # This would involve comparing pool states before/after certain transactions

    async def collect_empirical_data(self):
        """Collect empirical metrics for scope pools"""
        print("  Collecting empirical data for scope pools...")

        metrics = []
        for pool_name in SCOPE_POOLS:
            print(f"    Analyzing {pool_name}...")

            # This would collect:
            # - 24h/7d/30d volume
            # - TVL snapshots
            # - Fees collected
            # - Turnover ratios
            # - Oracle age distribution

            metrics.append({
                'pool': pool_name,
                'volume_24h': 0,  # Placeholder
                'tvl': 0,
                'fees_24h': 0,
                'turnover': 0
            })

        # Save metrics
        df = pd.DataFrame(metrics)
        df.to_csv('empirical_metrics.csv', index=False)
        print("  Saved empirical metrics to empirical_metrics.csv")

    async def generate_reports(self):
        """Generate all deliverable reports"""
        print("  Generating reports...")

        # Create output directory
        os.makedirs('deliverables', exist_ok=True)

        # D2: Instruction catalog
        with open('deliverables/D2_INSTRUCTION_CATALOG.md', 'w') as f:
            f.write("# Lifinity V2 Instruction Catalog\n\n")
            f.write("| Discriminator | Name | Account Count | Data Size |\n")
            f.write("|---------------|------|---------------|----------|\n")

            for disc, name in sorted(self.instructions_map.items()):
                # Find sample instruction with this discriminator
                sample = next((s for s in self.swap_samples if s.discriminator.hex() == disc), None)
                if sample:
                    acc_count = len(sample.account_metas)
                    data_size = len(sample.data)
                    f.write(f"| {disc[:16]}... | {name} | {acc_count} | {data_size} |\n")

        print("  Report D2_INSTRUCTION_CATALOG.md generated")

        # More reports would be generated here...

def main():
    """Main entry point"""
    analyzer = LifinityAnalyzer()
    asyncio.run(analyzer.analyze_program())

if __name__ == "__main__":
    main()