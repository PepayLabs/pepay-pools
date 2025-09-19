#!/usr/bin/env python3
"""
Analysis Runner Script
Provides different analysis modes and configurations for the optimized analyzer
"""

import asyncio
import argparse
import time
import sys
from pathlib import Path

from optimized_analyzer import OptimizedAnalyzer, FastReporter, AnalysisResults

def parse_args():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(description="Lifinity V2 Optimized Analysis Tool")

    parser.add_argument(
        "--mode",
        choices=["quick", "standard", "deep", "incremental"],
        default="quick",
        help="Analysis mode (default: quick)"
    )

    parser.add_argument(
        "--max-time",
        type=int,
        default=30,
        help="Maximum analysis time in seconds (default: 30)"
    )

    parser.add_argument(
        "--max-txs",
        type=int,
        default=100,
        help="Maximum transactions to analyze (default: 100)"
    )

    parser.add_argument(
        "--output-dir",
        type=str,
        default="analysis_output",
        help="Output directory for reports (default: analysis_output)"
    )

    parser.add_argument(
        "--rpc-url",
        type=str,
        help="Custom RPC URL (optional)"
    )

    parser.add_argument(
        "--clear-cache",
        action="store_true",
        help="Clear RPC cache before analysis"
    )

    parser.add_argument(
        "--focus",
        choices=["instructions", "swaps", "state", "oracles"],
        help="Focus analysis on specific area"
    )

    return parser.parse_args()

async def run_quick_analysis(analyzer, max_time=30):
    """Quick analysis - critical patterns only"""
    print("🚀 Running QUICK analysis (30s max)")
    return await analyzer.analyze_incremental(max_time=max_time)

async def run_standard_analysis(analyzer, max_time=60):
    """Standard analysis - more comprehensive"""
    print("⚡ Running STANDARD analysis (60s max)")
    return await analyzer.analyze_incremental(max_time=max_time)

async def run_deep_analysis(analyzer, max_time=120):
    """Deep analysis - more transactions and detail"""
    print("🔍 Running DEEP analysis (120s max)")
    # Modify analyzer settings for deeper analysis
    analyzer.MAX_INITIAL_TXS = 300
    analyzer.BATCH_SIZE = 15
    return await analyzer.analyze_incremental(max_time=max_time)

async def run_incremental_analysis(analyzer, max_time=300):
    """Incremental analysis - builds up over multiple runs"""
    print("📈 Running INCREMENTAL analysis (300s max)")

    results_list = []
    batch_size = 50

    for batch_num in range(6):  # 6 batches of 50 txs each
        print(f"\n--- Batch {batch_num + 1}/6 ---")

        # Configure for this batch
        analyzer.MAX_INITIAL_TXS = batch_size
        batch_start = time.time()

        # Run batch analysis
        batch_results = await analyzer.analyze_incremental(max_time=50)
        batch_time = time.time() - batch_start

        results_list.append(batch_results)

        print(f"Batch {batch_num + 1} completed in {batch_time:.2f}s")
        print(f"Instructions found: {len(batch_results.instructions)}")

        # Check if we should continue
        if batch_time > 40:  # If batches are taking too long
            print("⚠️ Batches taking too long, stopping incremental analysis")
            break

    # Merge results
    return merge_analysis_results(results_list)

def merge_analysis_results(results_list):
    """Merge multiple analysis results"""
    if not results_list:
        return None

    merged = results_list[0]

    for result in results_list[1:]:
        # Merge instructions
        for disc, inst in result.instructions.items():
            if disc in merged.instructions:
                merged.instructions[disc].frequency += inst.frequency
            else:
                merged.instructions[disc] = inst

        # Merge swaps
        merged.swaps.extend(result.swaps)

        # Merge oracle usage
        merged.oracle_usage.update(result.oracle_usage)

        # Update processing time
        merged.processing_time += result.processing_time

    return merged

def clear_cache():
    """Clear RPC cache"""
    cache_dir = Path(".rpc_cache")
    if cache_dir.exists():
        for cache_file in cache_dir.glob("*.pkl"):
            cache_file.unlink()
        print("🗑️ Cache cleared")
    else:
        print("ℹ️ No cache to clear")

def print_focused_results(results, focus_area):
    """Print results focused on specific area"""
    print(f"\n🎯 FOCUSED ANALYSIS: {focus_area.upper()}")
    print("=" * 50)

    if focus_area == "instructions":
        print("Top Instructions by Frequency:")
        sorted_insts = sorted(results.instructions.values(), key=lambda x: x.frequency, reverse=True)
        for i, inst in enumerate(sorted_insts[:10], 1):
            critical = " ⭐" if inst.is_critical else ""
            print(f"{i:2d}. {inst.name}: {inst.frequency} calls{critical}")

    elif focus_area == "swaps":
        print(f"Swap Analysis ({len(results.swaps)} swaps found):")
        if results.swaps:
            amounts = [s.amount_in for s in results.swaps]
            print(f"  - Average amount: {sum(amounts) // len(amounts):,}")
            print(f"  - Max amount: {max(amounts):,}")
            print(f"  - Min amount: {min(amounts):,}")

            # Recent swaps
            print("  Recent swaps:")
            for swap in results.swaps[:5]:
                print(f"    {swap.tx_id[:16]}... {swap.amount_in:,} units")

    elif focus_area == "state":
        print("State Pattern Analysis:")
        for key, value in results.state_patterns.items():
            print(f"  - {key.replace('_', ' ').title()}: {value}")

    elif focus_area == "oracles":
        print(f"Oracle Analysis ({len(results.oracle_usage)} oracles found):")
        for oracle in list(results.oracle_usage.keys())[:10]:
            print(f"  - {oracle}")

async def main():
    """Main execution"""
    args = parse_args()

    print("=" * 70)
    print("🚀 LIFINITY V2 OPTIMIZED ANALYZER")
    print(f"📊 Mode: {args.mode.upper()}")
    print(f"⏱️ Max time: {args.max_time}s")
    print(f"📁 Output: {args.output_dir}")
    print("=" * 70)

    # Clear cache if requested
    if args.clear_cache:
        clear_cache()

    try:
        # Initialize analyzer
        analyzer = OptimizedAnalyzer(rpc_url=args.rpc_url)

        # Configure based on args
        analyzer.MAX_INITIAL_TXS = args.max_txs

        # Run analysis based on mode
        start_time = time.time()

        if args.mode == "quick":
            results = await run_quick_analysis(analyzer, args.max_time)
        elif args.mode == "standard":
            results = await run_standard_analysis(analyzer, args.max_time)
        elif args.mode == "deep":
            results = await run_deep_analysis(analyzer, args.max_time)
        elif args.mode == "incremental":
            results = await run_incremental_analysis(analyzer, args.max_time)

        total_time = time.time() - start_time

        if not results:
            print("❌ Analysis failed to produce results")
            return

        # Generate reports
        reporter = FastReporter(args.output_dir)
        summary_file = reporter.generate_summary_report(results)
        json_file = reporter.generate_json_export(results)

        # Show focused results if requested
        if args.focus:
            print_focused_results(results, args.focus)

        # Final summary
        print("\n" + "=" * 70)
        print("✅ ANALYSIS COMPLETE")
        print(f"⏱️  Total time: {total_time:.2f}s")
        print(f"📊 Instructions: {len(results.instructions)}")
        print(f"🔄 Swaps: {len(results.swaps)}")
        print(f"🔗 Oracles: {len(results.oracle_usage)}")
        print(f"📁 Reports: {summary_file.name}, {json_file.name}")

        # Performance metrics
        if results.coverage_stats:
            print(f"📈 Processed: {results.coverage_stats.get('processed_transactions', 0)} transactions")
            print(f"⚠️ Errors: {results.coverage_stats.get('errors', 0)}")

        print("=" * 70)

        return results

    except KeyboardInterrupt:
        print("\n⏹️ Analysis interrupted by user")
    except Exception as e:
        print(f"\n❌ Analysis failed: {e}")
        return None

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as e:
        print(f"Fatal error: {e}")
        sys.exit(1)