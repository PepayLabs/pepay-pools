#!/usr/bin/env python3
"""
Final Optimized Lifinity V2 Analyzer
Production-ready version with comprehensive analysis and reporting
Target: Initial results within 30 seconds, expandable for deeper analysis
"""

import asyncio
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
import base58

# Constants
LIFINITY_V2_PROGRAM_ID = "2wT8Yq49kHgDzXuPxZSaeLaH1qbmGXtEyPy64bL7aD3c"
RPC_ENDPOINTS = [
    "https://api.mainnet-beta.solana.com",
    "https://solana-mainnet.g.alchemy.com/v2/demo",
    "https://rpc.ankr.com/solana"
]

# Known oracle patterns for better detection
KNOWN_ORACLE_PATTERNS = [
    "J83w4HKfqxwcq3BEMMkPFSppX3gqekLyLJBexebFVkix",  # SOL/USD
    "Gnt27xtC473ZT2Mw5u8wZ68Z3gULkSTb5DuxJy7eJotD",  # USDC/USD
    "3vxLXJqLqF3JG5TCbYycbKWRBbCJQLxQmBGCkyqEEefL",  # USDT/USD
    "E4v1BBgoso9s64TjV1viAycbvG2QBGJZPIDjRn9YPUn",  # mSOL/USD
    "7yyaeuJ1GGtVBLT2z2xub5ZWYKaNhF28mj1RdV4VDFVk", # JitoSOL/USD
    "AFrYBhb5wKQtxRS9UA9YRS4V3dwFm7SqmS6DHKq6YVgo"  # bSOL/USD
]

# Performance Configuration
MAX_INITIAL_TXS = 100
BATCH_SIZE = 5
REQUEST_TIMEOUT = 10
PARALLEL_REQUESTS = 2
CACHE_TTL = 3600

@dataclass
class InstructionData:
    """Comprehensive instruction data"""
    discriminator: str
    name: str
    frequency: int = 0
    account_count: int = 0
    data_size: int = 0
    is_critical: bool = False
    sample_data: str = ""
    confidence: float = 0.0  # Classification confidence
    oracle_interactions: int = 0
    token_interactions: int = 0

@dataclass
class SwapEvent:
    """Detailed swap event data"""
    tx_id: str
    slot: int
    timestamp: datetime
    amount_in: int = 0
    estimated_out: int = 0
    instruction_type: str = "unknown"
    oracle_account: str = ""
    fee_estimated: int = 0

@dataclass
class OracleInteraction:
    """Oracle usage data"""
    oracle_account: str
    usage_count: int = 0
    last_seen: datetime = field(default_factory=datetime.now)
    associated_swaps: int = 0

@dataclass
class AnalysisResults:
    """Comprehensive analysis results"""
    instructions: Dict[str, InstructionData]
    swaps: List[SwapEvent]
    oracles: Dict[str, OracleInteraction]
    state_patterns: Dict[str, Any]
    processing_time: float
    coverage_stats: Dict[str, int]
    raw_discriminators: Set[str]
    critical_findings: List[str]

class PerformanceCache:
    """High-performance caching system"""

    def __init__(self, cache_dir: str = ".lifinity_cache"):
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(exist_ok=True)
        self.memory_cache = {}  # In-memory cache for session

    def _cache_key(self, method: str, params: Any) -> str:
        """Generate cache key"""
        cache_input = f"{method}:{json.dumps(params, sort_keys=True, default=str)}"
        return hashlib.md5(cache_input.encode()).hexdigest()[:16]

    def get(self, method: str, params: Any) -> Optional[Any]:
        """Get cached response with memory + disk"""
        key = self._cache_key(method, params)

        # Check memory cache first
        if key in self.memory_cache:
            return self.memory_cache[key]

        # Check disk cache
        try:
            cache_file = self.cache_dir / f"{key}.pkl"
            if cache_file.exists():
                with open(cache_file, 'rb') as f:
                    cached_data = pickle.load(f)

                if time.time() - cached_data['timestamp'] < CACHE_TTL:
                    # Load into memory cache
                    self.memory_cache[key] = cached_data['data']
                    return cached_data['data']
                else:
                    cache_file.unlink()
        except Exception:
            pass

        return None

    def set(self, method: str, params: Any, data: Any):
        """Cache response in memory + disk"""
        key = self._cache_key(method, params)

        # Store in memory
        self.memory_cache[key] = data

        # Store on disk
        try:
            cache_file = self.cache_dir / f"{key}.pkl"
            with open(cache_file, 'wb') as f:
                pickle.dump({
                    'timestamp': time.time(),
                    'data': data
                }, f)
        except Exception:
            pass

class FinalOptimizedAnalyzer:
    """Production-ready Lifinity analyzer"""

    def __init__(self, rpc_url: str = None, enable_cache: bool = True):
        self.rpc_url = rpc_url or RPC_ENDPOINTS[0]
        self.client = Client(self.rpc_url)
        self.cache = PerformanceCache() if enable_cache else None
        self.program_id = Pubkey.from_string(LIFINITY_V2_PROGRAM_ID)

        # Analysis state
        self.instructions: Dict[str, InstructionData] = {}
        self.swaps: List[SwapEvent] = []
        self.oracles: Dict[str, OracleInteraction] = {}
        self.raw_discriminators: Set[str] = set()
        self.critical_findings: List[str] = []

        # Performance tracking
        self.start_time = time.time()
        self.processed_txs = 0
        self.successful_txs = 0
        self.errors = 0
        self.error_details = []

    async def analyze_incremental(self, max_time: int = 30, focus_areas: List[str] = None) -> AnalysisResults:
        """
        Main analysis method with configurable focus areas
        focus_areas: ['instructions', 'swaps', 'oracles', 'state']
        """
        print(f"🚀 Starting comprehensive Lifinity analysis (max {max_time}s)")
        if focus_areas:
            print(f"🎯 Focus areas: {', '.join(focus_areas)}")

        try:
            # Phase 1: Signature collection (5s max)
            signatures = await self._collect_signatures()
            if not signatures:
                return self._create_results("No signatures found")

            # Phase 2: Transaction processing (80% of time)
            processing_time = max(10, int(max_time * 0.8))
            await self._process_transactions_optimized(signatures, processing_time)

            # Phase 3: Analysis and pattern detection (remaining time)
            await self._analyze_patterns_comprehensive(focus_areas)

            # Phase 4: Generate insights
            self._generate_critical_findings()

            return self._create_results("Analysis completed successfully")

        except Exception as e:
            print(f"❌ Critical error: {e}")
            return self._create_results(f"Analysis failed: {e}")

    async def _collect_signatures(self) -> List[Any]:
        """Optimized signature collection with caching"""
        print("📡 Collecting transaction signatures...")

        cache_key = f"recent_sigs_{MAX_INITIAL_TXS}"
        if self.cache:
            cached = self.cache.get("signatures", cache_key)
            if cached:
                print(f"🎯 Using cached signatures ({len(cached)} found)")
                return cached

        try:
            response = self.client.get_signatures_for_address(
                self.program_id,
                limit=MAX_INITIAL_TXS
            )

            if response and response.value:
                signatures = response.value
                if self.cache:
                    self.cache.set("signatures", cache_key, signatures)
                print(f"✅ Collected {len(signatures)} signatures")
                return signatures

        except Exception as e:
            print(f"⚠️ Signature collection failed: {e}")

        return []

    async def _process_transactions_optimized(self, signatures: List[Any], max_time: int):
        """Optimized transaction processing with smart batching"""
        print(f"⚡ Processing transactions (max {max_time}s)...")

        start_time = time.time()
        total_sigs = len(signatures)

        for i in range(0, total_sigs, BATCH_SIZE):
            # Time check
            if time.time() - start_time > max_time:
                print(f"⏱️ Time limit reached")
                break

            batch = signatures[i:i + BATCH_SIZE]
            batch_success = await self._process_batch_smart(batch)

            # Update stats
            self.processed_txs += len(batch)
            self.successful_txs += batch_success

            # Progress reporting
            progress = (self.processed_txs / total_sigs) * 100
            success_rate = (self.successful_txs / max(1, self.processed_txs)) * 100

            print(f"📊 {self.processed_txs}/{total_sigs} ({progress:.1f}%) "
                  f"Success: {success_rate:.1f}% "
                  f"Instructions: {len(self.instructions)} "
                  f"Swaps: {len(self.swaps)}")

            # Adaptive delay based on error rate
            if self.errors > self.processed_txs * 0.5:
                await asyncio.sleep(0.5)

    async def _process_batch_smart(self, signatures: List[Any]) -> int:
        """Smart batch processing with error isolation"""
        successful = 0

        for sig_info in signatures:
            try:
                if await self._process_transaction_smart(sig_info):
                    successful += 1
            except Exception as e:
                self.errors += 1
                if len(self.error_details) < 5:
                    self.error_details.append(str(e)[:100])

        return successful

    async def _process_transaction_smart(self, sig_info) -> bool:
        """Smart transaction processing with multiple strategies"""
        try:
            sig_str = str(sig_info.signature)

            # Check cache
            tx_data = None
            if self.cache:
                tx_data = self.cache.get("transaction", sig_str)

            if not tx_data:
                tx_data = await self._fetch_transaction_multi_strategy(sig_info.signature)
                if not tx_data:
                    return False

                if self.cache:
                    self.cache.set("transaction", sig_str, tx_data)

            # Process with comprehensive extraction
            return self._extract_data_comprehensive(tx_data, sig_info)

        except Exception:
            return False

    async def _fetch_transaction_multi_strategy(self, signature) -> Optional[Any]:
        """Multi-strategy transaction fetching"""
        strategies = [
            {"encoding": "json", "max_supported_transaction_version": 0},
            {"encoding": "jsonParsed", "max_supported_transaction_version": 0},
        ]

        for strategy in strategies:
            try:
                response = self.client.get_transaction(signature, **strategy)
                if response and response.value:
                    return response.value
            except:
                continue

        return None

    def _extract_data_comprehensive(self, tx_data, sig_info) -> bool:
        """Comprehensive data extraction from transactions"""
        try:
            found_lifinity = False

            # Multiple parsing strategies
            message = None
            if hasattr(tx_data, 'transaction'):
                if hasattr(tx_data.transaction, 'transaction'):
                    message = tx_data.transaction.transaction.message
                else:
                    message = tx_data.transaction.message

            if message and hasattr(message, 'instructions'):
                for ix in message.instructions:
                    if self._is_lifinity_instruction(ix, message):
                        self._process_lifinity_instruction_comprehensive(ix, message, sig_info)
                        found_lifinity = True

            return found_lifinity

        except Exception:
            return False

    def _is_lifinity_instruction(self, ix, message) -> bool:
        """Check if instruction belongs to Lifinity program"""
        try:
            program_idx = ix.program_id_index
            if program_idx < len(message.account_keys):
                program_key = str(message.account_keys[program_idx])
                return program_key == LIFINITY_V2_PROGRAM_ID
        except:
            pass
        return False

    def _process_lifinity_instruction_comprehensive(self, ix, message, sig_info):
        """Comprehensive Lifinity instruction processing"""
        try:
            # Extract instruction data
            data = self._extract_instruction_data(ix)
            if not data or len(data) < 8:
                return

            discriminator = data[:8].hex()
            self.raw_discriminators.add(discriminator)

            # Get accounts
            accounts = getattr(ix, 'accounts', [])

            # Comprehensive instruction analysis
            self._analyze_instruction_comprehensive(discriminator, data, accounts, message, sig_info)

            # Detect specific patterns
            self._detect_swap_patterns(discriminator, data, accounts, message, sig_info)
            self._detect_oracle_patterns(accounts, message)

        except Exception:
            pass

    def _extract_instruction_data(self, ix) -> Optional[bytes]:
        """Extract instruction data from various formats"""
        try:
            if hasattr(ix, 'data'):
                if isinstance(ix.data, str):
                    return base58.b58decode(ix.data)
                elif isinstance(ix.data, bytes):
                    return ix.data
                else:
                    return bytes(ix.data)
        except:
            pass
        return None

    def _analyze_instruction_comprehensive(self, discriminator: str, data: bytes, accounts: List, message, sig_info):
        """Comprehensive instruction analysis"""
        if discriminator not in self.instructions:
            name, confidence = self._classify_instruction_advanced(data, accounts)

            self.instructions[discriminator] = InstructionData(
                discriminator=discriminator,
                name=name,
                frequency=0,
                account_count=len(accounts),
                data_size=len(data),
                sample_data=data[:32].hex(),
                confidence=confidence,
                oracle_interactions=0,
                token_interactions=0
            )

        # Update statistics
        inst = self.instructions[discriminator]
        inst.frequency += 1

        # Analyze account interactions
        oracle_count, token_count = self._analyze_account_patterns(accounts, message)
        inst.oracle_interactions += oracle_count
        inst.token_interactions += token_count

    def _classify_instruction_advanced(self, data: bytes, accounts: List) -> Tuple[str, float]:
        """Advanced instruction classification with confidence scores"""
        data_len = len(data)
        acc_count = len(accounts)

        # High confidence patterns
        if data_len == 8 and acc_count <= 2:
            return "query_state", 0.9
        elif data_len == 16 and acc_count >= 6 and acc_count <= 10:
            return "swap_exact_input", 0.85
        elif data_len == 24 and acc_count >= 6 and acc_count <= 10:
            return "swap_exact_output", 0.85
        elif data_len > 100 and acc_count >= 10:
            return "initialize_pool", 0.9
        elif 40 <= data_len <= 80 and acc_count >= 5:
            return "update_pool_params", 0.8
        elif data_len == 8 and acc_count >= 3:
            return "admin_action", 0.7

        # Medium confidence patterns
        elif 16 <= data_len <= 32:
            if acc_count >= 6:
                return "complex_swap", 0.6
            else:
                return "token_operation", 0.5
        elif 32 < data_len <= 64:
            return "pool_management", 0.5

        # Low confidence
        return f"unknown_{data_len}b_{acc_count}acc", 0.1

    def _detect_swap_patterns(self, discriminator: str, data: bytes, accounts: List, message, sig_info):
        """Detect and analyze swap patterns"""
        if not self._is_likely_swap(data, accounts):
            return

        try:
            # Extract swap amount
            amount_in = 0
            if len(data) >= 16:
                amount_in = struct.unpack('<Q', data[8:16])[0]

            # Find oracle account in this transaction
            oracle_account = self._find_oracle_in_accounts(accounts, message)

            swap = SwapEvent(
                tx_id=str(sig_info.signature),
                slot=sig_info.slot or 0,
                timestamp=datetime.fromtimestamp(sig_info.block_time) if sig_info.block_time else datetime.now(),
                amount_in=amount_in,
                instruction_type=self.instructions.get(discriminator, InstructionData("", "")).name,
                oracle_account=oracle_account,
                fee_estimated=self._estimate_fee(amount_in)
            )

            self.swaps.append(swap)

            # Update oracle interaction count
            if oracle_account and oracle_account in self.oracles:
                self.oracles[oracle_account].associated_swaps += 1

        except Exception:
            pass

    def _is_likely_swap(self, data: bytes, accounts: List) -> bool:
        """Enhanced swap detection"""
        return (16 <= len(data) <= 40 and
                6 <= len(accounts) <= 15)

    def _find_oracle_in_accounts(self, accounts: List, message) -> str:
        """Find oracle account in transaction accounts"""
        try:
            for acc_idx in accounts:
                if acc_idx < len(message.account_keys):
                    acc_key = str(message.account_keys[acc_idx])
                    if self._is_known_oracle(acc_key):
                        return acc_key
        except:
            pass
        return ""

    def _is_known_oracle(self, account_key: str) -> bool:
        """Check if account is a known oracle"""
        return account_key in KNOWN_ORACLE_PATTERNS

    def _estimate_fee(self, amount: int) -> int:
        """Estimate fee based on amount (typical AMM fee 0.3%)"""
        return int(amount * 0.003) if amount > 0 else 0

    def _detect_oracle_patterns(self, accounts: List, message):
        """Detect and track oracle usage patterns"""
        try:
            for acc_idx in accounts:
                if acc_idx < len(message.account_keys):
                    acc_key = str(message.account_keys[acc_idx])

                    if self._is_known_oracle(acc_key):
                        if acc_key not in self.oracles:
                            self.oracles[acc_key] = OracleInteraction(
                                oracle_account=acc_key,
                                usage_count=0,
                                last_seen=datetime.now(),
                                associated_swaps=0
                            )

                        self.oracles[acc_key].usage_count += 1
                        self.oracles[acc_key].last_seen = datetime.now()

        except Exception:
            pass

    def _analyze_account_patterns(self, accounts: List, message) -> Tuple[int, int]:
        """Analyze account patterns to identify oracle and token interactions"""
        oracle_count = 0
        token_count = 0

        try:
            for acc_idx in accounts:
                if acc_idx < len(message.account_keys):
                    acc_key = str(message.account_keys[acc_idx])

                    if self._is_known_oracle(acc_key):
                        oracle_count += 1
                    elif self._is_likely_token_account(acc_key):
                        token_count += 1

        except Exception:
            pass

        return oracle_count, token_count

    def _is_likely_token_account(self, account_key: str) -> bool:
        """Check if account is likely a token account"""
        # SPL token accounts typically have certain patterns
        known_token_programs = [
            "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",  # Token program
            "11111111111111111111111111111111",                # System program
        ]
        return account_key in known_token_programs

    async def _analyze_patterns_comprehensive(self, focus_areas: List[str] = None):
        """Comprehensive pattern analysis"""
        print("🔍 Analyzing patterns comprehensively...")

        # Mark critical instructions
        total_instructions = sum(inst.frequency for inst in self.instructions.values())
        for inst in self.instructions.values():
            if total_instructions > 0:
                frequency_ratio = inst.frequency / total_instructions
                inst.is_critical = (frequency_ratio > 0.1 or
                                  inst.frequency > 10 or
                                  inst.confidence > 0.8)

    def _generate_critical_findings(self):
        """Generate critical findings and insights"""
        self.critical_findings = []

        # High frequency instructions
        high_freq_instructions = [inst for inst in self.instructions.values() if inst.frequency > 5]
        if high_freq_instructions:
            self.critical_findings.append(f"Found {len(high_freq_instructions)} high-frequency instructions")

        # Swap activity
        if len(self.swaps) > 0:
            total_volume = sum(swap.amount_in for swap in self.swaps)
            avg_volume = total_volume / len(self.swaps)
            self.critical_findings.append(f"Detected {len(self.swaps)} swaps with avg volume: {avg_volume:,.0f}")

        # Oracle usage
        if len(self.oracles) > 0:
            active_oracles = [oracle for oracle in self.oracles.values() if oracle.usage_count > 1]
            self.critical_findings.append(f"Active oracles: {len(active_oracles)}/{len(self.oracles)}")

        # Instruction diversity
        if len(self.raw_discriminators) > 5:
            self.critical_findings.append(f"High instruction diversity: {len(self.raw_discriminators)} unique discriminators")

    def _create_results(self, status: str) -> AnalysisResults:
        """Create comprehensive analysis results"""
        processing_time = time.time() - self.start_time

        # Generate state patterns
        state_patterns = {
            "total_unique_instructions": len(self.instructions),
            "total_instruction_calls": sum(inst.frequency for inst in self.instructions.values()),
            "high_confidence_instructions": len([i for i in self.instructions.values() if i.confidence > 0.8]),
            "swap_instructions": len([i for i in self.instructions.values() if "swap" in i.name]),
            "admin_instructions": len([i for i in self.instructions.values() if "admin" in i.name]),
            "oracle_accounts_detected": len(self.oracles),
            "total_swaps_detected": len(self.swaps),
            "total_swap_volume": sum(swap.amount_in for swap in self.swaps),
            "raw_discriminators_found": len(self.raw_discriminators),
            "error_rate_percent": round((self.errors / max(1, self.processed_txs)) * 100, 2),
            "success_rate_percent": round((self.successful_txs / max(1, self.processed_txs)) * 100, 2)
        }

        coverage_stats = {
            "processed_transactions": self.processed_txs,
            "successful_transactions": self.successful_txs,
            "errors": self.errors,
            "error_rate_percent": state_patterns["error_rate_percent"],
            "instructions_found": len(self.instructions),
            "swaps_found": len(self.swaps),
            "oracles_found": len(self.oracles),
            "raw_discriminators": len(self.raw_discriminators),
            "processing_time_seconds": round(processing_time, 2),
            "status": status,
            "critical_findings_count": len(self.critical_findings)
        }

        return AnalysisResults(
            instructions=self.instructions,
            swaps=self.swaps,
            oracles=self.oracles,
            state_patterns=state_patterns,
            processing_time=processing_time,
            coverage_stats=coverage_stats,
            raw_discriminators=self.raw_discriminators,
            critical_findings=self.critical_findings
        )

class ComprehensiveReporter:
    """Advanced reporting system"""

    def __init__(self, output_dir: str = "lifinity_analysis"):
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(exist_ok=True)

    def generate_full_report(self, results: AnalysisResults) -> str:
        """Generate comprehensive analysis report"""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        report_file = self.output_dir / f"lifinity_comprehensive_{timestamp}.md"

        with open(report_file, 'w') as f:
            self._write_executive_summary(f, results)
            self._write_instruction_analysis(f, results)
            self._write_swap_analysis(f, results)
            self._write_oracle_analysis(f, results)
            self._write_technical_details(f, results)
            self._write_critical_findings(f, results)

        print(f"📊 Comprehensive report: {report_file.name}")
        return str(report_file)

    def _write_executive_summary(self, f, results: AnalysisResults):
        """Write executive summary section"""
        f.write("# Lifinity V2 Comprehensive Analysis Report\n\n")
        f.write(f"**Analysis Time**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"**Processing Duration**: {results.processing_time:.2f}s\n")
        f.write(f"**Status**: {results.coverage_stats['status']}\n\n")

        f.write("## Executive Summary\n\n")
        f.write(f"- **Transactions Analyzed**: {results.coverage_stats['processed_transactions']}\n")
        f.write(f"- **Success Rate**: {results.state_patterns['success_rate_percent']:.1f}%\n")
        f.write(f"- **Unique Instructions**: {len(results.instructions)}\n")
        f.write(f"- **Swap Activity**: {len(results.swaps)} swaps detected\n")
        f.write(f"- **Oracle Integrations**: {len(results.oracles)} oracles\n")
        f.write(f"- **Critical Findings**: {len(results.critical_findings)}\n\n")

    def _write_instruction_analysis(self, f, results: AnalysisResults):
        """Write instruction analysis section"""
        f.write("## Instruction Analysis\n\n")

        # Summary table
        f.write("### Instruction Summary\n\n")
        f.write("| Discriminator | Name | Frequency | Confidence | Critical | Oracle Interactions |\n")
        f.write("|---------------|------|-----------|------------|----------|--------------------|\n")

        sorted_instructions = sorted(
            results.instructions.values(),
            key=lambda x: x.frequency,
            reverse=True
        )

        for inst in sorted_instructions[:15]:
            critical = "✅" if inst.is_critical else ""
            f.write(f"| `{inst.discriminator[:16]}...` | {inst.name} | {inst.frequency} | ")
            f.write(f"{inst.confidence:.2f} | {critical} | {inst.oracle_interactions} |\n")

        # High-confidence instructions
        high_conf = [i for i in results.instructions.values() if i.confidence > 0.8]
        if high_conf:
            f.write(f"\n### High-Confidence Instructions ({len(high_conf)} found)\n\n")
            for inst in sorted(high_conf, key=lambda x: x.frequency, reverse=True):
                f.write(f"- **{inst.name}** (`{inst.discriminator[:16]}...`): {inst.frequency} calls\n")
                f.write(f"  - Confidence: {inst.confidence:.2f}\n")
                f.write(f"  - Data size: {inst.data_size} bytes\n")
                f.write(f"  - Accounts: {inst.account_count}\n\n")

    def _write_swap_analysis(self, f, results: AnalysisResults):
        """Write swap analysis section"""
        f.write("## Swap Activity Analysis\n\n")

        if not results.swaps:
            f.write("No swap activity detected in analyzed transactions.\n\n")
            return

        f.write(f"**Total Swaps Detected**: {len(results.swaps)}\n")
        f.write(f"**Total Volume**: {results.state_patterns['total_swap_volume']:,} units\n")

        if len(results.swaps) > 0:
            amounts = [s.amount_in for s in results.swaps if s.amount_in > 0]
            if amounts:
                f.write(f"**Average Swap Size**: {sum(amounts) // len(amounts):,} units\n")
                f.write(f"**Largest Swap**: {max(amounts):,} units\n")
                f.write(f"**Smallest Swap**: {min(amounts):,} units\n\n")

        # Recent swaps
        f.write("### Recent Swap Transactions\n\n")
        f.write("| Transaction | Amount | Oracle Used | Estimated Fee | Type |\n")
        f.write("|-------------|--------|-------------|---------------|------|\n")

        for swap in results.swaps[:10]:
            oracle_short = swap.oracle_account[:8] + "..." if swap.oracle_account else "None"
            f.write(f"| `{swap.tx_id[:16]}...` | {swap.amount_in:,} | {oracle_short} | ")
            f.write(f"{swap.fee_estimated:,} | {swap.instruction_type} |\n")

    def _write_oracle_analysis(self, f, results: AnalysisResults):
        """Write oracle analysis section"""
        f.write("\n## Oracle Integration Analysis\n\n")

        if not results.oracles:
            f.write("No oracle interactions detected in analyzed transactions.\n\n")
            return

        f.write(f"**Total Oracle Accounts**: {len(results.oracles)}\n\n")

        f.write("### Oracle Usage Summary\n\n")
        f.write("| Oracle Account | Usage Count | Associated Swaps | Last Seen |\n")
        f.write("|----------------|-------------|------------------|----------|\n")

        sorted_oracles = sorted(
            results.oracles.values(),
            key=lambda x: x.usage_count,
            reverse=True
        )

        for oracle in sorted_oracles:
            oracle_short = oracle.oracle_account[:12] + "..." + oracle.oracle_account[-8:]
            last_seen = oracle.last_seen.strftime("%H:%M:%S")
            f.write(f"| `{oracle_short}` | {oracle.usage_count} | {oracle.associated_swaps} | {last_seen} |\n")

    def _write_technical_details(self, f, results: AnalysisResults):
        """Write technical details section"""
        f.write("\n## Technical Details\n\n")

        # Raw discriminators
        f.write("### Raw Instruction Discriminators\n\n")
        f.write("```\n")
        for disc in sorted(results.raw_discriminators):
            f.write(f"{disc}\n")
        f.write("```\n\n")

        # State patterns
        f.write("### State Patterns Detected\n\n")
        for key, value in results.state_patterns.items():
            f.write(f"- **{key.replace('_', ' ').title()}**: {value}\n")

    def _write_critical_findings(self, f, results: AnalysisResults):
        """Write critical findings section"""
        f.write("\n## Critical Findings\n\n")

        if not results.critical_findings:
            f.write("No critical findings identified.\n\n")
            return

        for i, finding in enumerate(results.critical_findings, 1):
            f.write(f"{i}. {finding}\n")

        f.write("\n## Next Steps\n\n")
        f.write("1. **Deep Instruction Analysis**: Focus on high-frequency discriminators\n")
        f.write("2. **Oracle Price Correlation**: Analyze oracle price feeds vs swap execution\n")
        f.write("3. **State Layout Reverse Engineering**: Extract pool state structures\n")
        f.write("4. **Algorithm Parameter Estimation**: Derive AMM curve parameters\n")
        f.write("5. **EVM Portability Assessment**: Evaluate Ethereum deployment feasibility\n")

# Main execution function
async def main():
    """Main execution with comprehensive analysis"""
    print("=" * 70)
    print("🎯 FINAL OPTIMIZED LIFINITY V2 ANALYZER")
    print("🚀 Production-ready comprehensive analysis")
    print("=" * 70)

    try:
        # Initialize analyzer
        analyzer = FinalOptimizedAnalyzer()

        # Run comprehensive analysis
        results = await analyzer.analyze_incremental(
            max_time=30,
            focus_areas=['instructions', 'swaps', 'oracles']
        )

        # Generate comprehensive report
        reporter = ComprehensiveReporter()
        report_file = reporter.generate_full_report(results)

        # Generate JSON export for further processing
        json_file = reporter.output_dir / f"lifinity_data_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        with open(json_file, 'w') as f:
            export_data = {
                "metadata": {
                    "analysis_time": datetime.now().isoformat(),
                    "processing_time": results.processing_time,
                    "coverage_stats": results.coverage_stats
                },
                "instructions": {disc: asdict(inst) for disc, inst in results.instructions.items()},
                "swaps": [asdict(swap) for swap in results.swaps],
                "oracles": {acc: asdict(oracle) for acc, oracle in results.oracles.items()},
                "state_patterns": results.state_patterns,
                "raw_discriminators": list(results.raw_discriminators),
                "critical_findings": results.critical_findings
            }
            json.dump(export_data, f, indent=2, default=str)

        # Final summary
        print("\n" + "=" * 70)
        print("✅ COMPREHENSIVE ANALYSIS COMPLETE")
        print(f"⏱️  Total time: {results.processing_time:.2f}s")
        print(f"📊 Transactions: {results.coverage_stats['processed_transactions']} "
              f"(Success: {results.state_patterns['success_rate_percent']:.1f}%)")
        print(f"🔍 Instructions: {len(results.instructions)} "
              f"(High confidence: {results.state_patterns['high_confidence_instructions']})")
        print(f"🔄 Swaps: {len(results.swaps)} "
              f"(Volume: {results.state_patterns['total_swap_volume']:,})")
        print(f"🔗 Oracles: {len(results.oracles)}")
        print(f"🗝️ Discriminators: {len(results.raw_discriminators)}")
        print(f"🎯 Critical findings: {len(results.critical_findings)}")
        print(f"📁 Reports: {Path(report_file).name}, {json_file.name}")
        print("=" * 70)

        # Show critical findings
        if results.critical_findings:
            print("\n🎯 CRITICAL FINDINGS:")
            for i, finding in enumerate(results.critical_findings, 1):
                print(f"  {i}. {finding}")

        # Show top instructions
        if results.instructions:
            print("\n🔥 TOP INSTRUCTIONS:")
            sorted_insts = sorted(results.instructions.values(), key=lambda x: x.frequency, reverse=True)
            for inst in sorted_insts[:5]:
                critical = " ⭐" if inst.is_critical else ""
                conf = f" ({inst.confidence:.2f})" if inst.confidence > 0.5 else ""
                print(f"  {inst.name}: {inst.frequency} calls{conf}{critical}")

        return results

    except Exception as e:
        print(f"❌ Fatal error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(main())