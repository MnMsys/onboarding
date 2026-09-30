#!/usr/bin/env bash
# Provisions the MnMs Agent host stack (mnms-hostd, mnms-vaultd, mnms-agent-supervisor)
# on a fresh Linux VM: builds release binaries from the sibling mnms-agent checkout,
# copies them plus mnms-scripts/install-agent.sh to the target host, and runs it there.
#
# Auth is SSH key-based by default. No credentials are hardcoded or accepted as
# command-line arguments (arguments are visible in shell history and `ps`).
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: installmnmagent.sh <ip> [--user USER] [--key PATH]

  <ip>          Target VM address.
  --user USER   SSH user (default: root).
  --key PATH    SSH private key. If omitted, falls back to your ssh-agent /
                default identity — you will be prompted interactively if
                neither works. Never pass a password as an argument.
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
IP="$1"; shift
SSH_USER="root"
KEY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="${2:?}"; shift 2 ;;
    --user) SSH_USER="${2:?}"; shift 2 ;;
    *) usage ;;
  esac
done

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "$KEY" ]] && SSH_OPTS+=(-i "$KEY")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_DIR="$REPO_ROOT/mnms-agent"
SCRIPTS_DIR="$REPO_ROOT/mnms-scripts"

for d in "$AGENT_DIR" "$SCRIPTS_DIR"; do
  [[ -d "$d" ]] || { echo "ERROR: expected sibling checkout at $d (run from a MnMs workspace checkout, next to mnms-agent and mnms-scripts)" >&2; exit 1; }
done

echo "Building release binaries (mnms-hostd, mnms-vaultd, mnms-agent-supervisor, mnms-agent-runtime)..."
( cd "$AGENT_DIR" && cargo build --release -p mnms-agent-supervisor -p mnms-agent-runtime -p mnms-hostd )

echo "Testing SSH connection to $IP..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" "echo SSH connection successful"

echo "Copying binaries and install script to $IP..."
scp "${SSH_OPTS[@]}" \
  "$AGENT_DIR/target/release/mnms-hostd" \
  "$AGENT_DIR/target/release/mnms-vaultd" \
  "$AGENT_DIR/target/release/mnms-agent-supervisor" \
  "$AGENT_DIR/target/release/mnms-agent-runtime" \
  "$SCRIPTS_DIR/install-agent.sh" \
  "${SSH_USER}@${IP}:/tmp/"

echo "Installing on $IP..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" bash <<'REMOTE'
set -euo pipefail
sudo mkdir -p /usr/local/bin
sudo install -m 755 /tmp/mnms-hostd /tmp/mnms-vaultd /tmp/mnms-agent-supervisor /tmp/mnms-agent-runtime /usr/local/bin/
chmod +x /tmp/install-agent.sh
sudo bash /tmp/install-agent.sh
rm -f /tmp/mnms-hostd /tmp/mnms-vaultd /tmp/mnms-agent-supervisor /tmp/mnms-agent-runtime /tmp/install-agent.sh
REMOTE

echo "Agent host stack installed on $IP."
echo "Note: install-agent.sh's mnms-agent-supervisor.service expects a Podman OCI image"
echo "(MNMS_RUNTIME_IMAGE) by default. For a bare VM without a registry yet, set"
echo "MNMS_RUNTIME_DEV_BINARY=/usr/local/bin/mnms-agent-runtime in an override instead;"
echo "see mnms-agent/README.md."
