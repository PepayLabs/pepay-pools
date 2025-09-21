#!/usr/bin/env python3
"""
Working Lifinity V2 Analyzer
Simplified but robust version that focuses on getting results quickly
"""

import asyncio
import json
import struct
import base64
import time
import base58
from typing import Dict, List, Set, Any
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path
from collections import Counter

# Core imports
from solana.rpc.api import Client
from solders.pubkey import Pubkey

# Constants
LIFINITY_V2_PROGRAM_ID = "2wT8Yq49kHgDzXuPxZSaeLaH1qbmGXtEyPy64bL7aD3c"

@dataclass
class InstructionSummary:
    """Simple instruction summary"""
    discriminator: str
    frequency: int
    account_count: int
    data_size: int
    sample_accounts: List[str]
    classification: str

@dataclass
class AnalysisSummary:
    """Analysis results summary"""
    total_transactions: int
    successful_transactions: int
    instructions: Dict[str, InstructionSummary]
    raw_discriminators: Set[str]
    oracle_accounts: Set[str]
    processing_time: float
    status: str

class WorkingAnalyzer:
    """Simplified but working Lifinity analyzer"""

    def __init__(self):
        self.client = Client("https://api.mainnet-beta.solana.com")
        self.program_id = Pubkey.from_string(LIFINITY_V2_PROGRAM_ID)

        # Results
        self.instructions: Dict[str, InstructionSummary] = {}
        self.raw_discriminators: Set[str] = set()
        self.oracle_accounts: Set[str] = set()

        # Counters
        self.total_txs = 0
        self.successful_txs = 0
        self.start_time = time.time()

    async def analyze(self, max_transactions: int = 50) -> AnalysisSummary:
        """Simple analysis focusing on instruction extraction"""
        print(f"🚀 Starting simple Lifinity analysis (max {max_transactions} transactions)")

        try:
            # Get signatures
            print("📡 Fetching signatures...")
            response = self.client.get_signatures_for_address(
                self.program_id,
                limit=max_transactions
            )

            if not response or not response.value:
                return self._create_summary("No signatures found")

            signatures = response.value
            print(f"✅ Found {len(signatures)} signatures")

            # Process each transaction
            for i, sig_info in enumerate(signatures):
                if i >= max_transactions:
                    break

                print(f"📊 Processing {i+1}/{min(len(signatures), max_transactions)}", end="\r")

                success = await self._process_transaction(sig_info)
                self.total_txs += 1
                if success:
                    self.successful_txs += 1

            print(f"\n✅ Processed {self.total_txs} transactions, {self.successful_txs} successful")

            return self._create_summary("Analysis completed")

        except Exception as e:
            print(f"\n❌ Analysis error: {e}")
            return self._create_summary(f"Analysis failed: {e}")

    async def _process_transaction(self, sig_info) -> bool:
        """Process a single transaction"""
        try:
            # Get transaction
            tx_response = self.client.get_transaction(
                sig_info.signature,
                encoding="json",
                max_supported_transaction_version=0
            )

            if not tx_response or not tx_response.value:
                return False

            tx_data = tx_response.value

            # Extract instructions
            return self._extract_instructions(tx_data)

        except Exception:
            return False

    def _extract_instructions(self, tx_data) -> bool:
        """Extract instructions from transaction data"""
        try:
            # Navigate to message
            message = None

            if hasattr(tx_data, 'transaction'):
                if hasattr(tx_data.transaction, 'transaction'):
                    message = tx_data.transaction.transaction.message
                elif hasattr(tx_data.transaction, 'message'):
                    message = tx_data.transaction.message

            if not message:
                return False

            # Get account keys
            account_keys = []
            if hasattr(message, 'account_keys'):
                account_keys = [str(key) for key in message.account_keys]

            # Check if our program is in this transaction
            if LIFINITY_V2_PROGRAM_ID not in account_keys:
                return False

            # Process instructions
            found_lifinity = False
            if hasattr(message, 'instructions'):
                for ix in message.instructions:
                    if self._process_instruction(ix, account_keys):
                        found_lifinity = True

            return found_lifinity

        except Exception:
            return False

    def _process_instruction(self, ix, account_keys: List[str]) -> bool:
        """Process individual instruction"""
        try:
            # Check if this instruction is for our program
            program_idx = getattr(ix, 'program_id_index', -1)

            if program_idx < 0 or program_idx >= len(account_keys):
                return False

            program_key = account_keys[program_idx]
            if program_key != LIFINITY_V2_PROGRAM_ID:
                return False

            # Extract instruction data
            data = None
            if hasattr(ix, 'data'):
                if isinstance(ix.data, str):
                    try:
                        data = base58.b58decode(ix.data)
                    except:
                        data = ix.data.encode() if isinstance(ix.data, str) else None
                elif isinstance(ix.data, (bytes, bytearray)):
                    data = bytes(ix.data)

            if not data or len(data) < 8:
                return False

            # Extract discriminator
            discriminator = data[:8].hex()
            self.raw_discriminators.add(discriminator)

            # Get accounts for this instruction
            instruction_accounts = []
            if hasattr(ix, 'accounts'):
                for acc_idx in ix.accounts:
                    if acc_idx < len(account_keys):
                        instruction_accounts.append(account_keys[acc_idx])

            # Update instruction stats
            if discriminator not in self.instructions:
                self.instructions[discriminator] = InstructionSummary(
                    discriminator=discriminator,
                    frequency=0,
                    account_count=len(instruction_accounts),
                    data_size=len(data),
                    sample_accounts=instruction_accounts[:5],  # Keep first 5 accounts as sample
                    classification=self._classify_instruction(data, instruction_accounts)
                )

            self.instructions[discriminator].frequency += 1

            # Look for oracle accounts
            self._detect_oracles(instruction_accounts)

            return True

        except Exception:
            return False

    def _classify_instruction(self, data: bytes, accounts: List[str]) -> str:
        """Simple instruction classification"""
        data_len = len(data)
        acc_count = len(accounts)

        if data_len == 8:
            if acc_count <= 2:
                return "query"
            else:
                return "admin"
        elif 16 <= data_len <= 24 and acc_count >= 6:
            return "swap"
        elif data_len > 50 and acc_count >= 10:
            return "initialize"
        elif 24 < data_len <= 50:
            return "update"
        else:
            return f"unknown_{data_len}b"

    def _detect_oracles(self, accounts: List[str]):
        """Detect potential oracle accounts"""
        known_oracle_prefixes = ['J8', 'Gn', '3v', 'E4', '7y', 'AF']

        for account in accounts:
            # Check for known Pyth oracle patterns
            if any(account.startswith(prefix) for prefix in known_oracle_prefixes):
                self.oracle_accounts.add(account)

    def _create_summary(self, status: str) -> AnalysisSummary:
        """Create analysis summary"""
        processing_time = time.time() - self.start_time

        return AnalysisSummary(
            total_transactions=self.total_txs,
            successful_transactions=self.successful_txs,
            instructions=self.instructions,
            raw_discriminators=self.raw_discriminators,
            oracle_accounts=self.oracle_accounts,
            processing_time=processing_time,
            status=status
        )

def print_results(results: AnalysisSummary):
    """Print analysis results"""
    print("\n" + "=" * 60)
    print("📊 LIFINITY V2 ANALYSIS RESULTS")
    print("=" * 60)

    print(f"⏱️  Processing time: {results.processing_time:.2f}s")
    print(f"📈 Transactions: {results.total_transactions} total, {results.successful_transactions} successful")
    print(f"🔍 Instructions found: {len(results.instructions)}")
    print(f"🗝️ Raw discriminators: {len(results.raw_discriminators)}")
    print(f"🔗 Oracle accounts: {len(results.oracle_accounts)}")
    print(f"📋 Status: {results.status}")

    if results.instructions:
        print(f"\n🔥 INSTRUCTION ANALYSIS:")
        print(f"{'Discriminator':<18} {'Classification':<12} {'Frequency':<10} {'Accounts':<10} {'Data Size':<10}")
        print("-" * 70)

        # Sort by frequency
        sorted_instructions = sorted(
            results.instructions.values(),
            key=lambda x: x.frequency,
            reverse=True
        )

        for inst in sorted_instructions:
            print(f"{inst.discriminator[:16]:<18} {inst.classification:<12} {inst.frequency:<10} {inst.account_count:<10} {inst.data_size:<10}")

    if results.raw_discriminators:
        print(f"\n🗝️ RAW DISCRIMINATORS:")
        for disc in sorted(results.raw_discriminators):
            print(f"  {disc}")

    if results.oracle_accounts:
        print(f"\n🔗 DETECTED ORACLE ACCOUNTS:")
        for oracle in sorted(results.oracle_accounts):
            print(f"  {oracle}")

def save_results(results: AnalysisSummary, filename: str = None):
    """Save results to JSON file"""
    if not filename:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"lifinity_analysis_{timestamp}.json"

    output_dir = Path("lifinity_results")
    output_dir.mkdir(exist_ok=True)

    output_file = output_dir / filename

    # Convert to serializable format
    export_data = {
        "metadata": {
            "analysis_time": datetime.now().isoformat(),
            "processing_time": results.processing_time,
            "status": results.status
        },
        "summary": {
            "total_transactions": results.total_transactions,
            "successful_transactions": results.successful_transactions,
            "instructions_found": len(results.instructions),
            "oracle_accounts_found": len(results.oracle_accounts),
            "raw_discriminators_found": len(results.raw_discriminators)
        },
        "instructions": {
            disc: asdict(inst) for disc, inst in results.instructions.items()
        },
        "raw_discriminators": list(results.raw_discriminators),
        "oracle_accounts": list(results.oracle_accounts)
    }

    with open(output_file, 'w') as f:
        json.dump(export_data, f, indent=2, default=str)

    print(f"💾 Results saved to: {output_file}")
    return output_file

async def main():
    """Main execution"""
    print("🚀 LIFINITY V2 WORKING ANALYZER")
    print("Simple but effective instruction extraction")
    print("=" * 50)

    try:
        analyzer = WorkingAnalyzer()

        # Run analysis
        results = await analyzer.analyze(max_transactions=50)

        # Print results
        print_results(results)

        # Save results
        output_file = save_results(results)

        # Generate quick recommendations
        print(f"\n🎯 QUICK RECOMMENDATIONS:")
        if len(results.instructions) > 0:
            print(f"1. Focus reverse engineering on the {len(results.instructions)} discovered discriminators")
            high_freq = [i for i in results.instructions.values() if i.frequency > 5]
            if high_freq:
                print(f"2. Prioritize {len(high_freq)} high-frequency instructions for EVM porting")

        if len(results.oracle_accounts) > 0:
            print(f"3. Integrate {len(results.oracle_accounts)} detected oracle feeds in EVM version")

        print(f"4. Use {results.successful_transactions}/{results.total_transactions} transaction success rate to estimate current protocol activity")

        return results

    except Exception as e:
        print(f"❌ Fatal error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(main())