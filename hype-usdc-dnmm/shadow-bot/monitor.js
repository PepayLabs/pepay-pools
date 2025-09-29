// monitor.ts
// Real-time monitoring and alerting system for shadow bot
import 'dotenv/config';
import fetch from 'node-fetch';
import { JsonRpcProvider } from 'ethers';
export class ShadowBotMonitor {
    provider;
    alerts = [];
    metricsHistory = [];
    webhookUrl;
    // Alert thresholds
    ALERT_DELTA_BPS = Number(process.env.ALERT_DELTA_BPS || 100);
    ALERT_INVENTORY_DEV_BPS = Number(process.env.ALERT_INVENTORY_DEV_BPS || 2000);
    ALERT_REJECT_DURATION_SEC = Number(process.env.ALERT_REJECT_DURATION_SEC || 60);
    ALERT_SPREAD_BPS = Number(process.env.ALERT_SPREAD_BPS || 100);
    ALERT_CONF_BPS = Number(process.env.ALERT_CONF_BPS || 90);
    // Monitoring state
    rejectStartTime;
    consecutiveRejects = 0;
    lastAlertTime = {};
    ALERT_COOLDOWN = 300; // 5 minutes between same alerts
    constructor() {
        this.provider = new JsonRpcProvider(process.env.RPC_URL);
        this.webhookUrl = process.env.ALERT_WEBHOOK_URL;
    }
    async start() {
        console.log('[monitor] Shadow Bot Monitor Starting...');
        console.log('[monitor] Alert Thresholds:');
        console.log(`  - Delta: ${this.ALERT_DELTA_BPS} bps`);
        console.log(`  - Inventory Deviation: ${this.ALERT_INVENTORY_DEV_BPS} bps`);
        console.log(`  - Reject Duration: ${this.ALERT_REJECT_DURATION_SEC} seconds`);
        console.log(`  - Spread: ${this.ALERT_SPREAD_BPS} bps`);
        console.log(`  - Confidence: ${this.ALERT_CONF_BPS} bps`);
        // Start monitoring loop
        setInterval(() => this.checkMetrics(), 5000);
        // Start alert processor
        setInterval(() => this.processAlerts(), 10000);
        // Start health check
        setInterval(() => this.healthCheck(), 60000);
        console.log('[monitor] Monitoring active');
    }
    async checkMetrics() {
        try {
            // Fetch metrics from Prometheus endpoint
            const response = await fetch(`http://localhost:${process.env.PROM_PORT || 9464}/metrics`);
            const metricsText = await response.text();
            // Parse metrics
            const metrics = this.parseMetrics(metricsText);
            // Check for alerts
            this.checkDeltaAlert(metrics);
            this.checkSpreadAlert(metrics);
            this.checkConfidenceAlert(metrics);
            this.checkInventoryAlert(metrics);
            this.checkDecisionPatterns(metrics);
            // Store history
            this.metricsHistory.push(metrics);
            if (this.metricsHistory.length > 720) { // Keep 1 hour of data at 5s intervals
                this.metricsHistory.shift();
            }
        }
        catch (err) {
            console.error('[monitor] Error checking metrics:', err);
        }
    }
    parseMetrics(metricsText) {
        const lines = metricsText.split('\n');
        const metrics = {
            delta_bps: 0,
            spread_bps: 0,
            conf_bps: 0,
            sigma_bps: 0,
            inventory_deviation_bps: 0,
            fee_bps: 0,
            decision_counts: {}
        };
        for (const line of lines) {
            if (line.startsWith('dnmm_delta_bps ')) {
                metrics.delta_bps = parseFloat(line.split(' ')[1]);
            }
            else if (line.startsWith('dnmm_spread_bps ')) {
                metrics.spread_bps = parseFloat(line.split(' ')[1]);
            }
            else if (line.startsWith('dnmm_conf_bps ')) {
                metrics.conf_bps = parseFloat(line.split(' ')[1]);
            }
            else if (line.startsWith('dnmm_sigma_bps ')) {
                metrics.sigma_bps = parseFloat(line.split(' ')[1]);
            }
            else if (line.startsWith('dnmm_inventory_deviation_bps ')) {
                metrics.inventory_deviation_bps = parseFloat(line.split(' ')[1]);
            }
            else if (line.startsWith('dnmm_fee_bps ')) {
                metrics.fee_bps = parseFloat(line.split(' ')[1]);
            }
            else if (line.includes('dnmm_decisions_total{decision=')) {
                const match = line.match(/decision="([^"]+)"\}\s+(\d+)/);
                if (match) {
                    metrics.decision_counts[match[1]] = parseInt(match[2]);
                }
            }
        }
        return metrics;
    }
    checkDeltaAlert(metrics) {
        if (metrics.delta_bps > this.ALERT_DELTA_BPS) {
            this.addAlert({
                level: metrics.delta_bps > this.ALERT_DELTA_BPS * 2 ? 'critical' : 'warning',
                type: 'HIGH_DELTA',
                message: `Oracle divergence exceeds threshold`,
                value: metrics.delta_bps,
                threshold: this.ALERT_DELTA_BPS,
                timestamp: Date.now()
            });
        }
    }
    checkSpreadAlert(metrics) {
        if (metrics.spread_bps > this.ALERT_SPREAD_BPS) {
            this.addAlert({
                level: 'warning',
                type: 'WIDE_SPREAD',
                message: `Order book spread exceeds threshold`,
                value: metrics.spread_bps,
                threshold: this.ALERT_SPREAD_BPS,
                timestamp: Date.now()
            });
        }
    }
    checkConfidenceAlert(metrics) {
        if (metrics.conf_bps > this.ALERT_CONF_BPS) {
            this.addAlert({
                level: 'warning',
                type: 'HIGH_CONFIDENCE',
                message: `Confidence level exceeds threshold`,
                value: metrics.conf_bps,
                threshold: this.ALERT_CONF_BPS,
                timestamp: Date.now()
            });
        }
    }
    checkInventoryAlert(metrics) {
        if (metrics.inventory_deviation_bps > this.ALERT_INVENTORY_DEV_BPS) {
            this.addAlert({
                level: 'critical',
                type: 'INVENTORY_IMBALANCE',
                message: `Inventory deviation exceeds threshold`,
                value: metrics.inventory_deviation_bps,
                threshold: this.ALERT_INVENTORY_DEV_BPS,
                timestamp: Date.now()
            });
        }
    }
    checkDecisionPatterns(metrics) {
        const rejectCount = (metrics.decision_counts['REJECT'] || 0) +
            (metrics.decision_counts['REJECT(divergence)'] || 0) +
            (metrics.decision_counts['REJECT(conf_cap)'] || 0) +
            (metrics.decision_counts['REJECT(hysteresis)'] || 0);
        const totalCount = Object.values(metrics.decision_counts).reduce((a, b) => a + b, 0);
        if (totalCount > 0) {
            const rejectRate = (rejectCount / totalCount) * 100;
            // Check for sustained rejection
            if (rejectRate > 50) {
                if (!this.rejectStartTime) {
                    this.rejectStartTime = Date.now();
                }
                const rejectionDuration = (Date.now() - this.rejectStartTime) / 1000;
                if (rejectionDuration > this.ALERT_REJECT_DURATION_SEC) {
                    this.addAlert({
                        level: 'critical',
                        type: 'SUSTAINED_REJECTION',
                        message: `System rejecting trades for ${rejectionDuration.toFixed(0)} seconds`,
                        value: rejectionDuration,
                        threshold: this.ALERT_REJECT_DURATION_SEC,
                        timestamp: Date.now()
                    });
                }
            }
            else {
                this.rejectStartTime = undefined;
            }
        }
    }
    addAlert(alert) {
        // Check cooldown
        const lastAlert = this.lastAlertTime[alert.type];
        if (lastAlert && (Date.now() - lastAlert) / 1000 < this.ALERT_COOLDOWN) {
            return; // Skip duplicate alerts within cooldown
        }
        this.alerts.push(alert);
        this.lastAlertTime[alert.type] = Date.now();
        // Log alert
        const symbol = alert.level === 'critical' ? '🚨' :
            alert.level === 'warning' ? '⚠️' : 'ℹ️';
        console.log(`${symbol} [${alert.level.toUpperCase()}] ${alert.type}: ${alert.message}` +
            (alert.value ? ` (${alert.value} > ${alert.threshold})` : ''));
    }
    async processAlerts() {
        if (this.alerts.length === 0)
            return;
        // Group alerts by level
        const criticalAlerts = this.alerts.filter(a => a.level === 'critical');
        const warningAlerts = this.alerts.filter(a => a.level === 'warning');
        if (criticalAlerts.length > 0 || warningAlerts.length > 3) {
            await this.sendNotification(criticalAlerts, warningAlerts);
        }
        // Clear processed alerts
        this.alerts = [];
    }
    async sendNotification(critical, warnings) {
        if (!this.webhookUrl)
            return;
        const payload = {
            text: '🚨 Shadow Bot Alert',
            blocks: [
                {
                    type: 'header',
                    text: {
                        type: 'plain_text',
                        text: 'DNMM Shadow Bot Alert'
                    }
                },
                {
                    type: 'section',
                    fields: [
                        {
                            type: 'mrkdwn',
                            text: `*Critical Alerts:* ${critical.length}`
                        },
                        {
                            type: 'mrkdwn',
                            text: `*Warnings:* ${warnings.length}`
                        }
                    ]
                }
            ]
        };
        // Add critical alerts
        if (critical.length > 0) {
            payload.blocks.push({
                type: 'section',
                text: {
                    type: 'mrkdwn',
                    text: '*Critical Issues:*\n' + critical.map(a => `• ${a.message} (${a.value} > ${a.threshold})`).join('\n')
                }
            });
        }
        // Add warnings
        if (warnings.length > 0) {
            payload.blocks.push({
                type: 'section',
                text: {
                    type: 'mrkdwn',
                    text: '*Warnings:*\n' + warnings.slice(0, 5).map(a => `• ${a.message} (${a.value} > ${a.threshold})`).join('\n')
                }
            });
        }
        try {
            await fetch(this.webhookUrl, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
        }
        catch (err) {
            console.error('[monitor] Failed to send webhook:', err);
        }
    }
    async healthCheck() {
        try {
            // Check if metrics are being updated
            if (this.metricsHistory.length > 2) {
                const recent = this.metricsHistory.slice(-3);
                const allSame = recent.every(m => m.delta_bps === recent[0].delta_bps &&
                    m.spread_bps === recent[0].spread_bps);
                if (allSame) {
                    this.addAlert({
                        level: 'warning',
                        type: 'STALE_DATA',
                        message: 'Metrics not updating - shadow bot may be stuck',
                        timestamp: Date.now()
                    });
                }
            }
            // Check RPC connection
            const blockNumber = await this.provider.getBlockNumber();
            console.log(`[monitor] Health check OK - Block: ${blockNumber}`);
        }
        catch (err) {
            this.addAlert({
                level: 'critical',
                type: 'HEALTH_CHECK_FAILED',
                message: `Health check failed: ${err}`,
                timestamp: Date.now()
            });
        }
    }
    // Generate summary report
    generateSummary() {
        if (this.metricsHistory.length === 0) {
            return { error: 'No metrics collected yet' };
        }
        const recent = this.metricsHistory.slice(-12); // Last minute
        const avgDelta = recent.reduce((sum, m) => sum + m.delta_bps, 0) / recent.length;
        const avgSpread = recent.reduce((sum, m) => sum + m.spread_bps, 0) / recent.length;
        const avgConf = recent.reduce((sum, m) => sum + m.conf_bps, 0) / recent.length;
        const maxDelta = Math.max(...recent.map(m => m.delta_bps));
        return {
            monitoring_duration_min: (this.metricsHistory.length * 5) / 60,
            last_minute: {
                avg_delta_bps: avgDelta.toFixed(1),
                avg_spread_bps: avgSpread.toFixed(1),
                avg_confidence_bps: avgConf.toFixed(1),
                max_delta_bps: maxDelta
            },
            alerts_triggered: this.alerts.length,
            critical_alerts: this.alerts.filter(a => a.level === 'critical').length,
            health_status: this.alerts.some(a => a.type === 'HEALTH_CHECK_FAILED') ? 'UNHEALTHY' : 'HEALTHY'
        };
    }
}
// CLI usage
if (require.main === module) {
    const monitor = new ShadowBotMonitor();
    monitor.start();
    // Periodic summary
    setInterval(() => {
        const summary = monitor.generateSummary();
        console.log('\n[monitor] Summary:', JSON.stringify(summary, null, 2));
    }, 60000);
    // Handle shutdown
    process.on('SIGINT', () => {
        console.log('\n[monitor] Shutting down...');
        process.exit(0);
    });
}
