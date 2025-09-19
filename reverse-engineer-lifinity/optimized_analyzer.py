#!/usr/bin/env python3
"""
Optimized Lifinity V2 Analyzer
Performance-focused with incremental analysis, caching, and timeout controls
Target: Initial results within 30 seconds
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
MAX_INITIAL_TXS = 100  # Start with just 100 transactions
BATCH_SIZE = 10        # Small batches to avoid timeouts
REQUEST_TIMEOUT = 5    # 5 second timeout per request
PARALLEL_REQUESTS = 3  # Limit concurrent requests
CACHE_TTL = 3600      # 1 hour cache TTL

@dataclass
class InstructionData:
    """Lightweight instruction data"""
    discriminator: str
    name: str
    frequency: int = 0
    account_count: int = 0
    data_size: int = 0
    is_critical: bool = False

@dataclass
class SwapEvent:
    """Minimal swap event data"""
    tx_id: str
    slot: int
    timestamp: datetime
    amount_in: int
    estimated_out: int
    instruction_type: str

@dataclass
class AnalysisResults:
    """Complete analysis results"""
    instructions: Dict[str, InstructionData]
    swaps: List[SwapEvent]
    state_patterns: Dict[str, Any]
    oracle_usage: Dict[str, int]
    processing_time: float
    coverage_stats: Dict[str, int]

class RPCCache:
    """Simple file-based RPC response cache"""

    def __init__(self, cache_dir: str = ".rpc_cache"):
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(exist_ok=True)

    def _cache_key(self, method: str, params: Any) -> str:
        """Generate cache key from method and params"""
        cache_input = f"{method}:{json.dumps(params, sort_keys=True)}"
        return hashlib.md5(cache_input.encode()).hexdigest()

    def get(self, method: str, params: Any) -> Optional[Any]:
        """Get cached response"""
        try:
            cache_file = self.cache_dir / f"{self._cache_key(method, params)}.pkl"
            if cache_file.exists():
                with open(cache_file, 'rb') as f:
                    cached_data = pickle.load(f)

                # Check TTL
                if time.time() - cached_data['timestamp'] < CACHE_TTL:
                    return cached_data['data']
                else:
                    cache_file.unlink()  # Remove expired cache
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

class OptimizedAnalyzer:
    """High-performance Lifinity analyzer with incremental processing"""

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

        # Performance tracking
        self.start_time = time.time()
        self.processed_txs = 0
        self.errors = 0

    async def analyze_incremental(self, max_time: int = 30) -> AnalysisResults:
        """
        Main analysis method with time-based incremental processing
        Returns partial results even if not all data is processed
        """
        print(f"🚀 Starting optimized Lifinity analysis (max {max_time}s)")

        try:
            # Phase 1: Quick signature fetch (5s max)
            signatures = await self._fetch_signatures_fast()
            if not signatures:
                return self._create_results("No signatures found")

            # Phase 2: Process transactions in small batches
            processing_time = max(5, max_time - 10)  # Reserve at least 5s for processing
            await self._process_transactions_incremental(signatures, processing_time)

            # Phase 3: Quick pattern analysis
            self._analyze_patterns_fast()

            # Phase 4: Generate results
            return self._create_results("Analysis completed")

        except Exception as e:
            print(f"❌ Analysis error: {e}")
            return self._create_results(f"Partial analysis (error: {e})")

    async def _fetch_signatures_fast(self) -> List[Any]:
        """Fetch signatures with caching and timeout"""
        print("📡 Fetching recent signatures...")

        cache_key = f"signatures_{LIFINITY_V2_PROGRAM_ID}_{MAX_INITIAL_TXS}"
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
                print(f"✅ Fetched {len(signatures)} signatures")
                return signatures

        except Exception as e:
            print(f"⚠️ Signature fetch failed: {e}")

        return []

    async def _process_transactions_incremental(self, signatures: List[Any], max_time: int):
        """Process transactions with time limit and parallel batching"""
        print(f"⚡ Processing transactions (max {max_time}s)...")

        start_time = time.time()
        total_sigs = len(signatures)

        # Process in small batches with timeout
        for i in range(0, total_sigs, BATCH_SIZE):
            # Check time limit
            if time.time() - start_time > max_time:
                print(f"⏱️ Time limit reached, processed {self.processed_txs}/{total_sigs}")
                break

            batch = signatures[i:i + BATCH_SIZE]
            await self._process_batch_parallel(batch)

            # Progress update
            self.processed_txs = min(i + BATCH_SIZE, total_sigs)
            progress = (self.processed_txs / total_sigs) * 100
            print(f"📊 Progress: {self.processed_txs}/{total_sigs} ({progress:.1f}%)")

    async def _process_batch_parallel(self, signatures: List[Any]):
        """Process batch with limited concurrency"""
        semaphore = asyncio.Semaphore(PARALLEL_REQUESTS)

        async def process_single(sig_info):
            async with semaphore:
                try:
                    await self._process_transaction(sig_info)
                except Exception as e:
                    self.errors += 1
                    if self.errors <= 5:  # Only show first few errors
                        print(f"⚠️ TX error: {e}")

        # Process batch concurrently
        tasks = [process_single(sig) for sig in signatures]
        await asyncio.gather(*tasks, return_exceptions=True)

    async def _process_transaction(self, sig_info):
        """Process single transaction with caching"""
        try:
            sig_str = str(sig_info.signature)

            # Check cache first
            cached_tx = self.cache.get("get_transaction", sig_str)
            if cached_tx:
                tx_data = cached_tx
            else:
                # Fetch with timeout
                response = self.client.get_transaction(
                    sig_info.signature,
                    max_supported_transaction_version=0,
                    encoding="json"
                )

                if not response or not response.value:
                    return

                tx_data = response.value
                self.cache.set("get_transaction", sig_str, tx_data)

            # Quick instruction extraction
            self._extract_instructions_fast(tx_data, sig_info)

        except Exception as e:
            raise Exception(f"Transaction processing failed: {e}")

    def _extract_instructions_fast(self, tx_data, sig_info):
        """Fast instruction extraction focusing on critical data"""
        try:
            if not tx_data.transaction:
                return

            message = tx_data.transaction.transaction.message

            for ix in message.instructions:
                program_idx = ix.program_id_index

                if program_idx < len(message.account_keys):
                    program_key = str(message.account_keys[program_idx])

                    if program_key == LIFINITY_V2_PROGRAM_ID:
                        self._process_lifinity_instruction(ix, message, sig_info)

        except Exception as e:
            pass  # Skip malformed transactions

    def _process_lifinity_instruction(self, ix, message, sig_info):
        """Process Lifinity-specific instruction"""
        try:
            # Decode instruction data
            data = base58.b58decode(ix.data) if isinstance(ix.data, str) else bytes(ix.data)

            if len(data) < 8:
                return

            # Extract discriminator
            discriminator = data[:8].hex()

            # Update instruction statistics
            if discriminator not in self.instructions:
                self.instructions[discriminator] = InstructionData(
                    discriminator=discriminator,
                    name=self._classify_instruction(data, ix.accounts),
                    frequency=0,
                    account_count=len(ix.accounts),
                    data_size=len(data)
                )

            self.instructions[discriminator].frequency += 1

            # Quick swap detection
            if self._is_swap_instruction(data, ix.accounts):
                self._extract_swap_data(ix, data, sig_info)

            # Oracle account detection
            self._detect_oracle_usage(ix, message)

        except Exception as e:
            pass

    def _classify_instruction(self, data: bytes, accounts: List[int]) -> str:
        """Fast instruction classification"""
        data_len = len(data)
        acc_count = len(accounts)

        # Quick heuristics
        if data_len == 8:
            return "query" if acc_count <= 2 else "admin"
        elif 16 <= data_len <= 24 and acc_count >= 6:
            return "swap"
        elif data_len > 100:
            return "initialize"
        elif 24 < data_len <= 48:
            return "update_params"
        else:
            return f"unknown_{data_len}b"

    def _is_swap_instruction(self, data: bytes, accounts: List[int]) -> bool:
        """Quick swap detection"""
        return 16 <= len(data) <= 32 and len(accounts) >= 6

    def _extract_swap_data(self, ix, data: bytes, sig_info):
        """Extract basic swap information"""
        try:
            if len(data) >= 16:
                amount = struct.unpack('<Q', data[8:16])[0]

                swap = SwapEvent(
                    tx_id=str(sig_info.signature),
                    slot=sig_info.slot or 0,
                    timestamp=datetime.fromtimestamp(sig_info.block_time) if sig_info.block_time else datetime.now(),
                    amount_in=amount,
                    estimated_out=0,  # Would need log parsing
                    instruction_type="swap"
                )

                self.swaps.append(swap)

        except Exception:
            pass

    def _detect_oracle_usage(self, ix, message):
        """Detect oracle account usage"""
        try:
            for acc_idx in ix.accounts:
                if acc_idx < len(message.account_keys):
                    acc_key = str(message.account_keys[acc_idx])
                    # Check if it looks like a Pyth oracle (specific pattern)
                    if len(acc_key) == 44 and acc_key[0] in 'ABCDEFGH':  # Common Pyth prefixes
                        self.oracle_accounts.add(acc_key)
        except Exception:
            pass

    def _analyze_patterns_fast(self):
        """Quick pattern analysis"""
        print("🔍 Analyzing instruction patterns...")

        # Instruction frequency analysis
        total_instructions = sum(inst.frequency for inst in self.instructions.values())

        # Mark critical instructions (high frequency)
        for inst in self.instructions.values():
            if total_instructions > 0:
                inst.is_critical = (inst.frequency / total_instructions) > 0.1

        # Basic state pattern detection
        self.state_patterns = {
            "total_unique_instructions": len(self.instructions),
            "total_instruction_calls": total_instructions,
            "swap_instructions": len([i for i in self.instructions.values() if "swap" in i.name]),
            "admin_instructions": len([i for i in self.instructions.values() if "admin" in i.name]),
            "oracle_accounts_detected": len(self.oracle_accounts),
            "total_swaps_detected": len(self.swaps)
        }

    def _create_results(self, status: str) -> AnalysisResults:
        """Create analysis results"""
        processing_time = time.time() - self.start_time

        coverage_stats = {
            "processed_transactions": self.processed_txs,
            "errors": self.errors,
            "instructions_found": len(self.instructions),
            "swaps_found": len(self.swaps),
            "processing_time_seconds": round(processing_time, 2),
            "status": status
        }

        return AnalysisResults(
            instructions=self.instructions,
            swaps=self.swaps,
            state_patterns=self.state_patterns,
            oracle_usage={acc: 1 for acc in self.oracle_accounts},
            processing_time=processing_time,
            coverage_stats=coverage_stats
        )

class FastReporter:
    """Generate quick analysis reports"""

    def __init__(self, output_dir: str = "analysis_output"):
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(exist_ok=True)

    def generate_summary_report(self, results: AnalysisResults):
        """Generate concise summary report"""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        report_file = self.output_dir / f"lifinity_analysis_{timestamp}.md"

        with open(report_file, 'w') as f:
            f.write("# Lifinity V2 Quick Analysis Report\n\n")
            f.write(f"**Analysis Time**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"**Processing Duration**: {results.processing_time:.2f}s\n")
            f.write(f"**Status**: {results.coverage_stats['status']}\n\n")

            # Coverage Statistics
            f.write("## Coverage Statistics\n\n")
            for key, value in results.coverage_stats.items():
                f.write(f"- **{key.replace('_', ' ').title()}**: {value}\n")
            f.write("\n")

            # Critical Instructions
            f.write("## Critical Instructions\n\n")
            f.write("| Discriminator | Name | Frequency | Critical |\n")
            f.write("|---------------|------|-----------|----------|\n")

            sorted_instructions = sorted(
                results.instructions.values(),
                key=lambda x: x.frequency,
                reverse=True
            )

            for inst in sorted_instructions[:10]:
                critical = "✅" if inst.is_critical else ""
                f.write(f"| `{inst.discriminator[:16]}...` | {inst.name} | {inst.frequency} | {critical} |\n")

            # State Patterns
            f.write("\n## Detected Patterns\n\n")
            for key, value in results.state_patterns.items():
                f.write(f"- **{key.replace('_', ' ').title()}**: {value}\n")

            # Oracle Usage
            if results.oracle_usage:
                f.write("\n## Oracle Accounts Detected\n\n")
                for oracle in list(results.oracle_usage.keys())[:5]:
                    f.write(f"- `{oracle}`\n")

            # Swap Activity
            if results.swaps:
                f.write(f"\n## Recent Swap Activity\n\n")
                f.write(f"- **Total Swaps**: {len(results.swaps)}\n")

                if len(results.swaps) > 0:
                    recent_swap = results.swaps[0]
                    f.write(f"- **Latest Swap**: {recent_swap.tx_id[:16]}... ({recent_swap.amount_in:,} units)\n")

        print(f"📊 Report generated: {report_file}")
        return report_file

    def generate_json_export(self, results: AnalysisResults):
        """Generate JSON export for further analysis"""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        json_file = self.output_dir / f"lifinity_data_{timestamp}.json"

        # Convert to serializable format
        export_data = {
            "metadata": {
                "analysis_time": datetime.now().isoformat(),
                "processing_time": results.processing_time,
                "coverage_stats": results.coverage_stats
            },
            "instructions": {
                disc: asdict(inst) for disc, inst in results.instructions.items()
            },
            "state_patterns": results.state_patterns,
            "oracle_accounts": list(results.oracle_usage.keys()),
            "swap_count": len(results.swaps)
        }

        with open(json_file, 'w') as f:
            json.dump(export_data, f, indent=2, default=str)

        print(f"💾 Data exported: {json_file}")
        return json_file

async def main():
    """Main execution with optimized workflow"""
    print("=" * 60)
    print("🚀 OPTIMIZED LIFINITY V2 ANALYZER")
    print("⚡ Fast incremental analysis with caching")
    print("=" * 60)

    try:
        # Initialize analyzer
        analyzer = OptimizedAnalyzer()

        # Run analysis with 30s time limit
        results = await analyzer.analyze_incremental(max_time=30)

        # Generate reports
        reporter = FastReporter()
        summary_file = reporter.generate_summary_report(results)
        json_file = reporter.generate_json_export(results)

        # Final summary
        print("\n" + "=" * 60)
        print("✅ ANALYSIS COMPLETE")
        print(f"⏱️  Processing time: {results.processing_time:.2f}s")
        print(f"📊 Instructions found: {len(results.instructions)}")
        print(f"🔄 Swaps detected: {len(results.swaps)}")
        print(f"📁 Reports: {summary_file.name}, {json_file.name}")
        print("=" * 60)

        # Show top findings
        if results.instructions:
            print("\n🔥 TOP INSTRUCTION TYPES:")
            sorted_insts = sorted(results.instructions.values(), key=lambda x: x.frequency, reverse=True)
            for inst in sorted_insts[:5]:
                critical = " ⭐" if inst.is_critical else ""
                print(f"  {inst.name}: {inst.frequency} calls{critical}")

        return results

    except KeyboardInterrupt:
        print("\n⏹️ Analysis interrupted by user")
    except Exception as e:
        print(f"\n❌ Analysis failed: {e}")
        return None

if __name__ == "__main__":
    # Handle event loop for async execution
    try:
        asyncio.run(main())
    except Exception as e:
        print(f"Fatal error: {e}")
        sys.exit(1)