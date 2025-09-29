# DNMM Shadow Bot - Enterprise Edition

## Overview

The DNMM Shadow Bot is an enterprise-grade simulation system for the HYPE/USDC Dynamic Market Maker protocol. It provides comprehensive monitoring, analysis, and simulation capabilities for understanding and optimizing the DNMM system behavior.

## Features

### Core Capabilities
- **Full Protocol Simulation**: Complete DNMM logic including oracle integration, inventory management, and fee calculation
- **Multi-Oracle Support**: Integrates HyperCore and Pyth oracles with fallback mechanisms
- **EMA Tracking**: Exponentially weighted moving average for price and volatility tracking
- **Inventory Management**: Simulates inventory levels with floor constraints and recentering logic
- **Dynamic Fee Calculation**: Base + confidence + inventory deviation based fees
- **Hysteresis Logic**: Prevents oscillation between accept/reject states
- **Trade Simulation**: Optional realistic trade pattern simulation

### Monitoring & Analytics
- **Prometheus Metrics**: Real-time metrics exposed for Grafana dashboards
- **CSV Logging**: Comprehensive data logging for historical analysis
- **Anomaly Detection**: Automatic detection of unusual market conditions
- **Alert System**: Configurable alerts with webhook notifications
- **Statistical Analysis**: Built-in analysis tools for performance evaluation

## Architecture

```
┌─────────────────────────────────────────┐
│           DNMM Shadow Bot               │
├─────────────────────────────────────────┤
│                                         │
│  ┌──────────┐     ┌──────────┐        │
│  │HyperCore │     │   Pyth   │        │
│  │ Oracles  │     │  Network │        │
│  └────┬─────┘     └────┬─────┘        │
│       │                │               │
│       └────────┬───────┘               │
│                ▼                       │
│        ┌──────────────┐                │
│        │Oracle Manager│                │
│        └──────┬───────┘                │
│               │                        │
│       ┌───────▼────────┐               │
│       │Decision Engine │               │
│       └───────┬────────┘               │
│               │                        │
│    ┌──────────┼──────────┐             │
│    ▼          ▼          ▼             │
│ ┌──────┐ ┌──────┐ ┌──────────┐        │
│ │ EMA  │ │ Inv. │ │   Fee    │        │
│ │Track │ │ Mgmt │ │   Calc   │        │
│ └──────┘ └──────┘ └──────────┘        │
│                                        │
│         ┌─────────────┐                │
│         │   Outputs   │                │
│         ├─────────────┤                │
│         │ • CSV Logs  │                │
│         │ • Metrics   │                │
│         │ • Alerts    │                │
│         └─────────────┘                │
└─────────────────────────────────────────┘
```

## Installation

### Prerequisites
- Node.js >= 18.0.0
- NPM or Yarn
- Access to HyperEVM RPC endpoint
- (Optional) DNMM pool deployment address

### Setup

1. Clone the repository and navigate to shadow-bot directory:
```bash
cd hype-usdc-dnmm/shadow-bot
```

2. Install dependencies:
```bash
npm install
```

3. Configure environment:
```bash
cp .env.template .env
# Edit .env with your configuration
```

4. Build TypeScript (optional):
```bash
npm run build
```

## Configuration

### Essential Environment Variables

```bash
# Network
RPC_URL=https://hyperliquid-mainnet.g.alchemy.com/v2/YOUR-KEY
MARKET_KEY_DEC=0x485950455f55534443ffffffffffffffffffffffffffffffffffffffffffffff

# Pyth Oracle
PYTH_ADDR=0xe9d69CdD6Fe41e7B621B4A688C5D1a68cB5c8ADc
PYTH_BASE_FEED_ID=4279e31cc369bbcc2faf022b382b080e32a8e689ff20fbc530d2a603eb6cd98b
PYTH_QUOTE_FEED_ID=eaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a

# Decision Thresholds
ACCEPT_BPS=30      # Accept if delta <= 30 bps
SOFT_BPS=50        # Hair cut if delta <= 50 bps
HARD_BPS=75        # Reject if delta > 75 bps
```

See `.env.template` for complete configuration options.

## Usage

### Running the Shadow Bot

Basic operation:
```bash
npm start
```

Development mode with auto-restart:
```bash
npm run dev
```

### Monitoring

View real-time metrics:
```bash
# Prometheus metrics
curl http://localhost:9464/metrics

# Stats dashboard
curl http://localhost:9464/stats
```

Run the monitor daemon:
```bash
npm run monitor
```

### Data Analysis

Analyze collected data:
```bash
npm run analyze shadow_enterprise.csv
```

Generate custom reports:
```typescript
import { ShadowBotAnalyzer } from './analysis';

const analyzer = new ShadowBotAnalyzer('data.csv');
const report = analyzer.generateReport();
console.log(report);

// Get specific histograms
const deltaHist = analyzer.generateHistogram('delta_bps', [10, 30, 50, 75, 100]);

// Find anomalies
const anomalies = analyzer.findAnomalies(3); // 3 sigma threshold
```

## Metrics

### Key Metrics Tracked

| Metric | Description | Alert Threshold |
|--------|-------------|-----------------|
| `dnmm_delta_bps` | HC vs Pyth price divergence | 100 bps |
| `dnmm_spread_bps` | Order book spread | 100 bps |
| `dnmm_conf_bps` | Total confidence score | 90 bps |
| `dnmm_sigma_bps` | Volatility (EWMA) | - |
| `dnmm_inventory_deviation_bps` | Deviation from target | 2000 bps |
| `dnmm_fee_bps` | Calculated fee | - |

### Decision Outcomes

- **ACCEPT**: Normal operation, trade allowed
- **HAIR_CUT**: Increased fees applied
- **REJECT(divergence)**: Oracle prices diverged too much
- **REJECT(conf_cap)**: Confidence exceeds cap
- **REJECT(hysteresis)**: In recovery period
- **ACCEPT(recovered)**: Recovered from rejection

## Tuning Guide

### 1. Initial Data Collection
Run the shadow bot for 3-7 days to collect baseline data:
```bash
npm start
# Let it run continuously
```

### 2. Analyze Patterns
```bash
npm run analyze shadow_enterprise.csv
```

Review the report for:
- Accept/reject rates
- Percentile distributions (p50, p95, p99)
- Recommendations

### 3. Adjust Thresholds

Based on analysis, tune parameters:

```bash
# For 95% accept rate with current p95 delta at 45 bps:
ACCEPT_BPS=50  # Increase from 30
SOFT_BPS=70    # Increase from 50

# If seeing high volatility (sigma p95 > 50):
CONF_WEIGHT_SIGMA_BPS=5000  # Increase weight
SIGMA_EWMA_LAMBDA_BPS=50    # Slower adaptation

# For inventory imbalance issues:
INVENTORY_FLOOR_BPS=2000     # Increase floor
FEE_BETA_NUM=2               # Increase inventory fee weight
```

### 4. Validate Changes
Run with new parameters and monitor:
```bash
npm run dev  # Auto-restarts on config changes
npm run monitor  # Watch for alerts
```

## Alert Configuration

### Webhook Integration
Configure Slack/Discord webhook for alerts:
```bash
ALERT_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
```

### Alert Types
- **HIGH_DELTA**: Oracle divergence exceeds threshold
- **WIDE_SPREAD**: Order book spread too wide
- **HIGH_CONFIDENCE**: Confidence level too high
- **INVENTORY_IMBALANCE**: Significant inventory deviation
- **SUSTAINED_REJECTION**: Prolonged rejection period
- **STALE_DATA**: Metrics not updating
- **HEALTH_CHECK_FAILED**: System health issue

## Production Deployment

### 1. System Requirements
- 2+ CPU cores
- 4GB RAM minimum
- 50GB disk for logs (with rotation)
- Reliable network connection

### 2. Process Management
Use PM2 or systemd for production:

```bash
# PM2 setup
npm install -g pm2
pm2 start shadow-bot.ts --name dnmm-shadow
pm2 startup
pm2 save

# Monitor
pm2 logs dnmm-shadow
pm2 monit
```

### 3. Log Rotation
Configure logrotate for CSV files:
```bash
# /etc/logrotate.d/dnmm-shadow
/path/to/shadow-bot/*.csv {
    daily
    rotate 30
    compress
    missingok
    notifempty
}
```

### 4. Monitoring Stack
Deploy full monitoring:
- Prometheus for metrics collection
- Grafana for visualization
- AlertManager for alert routing

## Troubleshooting

### Common Issues

**Issue**: No Pyth data
```bash
# Check Pyth connection
curl https://api.pyth.network/price_feed_ids
# Verify feed IDs match your configuration
```

**Issue**: High rejection rate
```bash
# Analyze rejection patterns
npm run analyze | grep "reject_rate"
# Consider increasing ACCEPT_BPS or DIVERGENCE_BPS
```

**Issue**: Memory usage growing
```bash
# Reduce history size
MAX_HISTORY_SIZE=50  # Default is 100
# Enable log rotation
```

## API Reference

### Shadow Bot Class

```typescript
class ShadowBot {
  constructor(config: Config);
  start(): Promise<void>;
  stop(): void;
  getState(): State;
  simulateTrade(isBuy: boolean, amount: bigint): TradeResult;
}
```

### Analyzer Class

```typescript
class ShadowBotAnalyzer {
  constructor(csvPath: string);
  generateReport(): Report;
  generateHistogram(field: string, buckets: number[]): Histogram;
  findAnomalies(threshold: number): DataPoint[];
  exportFiltered(predicate: Function, outputPath: string): void;
}
```

### Monitor Class

```typescript
class ShadowBotMonitor {
  constructor();
  start(): Promise<void>;
  generateSummary(): Summary;
  checkMetrics(): Promise<void>;
}
```

## Performance Optimization

### Memory Management
- Limit history arrays to prevent memory leaks
- Use streaming for large CSV files
- Implement periodic garbage collection

### CPU Optimization
- Batch oracle calls when possible
- Use efficient BigInt operations
- Cache frequently accessed calculations

### Network Optimization
- Use WebSocket connections for real-time data
- Implement retry logic with exponential backoff
- Cache oracle responses with TTL

## Contributing

Please follow these guidelines:
1. Run tests before submitting PRs
2. Update documentation for new features
3. Follow existing code style
4. Add unit tests for new functionality

## License

Private - See repository license

## Support

For issues or questions:
- Check troubleshooting guide above
- Review logs in CSV files
- Monitor Prometheus metrics
- Contact maintainers via repository issues