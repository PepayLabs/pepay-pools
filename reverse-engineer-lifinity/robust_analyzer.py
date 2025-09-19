#!/usr/bin/env python3
"""
Robust Lifinity V2 Analyzer
Enhanced error handling and transaction format support
"""

import asyncio
import aiohttp
import json
import struct
import base64
import time
import pickle
import hashlib
from typing import Dict, List, Tuple, Optional, Any, Set
from dataclasses import dataclass, field, asdict
from datetime import datetime, timedelta
from pathlib import Path
from collections import defaultdict, Counter
import os
import sys

# Core imports
from solana.rpc.api import Client
from solders.pubkey import Pubkey
from solders.signature import Signature
import base58

# Constants
LIFINITY_V2_PROGRAM_ID = "2wT8Yq49kHgDzXuPxZSaeLaH1qbmGXtEyPy64bL7aD3c"
RPC_ENDPOINTS = [
    "https://api.mainnet-beta.solana.com",
    "https://solana-mainnet.g.alchemy.com/v2/demo",
    "https://rpc.ankr.com/solana"
]

# Performance Configuration
MAX_INITIAL_TXS = 100
BATCH_SIZE = 5         # Even smaller batches
REQUEST_TIMEOUT = 10   # Longer timeout
PARALLEL_REQUESTS = 2  # Fewer concurrent requests
CACHE_TTL = 3600

@dataclass
class InstructionData:
    """Lightweight instruction data"""
    discriminator: str
    name: str
    frequency: int = 0
    account_count: int = 0
    data_size: int = 0
    is_critical: bool = False
    sample_data: str = ""

@dataclass
class SwapEvent:
    """Minimal swap event data"""
    tx_id: str
    slot: int
    timestamp: datetime
    amount_in: int = 0
    estimated_out: int = 0
    instruction_type: str = "unknown"

@dataclass
class AnalysisResults:
    """Complete analysis results"""
    instructions: Dict[str, InstructionData]
    swaps: List[SwapEvent]
    state_patterns: Dict[str, Any]
    oracle_usage: Dict[str, int]
    processing_time: float
    coverage_stats: Dict[str, int]
    raw_discriminators: Set[str]

class RPCCache:
    """Simple file-based RPC response cache"""

    def __init__(self, cache_dir: str = ".rpc_cache"):
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(exist_ok=True)

    def _cache_key(self, method: str, params: Any) -> str:
        """Generate cache key from method and params"""
        cache_input = f"{method}:{json.dumps(params, sort_keys=True, default=str)}"
        return hashlib.md5(cache_input.encode()).hexdigest()

    def get(self, method: str, params: Any) -> Optional[Any]:
        """Get cached response"""
        try:
            cache_file = self.cache_dir / f"{self._cache_key(method, params)}.pkl"
            if cache_file.exists():
                with open(cache_file, 'rb') as f:
                    cached_data = pickle.load(f)

                if time.time() - cached_data['timestamp'] < CACHE_TTL:
                    return cached_data['data']
                else:
                    cache_file.unlink()
        except Exception:
            pass
        return None

    def set(self, method: str, params: Any, data: Any):
        """Cache response"""
        try:
            cache_file = self.cache_dir / f"{self._cache_key(method, params)}.pkl"
            with open(cache_file, 'wb') as f:
                pickle.dump({
                    'timestamp': time.time(),
                    'data': data
                }, f)
        except Exception:
            pass

class RobustAnalyzer:
    """Robust Lifinity analyzer with enhanced error handling"""

    def __init__(self, rpc_url: str = None):
        self.rpc_url = rpc_url or RPC_ENDPOINTS[0]
        self.client = Client(self.rpc_url)
        self.cache = RPCCache()
        self.program_id = Pubkey.from_string(LIFINITY_V2_PROGRAM_ID)

        # Analysis state
        self.instructions: Dict[str, InstructionData] = {}
        self.swaps: List[SwapEvent] = []
        self.state_patterns: Dict[str, Any] = {}
        self.oracle_accounts: Set[str] = set()
        self.raw_discriminators: Set[str] = set()

        # Performance tracking
        self.start_time = time.time()
        self.processed_txs = 0
        self.errors = 0
        self.error_details = []

    async def analyze_incremental(self, max_time: int = 30) -> AnalysisResults:
        """Main analysis method with robust error handling"""
        print(f"🚀 Starting robust Lifinity analysis (max {max_time}s)")

        try:
            # Phase 1: Fetch signatures (quick)
            signatures = await self._fetch_signatures_fast()
            if not signatures:
                return self._create_results("No signatures found")

            print(f"📊 Found {len(signatures)} signatures to analyze")

            # Phase 2: Process transactions with robust error handling
            processing_time = max(10, max_time - 15)
            await self._process_transactions_robust(signatures, processing_time)

            # Phase 3: Pattern analysis
            self._analyze_patterns_fast()

            # Phase 4: Generate results
            return self._create_results("Analysis completed successfully")

        except Exception as e:
            print(f"❌ Critical analysis error: {e}")
            import traceback
            traceback.print_exc()
            return self._create_results(f"Analysis failed: {e}")

    async def _fetch_signatures_fast(self) -> List[Any]:
        """Fetch signatures with caching"""
        print("📡 Fetching recent signatures...")

        cache_key = f"signatures_{MAX_INITIAL_TXS}"
        cached = self.cache.get("get_signatures_for_address", cache_key)

        if cached:
            print(f"🎯 Using cached signatures ({len(cached)} found)")
            return cached[:MAX_INITIAL_TXS]

        try:
            response = self.client.get_signatures_for_address(
                self.program_id,
                limit=MAX_INITIAL_TXS
            )

            if response and response.value:
                signatures = response.value
                self.cache.set("get_signatures_for_address", cache_key, signatures)
                print(f"✅ Fetched {len(signatures)} fresh signatures")
                return signatures

        except Exception as e:
            print(f"⚠️ Signature fetch failed: {e}")

        return []

    async def _process_transactions_robust(self, signatures: List[Any], max_time: int):
        """Process transactions with enhanced error handling"""
        print(f"⚡ Processing transactions robustly (max {max_time}s)...")

        start_time = time.time()
        total_sigs = len(signatures)
        successful_txs = 0

        for i in range(0, total_sigs, BATCH_SIZE):
            # Check time limit
            if time.time() - start_time > max_time:
                print(f"⏱️ Time limit reached, processed {self.processed_txs}/{total_sigs}")
                break

            batch = signatures[i:i + BATCH_SIZE]
            batch_success = await self._process_batch_robust(batch)
            successful_txs += batch_success

            # Progress update
            self.processed_txs = min(i + BATCH_SIZE, total_sigs)
            progress = (self.processed_txs / total_sigs) * 100
            success_rate = (successful_txs / self.processed_txs) * 100 if self.processed_txs > 0 else 0
            print(f"📊 Progress: {self.processed_txs}/{total_sigs} ({progress:.1f}%) Success: {success_rate:.1f}%")

            # Slow down if too many errors
            if self.errors > self.processed_txs * 0.8:  # 80% error rate
                print("⚠️ High error rate, slowing down...")
                await asyncio.sleep(1)

    async def _process_batch_robust(self, signatures: List[Any]) -> int:
        """Process batch with individual error handling"""
        successful = 0

        for sig_info in signatures:
            try:
                success = await self._process_single_transaction(sig_info)
                if success:
                    successful += 1
            except Exception as e:
                self.errors += 1
                error_detail = f"Batch processing error: {str(e)[:100]}"
                if len(self.error_details) < 10:  # Keep only first 10 error details
                    self.error_details.append(error_detail)

        return successful

    async def _process_single_transaction(self, sig_info) -> bool:
        """Process single transaction with detailed error handling"""
        try:
            sig_str = str(sig_info.signature)

            # Check cache first
            cached_tx = self.cache.get("get_transaction", sig_str)
            if cached_tx:
                tx_data = cached_tx
            else:
                # Fetch with multiple attempts
                tx_data = await self._fetch_transaction_robust(sig_info.signature)
                if not tx_data:
                    return False

                self.cache.set("get_transaction", sig_str, tx_data)

            # Extract instruction data with multiple parsing strategies
            return self._extract_instructions_robust(tx_data, sig_info)

        except Exception as e:
            self.errors += 1
            error_msg = f"Single TX error: {str(e)[:100]}"
            if len(self.error_details) < 10:
                self.error_details.append(error_msg)
            return False

    async def _fetch_transaction_robust(self, signature) -> Optional[Any]:
        """Fetch transaction with multiple attempts and formats"""
        attempts = [
            {"encoding": "json", "max_supported_transaction_version": 0},
            {"encoding": "jsonParsed", "max_supported_transaction_version": 0},
            {"encoding": "base64", "max_supported_transaction_version": 0},
        ]

        for attempt in attempts:
            try:
                response = self.client.get_transaction(signature, **attempt)
                if response and response.value:
                    return response.value
            except Exception as e:
                continue

        return None

    def _extract_instructions_robust(self, tx_data, sig_info) -> bool:
        """Extract instructions with multiple parsing strategies"""
        try:
            # Strategy 1: Standard transaction format
            if hasattr(tx_data, 'transaction') and tx_data.transaction:
                if self._parse_standard_transaction(tx_data, sig_info):
                    return True

            # Strategy 2: Try different attribute paths
            if hasattr(tx_data, 'meta') and hasattr(tx_data, 'transaction'):
                if self._parse_alternative_transaction(tx_data, sig_info):
                    return True

            # Strategy 3: Raw parsing if transaction data is dict
            if isinstance(tx_data, dict):
                if self._parse_dict_transaction(tx_data, sig_info):
                    return True

            return False

        except Exception as e:
            return False

    def _parse_standard_transaction(self, tx_data, sig_info) -> bool:
        """Parse standard transaction format"""
        try:
            transaction = tx_data.transaction
            if hasattr(transaction, 'transaction'):
                message = transaction.transaction.message
            else:
                message = transaction.message

            return self._process_message_instructions(message, sig_info)

        except Exception:
            return False

    def _parse_alternative_transaction(self, tx_data, sig_info) -> bool:
        """Parse alternative transaction format"""
        try:
            # Different ways to access the message
            possible_paths = [
                lambda x: x.transaction.message,
                lambda x: x.transaction.transaction.message,
                lambda x: x['transaction']['message'],
            ]

            for path_func in possible_paths:
                try:
                    message = path_func(tx_data)
                    if self._process_message_instructions(message, sig_info):
                        return True
                except:
                    continue

            return False

        except Exception:
            return False

    def _parse_dict_transaction(self, tx_data, sig_info) -> bool:
        """Parse transaction from dict format"""
        try:
            if 'transaction' in tx_data:
                tx = tx_data['transaction']
                if 'message' in tx:
                    return self._process_dict_message(tx['message'], sig_info)

            return False

        except Exception:
            return False

    def _process_message_instructions(self, message, sig_info) -> bool:
        """Process instructions from message object"""
        try:
            found_lifinity = False

            for ix in message.instructions:
                program_idx = ix.program_id_index

                if program_idx < len(message.account_keys):
                    program_key = str(message.account_keys[program_idx])

                    if program_key == LIFINITY_V2_PROGRAM_ID:
                        self._process_lifinity_instruction_robust(ix, message, sig_info)
                        found_lifinity = True

            return found_lifinity

        except Exception:
            return False

    def _process_dict_message(self, message_dict, sig_info) -> bool:
        """Process instructions from dict message"""
        try:
            found_lifinity = False

            if 'instructions' in message_dict and 'accountKeys' in message_dict:
                account_keys = message_dict['accountKeys']

                for ix in message_dict['instructions']:
                    program_idx = ix.get('programIdIndex', -1)

                    if 0 <= program_idx < len(account_keys):
                        program_key = account_keys[program_idx]

                        if program_key == LIFINITY_V2_PROGRAM_ID:
                            self._process_dict_instruction(ix, message_dict, sig_info)
                            found_lifinity = True

            return found_lifinity

        except Exception:
            return False

    def _process_lifinity_instruction_robust(self, ix, message, sig_info):
        """Process Lifinity instruction with robust parsing"""
        try:
            # Handle different data formats
            if hasattr(ix, 'data'):
                if isinstance(ix.data, str):
                    data = base58.b58decode(ix.data)
                elif isinstance(ix.data, bytes):
                    data = ix.data
                else:
                    data = bytes(ix.data)
            else:
                return

            if len(data) < 8:
                return

            # Extract discriminator
            discriminator = data[:8].hex()
            self.raw_discriminators.add(discriminator)

            # Process instruction
            self._update_instruction_stats(discriminator, data, ix.accounts if hasattr(ix, 'accounts') else [])

            # Detect patterns
            if self._is_swap_instruction(data, len(ix.accounts) if hasattr(ix, 'accounts') else 0):
                self._extract_swap_data_robust(ix, data, sig_info)

            # Detect oracles
            self._detect_oracle_usage_robust(ix, message)

        except Exception:
            pass

    def _process_dict_instruction(self, ix_dict, message_dict, sig_info):
        """Process instruction from dict format"""
        try:
            # Extract data
            data_str = ix_dict.get('data', '')
            if not data_str:
                return

            try:
                data = base58.b58decode(data_str)
            except:
                return

            if len(data) < 8:
                return

            # Extract discriminator
            discriminator = data[:8].hex()
            self.raw_discriminators.add(discriminator)

            # Process instruction
            accounts = ix_dict.get('accounts', [])
            self._update_instruction_stats(discriminator, data, accounts)

            # Detect patterns
            if self._is_swap_instruction(data, len(accounts)):
                self._extract_swap_data_dict(ix_dict, data, sig_info)

        except Exception:
            pass

    def _update_instruction_stats(self, discriminator: str, data: bytes, accounts: List):
        """Update instruction statistics"""
        if discriminator not in self.instructions:
            self.instructions[discriminator] = InstructionData(
                discriminator=discriminator,
                name=self._classify_instruction(data, accounts),
                frequency=0,
                account_count=len(accounts),
                data_size=len(data),
                sample_data=data[:32].hex()  # First 32 bytes as sample
            )

        self.instructions[discriminator].frequency += 1

    def _classify_instruction(self, data: bytes, accounts: List) -> str:
        """Enhanced instruction classification"""
        data_len = len(data)
        acc_count = len(accounts)

        # More sophisticated classification
        if data_len == 8:
            if acc_count <= 1:
                return "query_state"
            elif acc_count <= 3:
                return "simple_action"
            else:
                return "admin_action"
        elif 16 <= data_len <= 24:
            if acc_count >= 6:
                return "swap_exact_input"
            elif acc_count >= 3:
                return "token_action"
            else:
                return "state_update"
        elif 25 <= data_len <= 40:
            if acc_count >= 6:
                return "swap_exact_output"
            else:
                return "complex_update"
        elif data_len > 100:
            return "initialize_pool"
        elif 40 < data_len <= 100:
            return "configure_params"
        else:
            return f"unknown_{data_len}b_{acc_count}acc"

    def _is_swap_instruction(self, data: bytes, account_count: int) -> bool:
        """Enhanced swap detection"""
        return (16 <= len(data) <= 40 and
                account_count >= 6 and
                account_count <= 15)

    def _extract_swap_data_robust(self, ix, data: bytes, sig_info):
        """Extract swap data with robust parsing"""
        try:
            amount = 0
            if len(data) >= 16:
                # Try different amount parsing strategies
                try:
                    amount = struct.unpack('<Q', data[8:16])[0]  # Little-endian u64
                except:
                    try:
                        amount = struct.unpack('>Q', data[8:16])[0]  # Big-endian u64
                    except:
                        amount = int.from_bytes(data[8:16], 'little')

            swap = SwapEvent(
                tx_id=str(sig_info.signature),
                slot=sig_info.slot or 0,
                timestamp=datetime.fromtimestamp(sig_info.block_time) if sig_info.block_time else datetime.now(),
                amount_in=amount,
                instruction_type="swap"
            )

            self.swaps.append(swap)

        except Exception:
            pass

    def _extract_swap_data_dict(self, ix_dict, data: bytes, sig_info):
        """Extract swap data from dict format"""
        try:
            amount = 0
            if len(data) >= 16:
                amount = struct.unpack('<Q', data[8:16])[0]

            swap = SwapEvent(
                tx_id=str(sig_info.signature),
                slot=sig_info.slot or 0,
                timestamp=datetime.fromtimestamp(sig_info.block_time) if sig_info.block_time else datetime.now(),
                amount_in=amount,
                instruction_type="swap"
            )

            self.swaps.append(swap)

        except Exception:
            pass

    def _detect_oracle_usage_robust(self, ix, message):
        """Robust oracle detection"""
        try:
            if hasattr(ix, 'accounts') and hasattr(message, 'account_keys'):
                for acc_idx in ix.accounts:
                    if acc_idx < len(message.account_keys):
                        acc_key = str(message.account_keys[acc_idx])
                        if self._is_likely_oracle(acc_key):
                            self.oracle_accounts.add(acc_key)
        except Exception:
            pass

    def _is_likely_oracle(self, account_key: str) -> bool:
        """Check if account is likely an oracle"""
        # Pyth oracles typically start with certain patterns
        pyth_patterns = ['J8', 'H6', 'Gn', 'E4', '3v', 'AF', '7y']
        return any(account_key.startswith(pattern) for pattern_key in pyth_patterns)

    def _analyze_patterns_fast(self):
        """Quick pattern analysis with error handling"""
        print("🔍 Analyzing instruction patterns...")

        try:
            total_instructions = sum(inst.frequency for inst in self.instructions.values())

            # Mark critical instructions
            for inst in self.instructions.values():
                if total_instructions > 0:
                    inst.is_critical = (inst.frequency / total_instructions) > 0.1

            # Create state patterns
            self.state_patterns = {
                "total_unique_instructions": len(self.instructions),
                "total_instruction_calls": total_instructions,
                "swap_instructions": len([i for i in self.instructions.values() if "swap" in i.name]),
                "admin_instructions": len([i for i in self.instructions.values() if "admin" in i.name]),
                "oracle_accounts_detected": len(self.oracle_accounts),
                "total_swaps_detected": len(self.swaps),
                "raw_discriminators_found": len(self.raw_discriminators),
                "error_rate": (self.errors / max(1, self.processed_txs)) * 100
            }

        except Exception as e:
            print(f"⚠️ Pattern analysis error: {e}")

    def _create_results(self, status: str) -> AnalysisResults:
        """Create analysis results with error information"""
        processing_time = time.time() - self.start_time

        coverage_stats = {
            "processed_transactions": self.processed_txs,
            "errors": self.errors,
            "error_rate_percent": round((self.errors / max(1, self.processed_txs)) * 100, 2),
            "instructions_found": len(self.instructions),
            "swaps_found": len(self.swaps),
            "raw_discriminators": len(self.raw_discriminators),
            "oracle_accounts": len(self.oracle_accounts),
            "processing_time_seconds": round(processing_time, 2),
            "status": status,
            "error_samples": self.error_details[:5]  # First 5 error details
        }

        return AnalysisResults(
            instructions=self.instructions,
            swaps=self.swaps,
            state_patterns=self.state_patterns,
            oracle_usage={acc: 1 for acc in self.oracle_accounts},
            processing_time=processing_time,
            coverage_stats=coverage_stats,
            raw_discriminators=self.raw_discriminators
        )

# Main function for direct execution
async def main():
    """Main execution for robust analyzer"""
    print("=" * 60)
    print("🛡️ ROBUST LIFINITY V2 ANALYZER")
    print("🚀 Enhanced error handling and parsing")
    print("=" * 60)

    try:
        analyzer = RobustAnalyzer()
        results = await analyzer.analyze_incremental(max_time=30)

        # Quick report
        print(f"\n📊 ANALYSIS SUMMARY:")
        print(f"⏱️  Time: {results.processing_time:.2f}s")
        print(f"📈 Processed: {results.coverage_stats['processed_transactions']} transactions")
        print(f"❌ Errors: {results.coverage_stats['errors']} ({results.coverage_stats['error_rate_percent']}%)")
        print(f"🔍 Instructions: {len(results.instructions)}")
        print(f"🔄 Swaps: {len(results.swaps)}")
        print(f"🗝️ Raw discriminators: {len(results.raw_discriminators)}")

        if results.instructions:
            print(f"\n🔥 TOP INSTRUCTIONS:")
            sorted_insts = sorted(results.instructions.values(), key=lambda x: x.frequency, reverse=True)
            for inst in sorted_insts[:5]:
                print(f"  {inst.name}: {inst.frequency} calls")

        if results.raw_discriminators:
            print(f"\n🗝️ DISCRIMINATORS FOUND:")
            for disc in list(results.raw_discriminators)[:10]:
                print(f"  {disc}")

        return results

    except Exception as e:
        print(f"❌ Fatal error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(main())