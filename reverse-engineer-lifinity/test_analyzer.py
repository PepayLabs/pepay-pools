#!/usr/bin/env python3
"""
Test script for the optimized analyzer
Tests core functionality without making network calls
"""

import asyncio
import time
from unittest.mock import Mock, patch
from datetime import datetime

from optimized_analyzer import OptimizedAnalyzer, InstructionData, SwapEvent, AnalysisResults

def create_mock_signature():
    """Create a mock signature object"""
    mock_sig = Mock()
    mock_sig.signature = "5jKPEjkTgjhHjjtW2qWGfWS67YJhJDGJf9K4VCuGH7q6aJ9FUczBSjdPqNQ1p4RSUNyVqBRnQa2Sj8G3UQb8T1rV"
    mock_sig.slot = 150000000
    mock_sig.block_time = int(time.time())
    return mock_sig

def create_mock_transaction():
    """Create a mock transaction object"""
    mock_tx = Mock()
    mock_tx.transaction = Mock()
    mock_tx.transaction.transaction = Mock()
    mock_tx.transaction.transaction.message = Mock()

    # Mock instruction
    mock_instruction = Mock()
    mock_instruction.program_id_index = 0
    mock_instruction.data = b'\x01\x02\x03\x04\x05\x06\x07\x08\x09\x10\x11\x12\x13\x14\x15\x16'  # 16 bytes (discriminator + amount)
    mock_instruction.accounts = [0, 1, 2, 3, 4, 5, 6, 7]  # 8 accounts

    mock_tx.transaction.transaction.message.instructions = [mock_instruction]
    mock_tx.transaction.transaction.message.account_keys = [
        "2wT8Yq49kHgDzXuPxZSaeLaH1qbmGXtEyPy64bL7aD3c",  # Lifinity program
        "So11111111111111111111111111111111111111112",     # SOL mint
        "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",     # USDC mint
        "J83w4HKfqxwcq3BEMMkPFSppX3gqekLyLJBexebFVkix",     # Oracle account
        "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",     # Token program
        "11111111111111111111111111111111",                # System program
        "So11111111111111111111111111111111111111112",     # User token account
        "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"      # Pool vault
    ]

    mock_tx.transaction.transaction.message.header = Mock()
    mock_tx.transaction.transaction.message.header.num_required_signatures = 1
    mock_tx.transaction.transaction.message.header.num_readonly_signed_accounts = 0
    mock_tx.transaction.transaction.message.header.num_readonly_unsigned_accounts = 4

    return mock_tx

async def test_instruction_processing():
    """Test instruction processing logic"""
    print("🧪 Testing instruction processing...")

    analyzer = OptimizedAnalyzer()

    # Create mock data
    sig_info = create_mock_signature()
    tx_data = create_mock_transaction()

    # Test instruction extraction
    analyzer._extract_instructions_fast(tx_data, sig_info)

    # Verify results
    assert len(analyzer.instructions) > 0, "Should have extracted at least one instruction"
    assert len(analyzer.swaps) > 0, "Should have detected at least one swap"

    print(f"✅ Instructions extracted: {len(analyzer.instructions)}")
    print(f"✅ Swaps detected: {len(analyzer.swaps)}")

    # Check instruction details
    for disc, inst in analyzer.instructions.items():
        print(f"   Instruction: {inst.name} (freq: {inst.frequency})")

def test_pattern_analysis():
    """Test pattern analysis logic"""
    print("\n🧪 Testing pattern analysis...")

    analyzer = OptimizedAnalyzer()

    # Add some test instructions
    analyzer.instructions = {
        "0102030405060708": InstructionData("0102030405060708", "swap", 50, 8, 16, True),
        "0203040506070809": InstructionData("0203040506070809", "admin", 5, 2, 8, False),
        "0304050607080910": InstructionData("0304050607080910", "query", 100, 1, 8, True),
    }

    # Add some test swaps
    analyzer.swaps = [
        SwapEvent("tx1", 150000001, datetime.now(), 1000000, 950000, "swap"),
        SwapEvent("tx2", 150000002, datetime.now(), 2000000, 1900000, "swap"),
    ]

    # Add some oracle accounts
    analyzer.oracle_accounts.add("J83w4HKfqxwcq3BEMMkPFSppX3gqekLyLJBexebFVkix")

    # Run pattern analysis
    analyzer._analyze_patterns_fast()

    # Verify patterns
    assert analyzer.state_patterns["total_unique_instructions"] == 3
    assert analyzer.state_patterns["total_swaps_detected"] == 2
    assert analyzer.state_patterns["oracle_accounts_detected"] == 1

    print(f"✅ Pattern analysis completed")
    print(f"   Unique instructions: {analyzer.state_patterns['total_unique_instructions']}")
    print(f"   Swaps detected: {analyzer.state_patterns['total_swaps_detected']}")
    print(f"   Oracle accounts: {analyzer.state_patterns['oracle_accounts_detected']}")

def test_results_creation():
    """Test results creation"""
    print("\n🧪 Testing results creation...")

    analyzer = OptimizedAnalyzer()
    analyzer.start_time = time.time() - 5  # Simulate 5 second processing

    # Add test data
    analyzer.instructions = {
        "0102030405060708": InstructionData("0102030405060708", "swap", 50, 8, 16, True)
    }
    analyzer.swaps = [SwapEvent("tx1", 150000001, datetime.now(), 1000000, 950000, "swap")]
    analyzer.oracle_accounts.add("J83w4HKfqxwcq3BEMMkPFSppX3gqekLyLJBexebFVkix")
    analyzer.processed_txs = 10
    analyzer.errors = 1

    # Run pattern analysis first
    analyzer._analyze_patterns_fast()

    # Create results
    results = analyzer._create_results("Test completed")

    # Verify results
    assert isinstance(results, AnalysisResults)
    assert len(results.instructions) == 1
    assert len(results.swaps) == 1
    assert len(results.oracle_usage) == 1
    assert results.processing_time > 0
    assert results.coverage_stats["processed_transactions"] == 10
    assert results.coverage_stats["errors"] == 1

    print(f"✅ Results created successfully")
    print(f"   Processing time: {results.processing_time:.2f}s")
    print(f"   Coverage stats: {results.coverage_stats}")

async def test_cache_functionality():
    """Test cache functionality"""
    print("\n🧪 Testing cache functionality...")

    from optimized_analyzer import RPCCache

    cache = RPCCache(".test_cache")

    # Test cache set/get
    test_data = {"result": "test_value", "number": 12345}
    cache.set("test_method", {"param": "value"}, test_data)

    retrieved = cache.get("test_method", {"param": "value"})
    assert retrieved == test_data, "Cache should return the same data"

    # Test cache miss
    missing = cache.get("test_method", {"param": "different"})
    assert missing is None, "Cache miss should return None"

    print("✅ Cache functionality working correctly")

    # Cleanup
    import shutil
    from pathlib import Path
    test_cache_dir = Path(".test_cache")
    if test_cache_dir.exists():
        shutil.rmtree(test_cache_dir)

async def run_full_mock_analysis():
    """Run full analysis with mocked network calls"""
    print("\n🧪 Testing full analysis with mocks...")

    with patch('optimized_analyzer.Client') as mock_client_class:
        # Mock the client
        mock_client = Mock()
        mock_client_class.return_value = mock_client

        # Mock get_signatures_for_address
        mock_response = Mock()
        mock_response.value = [create_mock_signature() for _ in range(10)]
        mock_client.get_signatures_for_address.return_value = mock_response

        # Mock get_transaction
        mock_tx_response = Mock()
        mock_tx_response.value = create_mock_transaction()
        mock_client.get_transaction.return_value = mock_tx_response

        # Run analysis with more time for processing
        analyzer = OptimizedAnalyzer()
        results = await analyzer.analyze_incremental(max_time=15)

        # Verify results
        assert results is not None, "Analysis should return results"
        assert len(results.instructions) > 0, "Should find instructions"
        assert results.processing_time < 15, "Should complete within time limit"

        print(f"✅ Full mock analysis completed")
        print(f"   Instructions found: {len(results.instructions)}")
        print(f"   Processing time: {results.processing_time:.2f}s")
        print(f"   Status: {results.coverage_stats['status']}")

async def main():
    """Run all tests"""
    print("=" * 60)
    print("🧪 TESTING OPTIMIZED LIFINITY ANALYZER")
    print("=" * 60)

    try:
        # Run tests
        await test_instruction_processing()
        test_pattern_analysis()
        test_results_creation()
        await test_cache_functionality()
        await run_full_mock_analysis()

        print("\n" + "=" * 60)
        print("✅ ALL TESTS PASSED")
        print("🚀 Analyzer is ready for production use!")
        print("=" * 60)

    except Exception as e:
        print(f"\n❌ Test failed: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(main())