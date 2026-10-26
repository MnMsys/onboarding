#!/usr/bin/env bash
# Provisions the MnMs Agent host stack (mnms-host, mnms-vaultd, mnms-agent-supervisor) on a fresh
# Linux VM. First verifies the host trust bundle against the MnMs root key hardcoded in
# verify-host-trust.sh (ADR-0027 §2b) and stops if it does not verify. Then builds release binaries
# from the sibling mnms-host and mnms-agent checkouts, copies them, the bundle and the mnms-scripts
# set (install-agent.sh and the provisioning scripts mnms-host runs) to the target host, and runs
# the installer there.
#
# The host's mTLS material (ADR-0027 §2c, lead 2026-10-26) is installed under /etc/mnms/pki, where
# mnms-haproxy-adapter turns it into the platform entrance on port 9443: the Host CA certificate and
# the one certificate all the host's servers share are hardcoded below (both public); the
# certificate's private key is read from the file given with --mtls-key and is never in this script.
#
# Auth is SSH key-based by default. No credentials are hardcoded or accepted as
# command-line arguments (arguments are visible in shell history and `ps`).
set -euo pipefail

# Made by hand with make-host-mtls.sh, written in with `make-host-mtls.sh embed <dir> installmnmagent.sh`.
HOST_CA_CERT_PEM='REPLACE: make-host-mtls.sh embed <dir> installmnmagent.sh'
MTLS_CERT_PEM='REPLACE: make-host-mtls.sh embed <dir> installmnmagent.sh'

usage() {
  cat >&2 <<'EOF'
Usage: installmnmagent.sh <ip> --trust host-trust.json --mtls-key mnms-mtls.key [--machine-id IP]
                          [--user USER] [--key PATH]

  <ip>          Target VM address.
  --trust PATH  The host trust bundle (`mnm host trust-bundle`): the host's MnMs license and its
                certificate for the Manager's task key. Verified before anything is installed.
  --mtls-key PATH  The private key of the host's shared mTLS certificate (from make-host-mtls.sh).
                It must match the certificate hardcoded in this script; it is copied to the
                machine (root-only) and never stored anywhere else.
  --machine-id  The machine's IP as the Manager sees it (default: <ip>).
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
TRUST=""
MTLS_KEY=""
MACHINE_ID="$IP"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --trust) TRUST="${2:?}"; shift 2 ;;
    --mtls-key) MTLS_KEY="${2:?}"; shift 2 ;;
    --machine-id) MACHINE_ID="${2:?}"; shift 2 ;;
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
HOST_DIR="$REPO_ROOT/mnms-host"
SCRIPTS_DIR="$REPO_ROOT/mnms-scripts"

# The license check comes first: nothing is built or copied for a host MnMs has not licensed.
[[ -n "$TRUST" ]] || { echo "ERROR: --trust host-trust.json is required (the host's MnMs license bundle)" >&2; usage; }
"$SCRIPT_DIR/verify-host-trust.sh" "$TRUST"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# The shared mTLS certificate: hardcoded, issued by the hardcoded Host CA, still valid, and the key
# given is its key. Checked before anything is built or copied.
[[ "$HOST_CA_CERT_PEM" != REPLACE* && "$MTLS_CERT_PEM" != REPLACE* ]] \
  || { echo "ERROR: this script has no mTLS certificates yet: run make-host-mtls.sh embed <dir> $0" >&2; exit 1; }
[[ -n "$MTLS_KEY" && -f "$MTLS_KEY" ]] || { echo "ERROR: --mtls-key <file> is required (the shared certificate's private key)" >&2; usage; }
( umask 077
  printf '%s\n' "$HOST_CA_CERT_PEM" >"$STAGE/host-ca.crt"
  printf '%s\n' "$MTLS_CERT_PEM" >"$STAGE/mnms-mtls.crt"
  cp "$MTLS_KEY" "$STAGE/mnms-mtls.key" )
chmod 0644 "$STAGE/host-ca.crt" "$STAGE/mnms-mtls.crt"
openssl verify -CAfile "$STAGE/host-ca.crt" "$STAGE/mnms-mtls.crt" >/dev/null 2>&1 \
  || { echo "ERROR: the hardcoded mTLS certificate is not issued by the hardcoded Host CA" >&2; exit 1; }
openssl x509 -in "$STAGE/mnms-mtls.crt" -noout -checkend 0 >/dev/null \
  || { echo "ERROR: the hardcoded mTLS certificate has expired: make a new one with make-host-mtls.sh" >&2; exit 1; }
[[ "$(openssl pkey -in "$STAGE/mnms-mtls.key" -pubout 2>/dev/null)" == "$(openssl x509 -in "$STAGE/mnms-mtls.crt" -noout -pubkey)" ]] \
  || { echo "ERROR: $MTLS_KEY is not the private key of the hardcoded mTLS certificate" >&2; exit 1; }
echo "mTLS certificate verified: $(openssl x509 -in "$STAGE/mnms-mtls.crt" -noout -subject), valid until $(openssl x509 -in "$STAGE/mnms-mtls.crt" -noout -enddate | cut -d= -f2)"

for d in "$AGENT_DIR" "$HOST_DIR" "$SCRIPTS_DIR"; do
  [[ -d "$d" ]] || { echo "ERROR: expected sibling checkout at $d (run from a MnMs workspace checkout, next to mnms-agent, mnms-host and mnms-scripts)" >&2; exit 1; }
done

echo "Building release binaries (mnms-host, mnms-vaultd, mnms-agent-supervisor, mnms-agent-runtime)..."
( cd "$HOST_DIR" && cargo build --release )
( cd "$AGENT_DIR" && cargo build --release -p mnms-agent-supervisor -p mnms-agent-runtime -p mnms-vaultd )

echo "Testing SSH connection to $IP..."
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" "echo SSH connection successful"

# install-agent.sh installs the provisioning scripts mnms-host runs (tenant users, service databases)
# and needs them next to it, so the whole mnms-scripts set travels as one archive.
COPYFILE_DISABLE=1 tar czf "$STAGE/mnms-scripts.tgz" --exclude=.git --exclude=lab --exclude=tests --exclude=docs \
  -C "$SCRIPTS_DIR" .
# mnms-host's own systemd units and polkit policy, which install-agent.sh installs with it.
COPYFILE_DISABLE=1 tar czf "$STAGE/mnms-host-files.tgz" -C "$HOST_DIR" systemd polkit

echo "Copying binaries and mnms-scripts to $IP..."
scp "${SSH_OPTS[@]}" \
  "$HOST_DIR/target/release/mnms-host" \
  "$AGENT_DIR/target/release/mnms-vaultd" \
  "$AGENT_DIR/target/release/mnms-agent-supervisor" \
  "$AGENT_DIR/target/release/mnms-agent-runtime" \
  "$STAGE/mnms-scripts.tgz" \
  "$STAGE/mnms-host-files.tgz" \
  "$STAGE/host-ca.crt" "$STAGE/mnms-mtls.crt" "$STAGE/mnms-mtls.key" \
  "$TRUST" \
  "${SSH_USER}@${IP}:/tmp/"
TRUST_NAME="$(basename "$TRUST")"

echo "Installing on $IP..."
# The machine id and bundle name are passed as arguments, never interpolated into the script text.
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${IP}" bash -s -- "$MACHINE_ID" "$TRUST_NAME" <<'REMOTE'
set -euo pipefail
MACHINE_ID="$1" TRUST_NAME="$2"
sudo mkdir -p /usr/local/bin
sudo install -m 755 /tmp/mnms-vaultd /tmp/mnms-agent-supervisor /tmp/mnms-agent-runtime /usr/local/bin/
rm -rf /tmp/mnms-scripts /tmp/mnms-host-files && mkdir -p /tmp/mnms-scripts /tmp/mnms-host-files
tar xzf /tmp/mnms-scripts.tgz -C /tmp/mnms-scripts
tar xzf /tmp/mnms-host-files.tgz -C /tmp/mnms-host-files
sudo MNMS_HOST_BIN=/tmp/mnms-host MNMS_HOST_TRUST_BUNDLE="/tmp/$TRUST_NAME" MNMS_MACHINE_ID="$MACHINE_ID" \
  MNMS_HOST_UNITS_DIR=/tmp/mnms-host-files/systemd MNMS_HOST_POLKIT_DIR=/tmp/mnms-host-files/polkit \
  bash /tmp/mnms-scripts/install-agent.sh
rm -rf /tmp/mnms-scripts /tmp/mnms-scripts.tgz /tmp/mnms-host-files /tmp/mnms-host-files.tgz
rm -f /tmp/mnms-host /tmp/mnms-vaultd /tmp/mnms-agent-supervisor /tmp/mnms-agent-runtime "/tmp/$TRUST_NAME"

# The host's mTLS material: certificates public, the key root-only; HAProxy reads the combined PEM.
sudo install -d -m 0755 -o root -g root /etc/mnms/pki
sudo install -m 0644 -o root -g root /tmp/host-ca.crt /tmp/mnms-mtls.crt /etc/mnms/pki/
sudo install -m 0600 -o root -g root /tmp/mnms-mtls.key /etc/mnms/pki/mnms-mtls.key
rm -f /tmp/host-ca.crt /tmp/mnms-mtls.crt /tmp/mnms-mtls.key
GRP=root; getent group haproxy >/dev/null && GRP=haproxy
sudo sh -c 'umask 077; cat /etc/mnms/pki/mnms-mtls.crt /etc/mnms/pki/mnms-mtls.key >/etc/mnms/pki/mnms-mtls.pem'
sudo chgrp "$GRP" /etc/mnms/pki/mnms-mtls.pem && sudo chmod 0640 /etc/mnms/pki/mnms-mtls.pem
REMOTE

echo "Agent host stack installed on $IP; the platform mTLS entrance is port 9443 once mnms-haproxy-adapter runs."
echo "Note: install-agent.sh's mnms-agent-supervisor.service expects a Podman OCI image"
echo "(MNMS_RUNTIME_IMAGE) by default. For a bare VM without a registry yet, set"
echo "MNMS_RUNTIME_DEV_BINARY=/usr/local/bin/mnms-agent-runtime in an override instead;"
echo "see mnms-agent/README.md."
