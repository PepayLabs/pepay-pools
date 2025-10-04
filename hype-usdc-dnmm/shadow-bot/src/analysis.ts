// analysis.ts
// Data analysis utilities for shadow bot CSV outputs

import fs from 'fs';
import { parse } from 'csv-parse/sync';

interface DataPoint {
  timestamp: number;
  mid_hc_wad: string;
  bid_wad: string;
  ask_wad: string;
  spread_bps: number;
  mid_pyth_wad: string;
  conf_pyth_bps: number;
  mid_ema_wad: string;
  delta_bps: number;
  conf_total_bps: number;
  conf_spread_bps: number;
  conf_sigma_bps: number;
  conf_pyth_weighted: number;
  sigma_bps: number;
  inventory_deviation_bps: number;
  fee_bps: number;
  base_reserves: string;
  quote_reserves: string;
  decision: string;
  used_fallback: boolean;
  pyth_fresh: boolean;
  ema_fresh: boolean;
  hysteresis_frames: number;
  rejection_duration: number;
}

export class ShadowBotAnalyzer {
  private data: DataPoint[] = [];

  constructor(csvPath: string) {
    this.loadData(csvPath);
  }

  private loadData(csvPath: string) {
    const fileContent = fs.readFileSync(csvPath, 'utf-8');
    const records = parse(fileContent, {
      columns: true,
      skip_empty_lines: true,
      cast: (value, context) => {
        // Parse numbers
        if (context.column === 'timestamp' ||
            context.column === 'spread_bps' ||
            context.column === 'conf_pyth_bps' ||
            context.column === 'delta_bps' ||
            context.column === 'conf_total_bps' ||
            context.column === 'conf_spread_bps' ||
            context.column === 'conf_sigma_bps' ||
            context.column === 'conf_pyth_weighted' ||
            context.column === 'sigma_bps' ||
            context.column === 'inventory_deviation_bps' ||
            context.column === 'fee_bps' ||
            context.column === 'hysteresis_frames' ||
            context.column === 'rejection_duration') {
          return parseFloat(value);
        }
        // Parse booleans
        if (context.column === 'used_fallback' ||
            context.column === 'pyth_fresh' ||
            context.column === 'ema_fresh') {
          return value === 'true';
        }
        return value;
      }
    });
    this.data = records;
  }

  // Calculate percentiles
  private percentile(values: number[], p: number): number {
    const sorted = values.slice().sort((a, b) => a - b);
    const index = Math.ceil((p / 100) * sorted.length) - 1;
    return sorted[Math.max(0, index)];
  }

  // Generate statistics report
  generateReport(): any {
    if (this.data.length === 0) {
      return { error: 'No data available' };
    }

    const deltaBps = this.data.map(d => d.delta_bps);
    const spreadBps = this.data.map(d => d.spread_bps);
    const confBps = this.data.map(d => d.conf_total_bps);
    const sigmaBps = this.data.map(d => d.sigma_bps);
    const invDevBps = this.data.map(d => d.inventory_deviation_bps);
    const feeBps = this.data.map(d => d.fee_bps);

    // Decision statistics
    const decisions = this.data.reduce((acc, d) => {
      acc[d.decision] = (acc[d.decision] || 0) + 1;
      return acc;
    }, {} as Record<string, number>);

    const totalSamples = this.data.length;
    const acceptRate = ((decisions['ACCEPT'] || 0) / totalSamples) * 100;
    const hairCutRate = ((decisions['HAIR_CUT'] || 0) / totalSamples) * 100;
    const rejectRate = (100 - acceptRate - hairCutRate);

    // Fallback usage
    const fallbackCount = this.data.filter(d => d.used_fallback).length;
    const fallbackRate = (fallbackCount / totalSamples) * 100;

    // Pyth freshness
    const pythFreshCount = this.data.filter(d => d.pyth_fresh).length;
    const pythFreshRate = (pythFreshCount / totalSamples) * 100;

    return {
      summary: {
        total_samples: totalSamples,
        duration_hours: (this.data[totalSamples - 1].timestamp - this.data[0].timestamp) / 3600,
        accept_rate: acceptRate.toFixed(2) + '%',
        hair_cut_rate: hairCutRate.toFixed(2) + '%',
        reject_rate: rejectRate.toFixed(2) + '%',
        fallback_rate: fallbackRate.toFixed(2) + '%',
        pyth_fresh_rate: pythFreshRate.toFixed(2) + '%'
      },
      delta_bps: {
        mean: this.mean(deltaBps),
        median: this.median(deltaBps),
        p25: this.percentile(deltaBps, 25),
        p75: this.percentile(deltaBps, 75),
        p95: this.percentile(deltaBps, 95),
        p99: this.percentile(deltaBps, 99),
        max: Math.max(...deltaBps)
      },
      spread_bps: {
        mean: this.mean(spreadBps),
        median: this.median(spreadBps),
        p25: this.percentile(spreadBps, 25),
        p75: this.percentile(spreadBps, 75),
        p95: this.percentile(spreadBps, 95),
        max: Math.max(...spreadBps)
      },
      confidence_bps: {
        mean: this.mean(confBps),
        median: this.median(confBps),
        p75: this.percentile(confBps, 75),
        p95: this.percentile(confBps, 95),
        max: Math.max(...confBps)
      },
      sigma_bps: {
        mean: this.mean(sigmaBps),
        median: this.median(sigmaBps),
        p75: this.percentile(sigmaBps, 75),
        p95: this.percentile(sigmaBps, 95),
        max: Math.max(...sigmaBps)
      },
      inventory_deviation_bps: {
        mean: this.mean(invDevBps),
        median: this.median(invDevBps),
        p75: this.percentile(invDevBps, 75),
        p95: this.percentile(invDevBps, 95),
        max: Math.max(...invDevBps)
      },
      fee_bps: {
        mean: this.mean(feeBps),
        median: this.median(feeBps),
        p75: this.percentile(feeBps, 75),
        p95: this.percentile(feeBps, 95),
        max: Math.max(...feeBps)
      },
      decisions: decisions,
      recommendations: this.generateRecommendations(deltaBps, spreadBps, confBps, acceptRate, rejectRate)
    };
  }

  private mean(values: number[]): number {
    return values.reduce((a, b) => a + b, 0) / values.length;
  }

  private median(values: number[]): number {
    return this.percentile(values, 50);
  }

  private generateRecommendations(
    deltaBps: number[],
    spreadBps: number[],
    confBps: number[],
    acceptRate: number,
    rejectRate: number
  ): string[] {
    const recommendations: string[] = [];

    // Delta recommendations
    const p95Delta = this.percentile(deltaBps, 95);
    if (p95Delta > 100) {
      recommendations.push(`High oracle divergence detected (p95=${p95Delta}bps). Consider increasing DIVERGENCE_BPS or investigating oracle quality.`);
    }

    // Accept rate recommendations
    if (acceptRate < 80) {
      recommendations.push(`Low accept rate (${acceptRate.toFixed(1)}%). Consider relaxing ACCEPT_BPS or SOFT_BPS thresholds.`);
    }
    if (rejectRate > 10) {
      recommendations.push(`High reject rate (${rejectRate.toFixed(1)}%). Review divergence thresholds and oracle freshness.`);
    }

    // Spread recommendations
    const p95Spread = this.percentile(spreadBps, 95);
    if (p95Spread > 50) {
      recommendations.push(`Wide spreads detected (p95=${p95Spread}bps). Market may be illiquid or volatile.`);
    }

    // Confidence recommendations
    const p95Conf = this.percentile(confBps, 95);
    if (p95Conf > 80) {
      recommendations.push(`High confidence values (p95=${p95Conf}bps). Consider adjusting confidence weights or caps.`);
    }

    return recommendations;
  }

  // Generate histogram data for visualization
  generateHistogram(field: keyof DataPoint, buckets: number[]): Record<string, number> {
    const values = this.data.map(d => Number(d[field]));
    const histogram: Record<string, number> = {};

    for (let i = 0; i < buckets.length; i++) {
      const min = i === 0 ? 0 : buckets[i - 1];
      const max = buckets[i];
      const key = `${min}-${max}`;
      histogram[key] = values.filter(v => v >= min && v < max).length;
    }

    // Add overflow bucket
    const lastBucket = buckets[buckets.length - 1];
    histogram[`${lastBucket}+`] = values.filter(v => v >= lastBucket).length;

    return histogram;
  }

  // Identify anomalies
  findAnomalies(threshold: number = 3): DataPoint[] {
    const deltaBps = this.data.map(d => d.delta_bps);
    const mean = this.mean(deltaBps);
    const stdDev = Math.sqrt(
      deltaBps.reduce((sum, val) => sum + Math.pow(val - mean, 2), 0) / deltaBps.length
    );

    return this.data.filter(d =>
      Math.abs(d.delta_bps - mean) > threshold * stdDev ||
      d.rejection_duration > 60 ||
      d.inventory_deviation_bps > 5000
    );
  }

  // Export filtered data
  exportFiltered(predicate: (d: DataPoint) => boolean, outputPath: string) {
    const filtered = this.data.filter(predicate);
    const csv = [
      Object.keys(filtered[0]).join(','),
      ...filtered.map(d => Object.values(d).join(','))
    ].join('\n');
    fs.writeFileSync(outputPath, csv);
  }
}

// CLI usage
if (require.main === module) {
  const csvPath = process.argv[2] || 'shadow_enterprise.csv';

  if (!fs.existsSync(csvPath)) {
    console.error(`File not found: ${csvPath}`);
    process.exit(1);
  }

  const analyzer = new ShadowBotAnalyzer(csvPath);
  const report = analyzer.generateReport();

  console.log('\n=== Shadow Bot Analysis Report ===\n');
  console.log(JSON.stringify(report, null, 2));

  // Generate histograms
  console.log('\n=== Delta BPS Histogram ===');
  const deltaHist = analyzer.generateHistogram('delta_bps' as keyof DataPoint, [10, 20, 30, 50, 75, 100, 200]);
  console.log(deltaHist);

  console.log('\n=== Spread BPS Histogram ===');
  const spreadHist = analyzer.generateHistogram('spread_bps' as keyof DataPoint, [5, 10, 20, 30, 50, 100]);
  console.log(spreadHist);

  // Find anomalies
  const anomalies = analyzer.findAnomalies();
  if (anomalies.length > 0) {
    console.log(`\n=== Found ${anomalies.length} Anomalies ===`);
    console.log('First 5 anomalies:', anomalies.slice(0, 5));
  }
}