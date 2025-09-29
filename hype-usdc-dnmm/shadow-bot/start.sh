#!/bin/bash

# DNMM Shadow Bot Startup Script
# Enterprise-grade monitoring for HYPE/USDC pair

set -e

echo "==============================================="
echo "    DNMM Shadow Bot - Enterprise Edition      "
echo "==============================================="
echo ""

# Check if .env exists
if [ ! -f .env ]; then
    echo "⚠️  No .env file found. Creating from template..."
    cp .env.template .env
    echo "📝 Please configure .env with your settings and run again."
    exit 1
fi

# Load environment variables
export $(grep -v '^#' .env | xargs)

# Check required variables
if [ -z "$RPC_URL" ] || [ -z "$MARKET_KEY_DEC" ]; then
    echo "❌ Missing required environment variables"
    echo "Please configure RPC_URL and MARKET_KEY_DEC in .env"
    exit 1
fi

# Create data directory if not exists
mkdir -p data logs

# Clean old logs (optional)
if [ "$1" == "--clean" ]; then
    echo "🧹 Cleaning old data files..."
    rm -f data/*.csv logs/*.log
fi

# Test configuration
echo "🔍 Testing configuration..."
if ! node --loader ts-node/esm test-config.ts > /dev/null 2>&1; then
    echo "❌ Configuration test failed"
    exit 1
fi
echo "✅ Configuration valid"

# Start monitoring in background (optional)
if [ "$1" == "--monitor" ] || [ "$2" == "--monitor" ]; then
    echo "🔍 Starting monitor daemon..."
    nohup node --loader ts-node/esm monitor.ts > logs/monitor.log 2>&1 &
    echo "Monitor PID: $!"
fi

# Start shadow bot
echo ""
echo "🚀 Starting DNMM Shadow Bot..."
echo "📊 Metrics: http://localhost:${PROM_PORT:-9464}/metrics"
echo "📈 Stats: http://localhost:${PROM_PORT:-9464}/stats"
echo "📝 Output: ${OUT_CSV:-shadow_enterprise.csv}"
echo ""
echo "Press Ctrl+C to stop"
echo "==============================================="
echo ""

# Start with proper error handling
exec node --loader ts-node/esm shadow-bot.ts 2>&1 | tee logs/shadow-bot.log