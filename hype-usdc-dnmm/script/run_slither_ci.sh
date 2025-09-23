#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REPORT_PATH="reports/security/slither_findings.json"

printf '==> forge build --build-info\n'
forge build --build-info >/dev/null

rm -f "$REPORT_PATH"

printf '==> slither (writing %s)\n' "$REPORT_PATH"
set +e
slither . --filter-paths node_modules --exclude-informational --json "$REPORT_PATH"
SLITHER_STATUS=$?
set -e

if [[ $SLITHER_STATUS -ne 0 ]]; then
  if [[ $SLITHER_STATUS -ne 255 ]]; then
    echo "slither exited with status $SLITHER_STATUS"
    exit $SLITHER_STATUS
  fi
fi

if [[ ! -f "$REPORT_PATH" ]]; then
    echo "slither did not produce $REPORT_PATH"
    exit 1
fi
