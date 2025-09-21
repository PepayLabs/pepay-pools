#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_ROOT="$REPO_ROOT/hype-usdc-dnmm"

if ! command -v forge >/dev/null 2>&1; then
  echo "forge is not installed. Install Foundry via: curl -L https://foundry.paradigm.xyz | bash" >&2
  exit 127
fi

exec forge --root "$PROJECT_ROOT" "$@"
