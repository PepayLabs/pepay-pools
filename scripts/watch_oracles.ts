import http from "http";
import { JsonRpcProvider, Log, Contract } from "ethers";

const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
const WATCHER_ADDRESS = process.env.ORACLE_WATCHER_ADDRESS;
const METRICS_PORT = Number(process.env.METRICS_PORT || 9464);

if (!WATCHER_ADDRESS) {
  console.error("Missing ORACLE_WATCHER_ADDRESS env var");
  process.exit(1);
}

const ABI = [
  "event OracleAlert(bytes32 indexed source,uint8 kind,uint256 value,uint256 threshold,bool critical)",
  "event AutoPauseRequested(bytes32 indexed source,bool handlerCalled,bytes handlerData)"
];

const KIND_LABEL: Record<number, string> = {
  0: "age",
  1: "divergence",
  2: "fallback"
};

type Metrics = {
  totalAlerts: number;
  criticalAlerts: number;
  lastKind: string;
  lastValue: bigint;
  lastSource: string;
  autopauseRequests: number;
  autopauseSuccess: number;
};

const metrics: Metrics = {
  totalAlerts: 0,
  criticalAlerts: 0,
  lastKind: "",
  lastValue: 0n,
  lastSource: "",
  autopauseRequests: 0,
  autopauseSuccess: 0
};

const provider = new JsonRpcProvider(RPC_URL);
const watcher = new Contract(WATCHER_ADDRESS, ABI, provider);

function formatBigint(value: bigint, decimals = 0): string {
  if (decimals === 0) return value.toString();
  const scale = BigInt(10 ** decimals);
  return `${value / scale}.${(value % scale).toString().padStart(decimals, "0")}`;
}

watcher.on("OracleAlert", (source: string, kind: number, value: bigint, threshold: bigint, critical: boolean, event: Log) => {
  metrics.totalAlerts += 1;
  if (critical) metrics.criticalAlerts += 1;
  metrics.lastKind = KIND_LABEL[kind] ?? `kind_${kind}`;
  metrics.lastValue = value;
  metrics.lastSource = source;

  const ts = new Date(event.blockNumber ? Number(event.blockNumber) * 1000 : Date.now()).toISOString();
  console.log(
    `[${ts}] OracleAlert source=${source} kind=${metrics.lastKind} value=${value} threshold=${threshold} critical=${critical}`
  );
});

watcher.on("AutoPauseRequested", (source: string, handlerCalled: boolean, handlerData: string) => {
  metrics.autopauseRequests += 1;
  if (handlerCalled) metrics.autopauseSuccess += 1;
  console.log(
    `[${new Date().toISOString()}] AutoPauseRequested source=${source} handlerCalled=${handlerCalled} data=${handlerData}`
  );
});

const server = http.createServer((_req, res) => {
  res.setHeader("Content-Type", "text/plain; version=0.0.4");
  res.end(
    `oracle_alerts_total ${metrics.totalAlerts}\n` +
      `oracle_alerts_critical_total ${metrics.criticalAlerts}\n` +
      `oracle_autopause_requests_total ${metrics.autopauseRequests}\n` +
      `oracle_autopause_success_total ${metrics.autopauseSuccess}\n` +
      `oracle_last_alert_kind{source="${metrics.lastSource}"} "${metrics.lastKind}"\n` +
      `oracle_last_alert_value{source="${metrics.lastSource}"} ${formatBigint(metrics.lastValue)}\n`
  );
});

server.listen(METRICS_PORT, () => {
  console.log(`Oracle watcher metrics listening on :${METRICS_PORT}`);
});

console.log(`Subscribed to OracleWatcher at ${WATCHER_ADDRESS} using ${RPC_URL}`);
