#!/usr/bin/env bash
# Set up the `mnm` CLI for one operator (a person) on Linux, macOS or WSL. Two steps:
#
#   1. mnm-operator.sh request <name> [--tenant scomm]
#        Makes your private key (never leaves this machine) and a certificate request.
#        Send the printed request, and the public IP you will connect from, to DevOps.
#
#   2. mnm-operator.sh install --bundle <dir from DevOps>
#        DevOps sends back a bundle: your certificate, the host's CA certificate, the gateway URL
#        and (Linux/WSL) the mnm binary. This installs mnm, adds the host (`mnm host add`, verified
#        against the MnMs root), selects your tenant and checks `mnm health`.
#
#   mnm-operator.sh status       what is installed and whether the certificate is still valid
#
# Everything lives in ~/.config/mnm (certs/ is 0700, the key 0600) and ~/.local/bin/mnm. The
# shell setup is one line added to ~/.bashrc / ~/.zshrc: `. ~/.config/mnm/env.sh`.
set -euo pipefail

CONF="${MNM_CONFIG_DIR:-$HOME/.config/mnm}"
CERTS="$CONF/certs"
BIN_DIR="${MNM_BIN_DIR:-$HOME/.local/bin}"
ENV_FILE="$CONF/env.sh"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required (install it first)"; }

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{1,62}$ ]]; }

cmd_request() {
  local name="" tenant="scomm"
  while [ $# -gt 0 ]; do
    case "$1" in
      --tenant) tenant="${2:?--tenant needs a value}"; shift 2 ;;
      -h|--help) usage ;;
      -*) die "unknown option $1" ;;
      *) name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "usage: $0 request <name> [--tenant scomm]"
  valid_name "$name" || die "name '$name': lowercase letters, digits, '-' and '_' (2-63 chars), e.g. jane-doe"
  valid_name "$tenant" || die "tenant '$tenant' is not a valid id"
  need openssl
  install -d -m 0700 "$CONF" "$CERTS"
  local key="$CERTS/$name.key" csr="$CERTS/$name.csr"
  if [ -e "$key" ]; then
    say "keeping your existing key $key"
  else
    (umask 077; openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$key" 2>/dev/null)
    chmod 0600 "$key"
  fi
  openssl req -new -key "$key" -subj "/O=$tenant/CN=$name" -out "$csr" 2>/dev/null
  printf 'name=%s\ntenant=%s\n' "$name" "$tenant" > "$CONF/operator.conf"
  say ""
  say "Your private key: $key (stays here; never send it)."
  say "Send DevOps the certificate request below AND the public IP you will connect from"
  say "(e.g. from: curl -s https://ifconfig.me):"
  say ""
  cat "$csr"
}

cmd_install() {
  local bundle=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --bundle) bundle="${2:?--bundle needs a directory}"; shift 2 ;;
      -h|--help) usage ;;
      *) die "unknown option $1" ;;
    esac
  done
  [ -d "$bundle" ] || die "usage: $0 install --bundle <directory DevOps sent you>"
  [ -f "$CONF/operator.conf" ] || die "run '$0 request <name>' first (no key on this machine yet)"
  need openssl
  # shellcheck disable=SC1091
  . "$CONF/operator.conf"
  local key="$CERTS/$name.key"
  [ -f "$key" ] || die "your key $key is missing: run '$0 request $name' again and send DevOps the new request"
  local crt="$bundle/$name.crt" ca="$bundle/host-ca.crt" gw_file="$bundle/gateway.txt"
  [ -f "$crt" ] || die "$crt not in the bundle (is it for '$name'?)"
  [ -f "$ca" ] || die "host-ca.crt not in the bundle"
  [ -f "$gw_file" ] || die "gateway.txt not in the bundle"
  local gateway; gateway="$(head -1 "$gw_file" | tr -d '[:space:]')"
  [[ "$gateway" =~ ^https://[A-Za-z0-9.:-]+$ ]] || die "gateway.txt: '$gateway' is not an https URL"

  # The certificate must be for this key, issued by this CA, and still valid.
  [ "$(openssl pkey -in "$key" -pubout 2>/dev/null)" = "$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null)" ] \
    || die "$crt is not the certificate for your key $key"
  openssl verify -CAfile "$ca" "$crt" >/dev/null 2>&1 || die "$crt is not issued by the bundle's host-ca.crt"
  openssl x509 -in "$crt" -noout -checkend 0 >/dev/null || die "$crt has expired: ask DevOps for a new one"
  local subject; subject="$(openssl x509 -in "$crt" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
  [ "$subject" = "CN=$name,O=$tenant" ] || die "certificate subject is '$subject', expected 'CN=$name,O=$tenant'"

  install -m 0644 "$crt" "$CERTS/$name.crt"
  install -m 0644 "$ca" "$CERTS/host-ca.crt"

  # The binary: from the bundle if it has one for this platform, else an mnm already on PATH.
  install -d "$BIN_DIR"
  if [ -f "$bundle/mnm-$(uname -s | tr 'A-Z' 'a-z')-$(uname -m)" ]; then
    install -m 0755 "$bundle/mnm-$(uname -s | tr 'A-Z' 'a-z')-$(uname -m)" "$BIN_DIR/mnm"
    say "installed $BIN_DIR/mnm"
  elif [ ! -x "$BIN_DIR/mnm" ]; then
    die "the bundle has no mnm binary for $(uname -s)/$(uname -m); build it (mnms-cli: cargo build --release) and put it at $BIN_DIR/mnm"
  fi
  local MNM="$BIN_DIR/mnm"

  cat > "$ENV_FILE" <<EOF
# mnm operator settings (written by mnm-operator.sh). The gateway, tenant and actor come from
# ~/.config/mnm/hosts.json and session.toml (mnm host use / mnm me use).
case ":\$PATH:" in *":$BIN_DIR:"*) ;; *) export PATH="$BIN_DIR:\$PATH" ;; esac
export MNMS_CA_CERT="$CERTS/host-ca.crt"
export MNMS_CLIENT_CERT="$CERTS/$name.crt"
export MNMS_CLIENT_KEY="$CERTS/$name.key"
export MNMS_TENANT_ID="$tenant"
export MNMS_ACTOR_ID="$name"
EOF
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    grep -qF '.config/mnm/env.sh' "$rc" || printf '\n# mnm CLI (MnMs)\n[ -f "%s" ] && . "%s"\n' "$ENV_FILE" "$ENV_FILE" >> "$rc"
  done
  # shellcheck disable=SC1090
  . "$ENV_FILE"

  # Another `mnm` earlier on PATH (e.g. the old Node.js mnm-cli from npm) would shadow this one.
  local found; found="$(command -v mnm || true)"
  if [ "$found" != "$MNM" ]; then
    say "warning: 'mnm' on your PATH is $found, not $MNM; use a new shell (env.sh puts $BIN_DIR first)"
  fi

  say "adding the host from $gateway (its document is checked against the MnMs root key)..."
  local added name_line host
  added="$("$MNM" host add "$gateway" 2>&1)" || { echo "$added" >&2; die "mnm host add failed"; }
  echo "$added" | sed 's/^/  /'
  host="$("$MNM" host list 2>/dev/null | awk 'NR>1 || !/NAME/ {gsub(/\*/,""); print $1; exit}')"
  [ -n "$host" ] && "$MNM" host use "$host" >/dev/null 2>&1 || true
  "$MNM" me use --tenant "$tenant" --actor-id "$name" >/dev/null 2>&1 || "$MNM" me use --tenant "$tenant" >/dev/null 2>&1 || true

  local health; health="$("$MNM" health 2>&1 || true)"
  say "mnm health: $health"
  [ "$health" = "ok" ] || die "health check failed: is your IP allowed on the gateway yet? (ask DevOps)"
  say ""
  say "Done. Open a new shell (or: . $ENV_FILE), then try:"
  say "  mnm whoami"
  say "  mnm authz effective        # what you are allowed to do"
  say "  mnm service list"
  say "Your certificate expires $(openssl x509 -in "$CERTS/$name.crt" -noout -enddate | cut -d= -f2): send a new request before then."
}

cmd_status() {
  [ -f "$CONF/operator.conf" ] || { say "not set up (run: $0 request <name>)"; exit 1; }
  # shellcheck disable=SC1091
  . "$CONF/operator.conf"
  say "operator: $name (tenant $tenant)"
  say "key:      $([ -f "$CERTS/$name.key" ] && echo present || echo MISSING)"
  if [ -f "$CERTS/$name.crt" ]; then
    local end; end="$(openssl x509 -in "$CERTS/$name.crt" -noout -enddate | cut -d= -f2)"
    if openssl x509 -in "$CERTS/$name.crt" -noout -checkend 0 >/dev/null; then say "cert:     valid until $end"; else say "cert:     EXPIRED ($end)"; fi
  else
    say "cert:     not installed yet (waiting for DevOps' bundle)"
  fi
  say "mnm:      $(command -v mnm || echo 'not on PATH') $( [ -x "$BIN_DIR/mnm" ] && echo "(installed: $BIN_DIR/mnm)")"
}

case "${1:-}" in
  request) shift; cmd_request "$@" ;;
  install) shift; cmd_install "$@" ;;
  status) shift; cmd_status "$@" ;;
  -h|--help|"") usage ;;
  *) die "unknown command $1 (request, install, status)" ;;
esac
