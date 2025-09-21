#!/usr/bin/env bash
set -euo pipefail

# Colors for readability
GREEN="\033[0;32m"
RESET="\033[0m"

log() {
  printf "${GREEN}[*] %s${RESET}\n" "$1"
}

# --- Node.js via nvm ---
NVM_VERSION="v0.40.3"
NODE_VERSION="20"
NVM_DIR="${HOME}/.nvm"

if ! command -v node >/dev/null 2>&1; then
  log "Node.js not detected; installing nvm ${NVM_VERSION}"
fi

if [ ! -d "${NVM_DIR}" ]; then
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi

# shellcheck disable=SC1091
if [ -s "${NVM_DIR}/nvm.sh" ]; then
  # shellcheck disable=SC1091
  source "${NVM_DIR}/nvm.sh"
else
  echo "nvm installation not found at ${NVM_DIR}" >&2
  exit 1
fi

if ! nvm ls "${NODE_VERSION}" >/dev/null 2>&1; then
  log "Installing Node.js ${NODE_VERSION}"
  nvm install "${NODE_VERSION}"
fi

log "Activating Node.js ${NODE_VERSION}"
nvm use "${NODE_VERSION}" >/dev/null
nvm alias default "${NODE_VERSION}" >/dev/null

if ! grep -q 'source ~/.nvm/nvm.sh' "${HOME}/.bashrc" 2>/dev/null; then
  echo 'source ~/.nvm/nvm.sh >/dev/null 2>&1' >> "${HOME}/.bashrc"
fi

# --- Foundry (forge/cast/anvil) ---
FOUNDRY_BIN="${HOME}/.foundry/bin"
FOUNDRYUP="${FOUNDRY_BIN}/foundryup"

if ! command -v forge >/dev/null 2>&1; then
  log "Installing Foundry toolchain"
  curl -L https://foundry.paradigm.xyz | bash
fi

if [ -x "${FOUNDRYUP}" ]; then
  # shellcheck disable=SC1090
  source "${FOUNDRYUP%/foundryup}/env"
  log "Running foundryup to ensure latest binaries"
  "${FOUNDRYUP}" -y >/dev/null
else
  echo "foundryup not found at ${FOUNDRYUP}" >&2
  exit 1
fi

if ! grep -q 'foundry/bin' "${HOME}/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> "${HOME}/.bashrc"
fi

log "Setup complete. Open a new shell or run 'source ~/.bashrc' to pick up changes."
