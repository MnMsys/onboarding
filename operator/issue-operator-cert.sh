#!/usr/bin/env bash
# DevOps side of operator onboarding: sign one person's certificate request with the Host CA and
# build the bundle they install with `mnm-operator.sh install --bundle <dir>`.
#
#   issue-operator-cert.sh --csr <name>.csr --pki <dir with host-ca.crt + host-ca.key> \
#       --gateway https://<control plane>:9443 [--tenant scomm] [--days 30] \
#       [--mnm <linux x86_64 mnm binary>] [--out <bundle dir>]
#
# Checks: the request's subject is exactly O=<tenant>,CN=<name> (the identity the gateway passes to
# the API), the name is a plain id, the request's signature verifies. The certificate is a client
# certificate only (clientAuth, CA:FALSE), 30 days by default. The Host CA key is only read.
#
# It does NOT give the person any permission and does NOT open the firewall: it prints the two
# commands for that (role assignment through mnm; 9443 from their IP on the control plane), which
# you run after deciding the role.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
CSR="" PKI="" GATEWAY="" TENANT="scomm" DAYS=30 MNM_BIN="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --csr) CSR="${2:?}"; shift 2 ;;
    --pki) PKI="${2:?}"; shift 2 ;;
    --gateway) GATEWAY="${2:?}"; shift 2 ;;
    --tenant) TENANT="${2:?}"; shift 2 ;;
    --days) DAYS="${2:?}"; shift 2 ;;
    --mnm) MNM_BIN="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done
[ -f "$CSR" ] || die "--csr <file> is required"
[ -f "$PKI/host-ca.crt" ] && [ -f "$PKI/host-ca.key" ] || die "--pki must contain host-ca.crt and host-ca.key"
[[ "$GATEWAY" =~ ^https://[A-Za-z0-9.:-]+$ ]] || die "--gateway must be an https URL, e.g. https://95.216.156.203:9443"
[[ "$DAYS" =~ ^[0-9]+$ ]] && [ "$DAYS" -ge 1 ] && [ "$DAYS" -le 90 ] || die "--days must be 1..90"
[[ "$TENANT" =~ ^[a-z0-9][a-z0-9_-]{1,62}$ ]] || die "--tenant is not a valid id"

openssl req -in "$CSR" -noout -verify >/dev/null 2>&1 || die "$CSR: signature does not verify (not a valid request)"
subject="$(openssl req -in "$CSR" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
name="$(printf '%s' "$subject" | sed -n "s/^CN=\([a-z0-9][a-z0-9_-]*\),O=$TENANT\$/\1/p")"
[ -n "$name" ] || die "request subject is '$subject'; expected exactly 'CN=<name>,O=$TENANT' with a plain lowercase name"
[ "${#name}" -ge 2 ] && [ "${#name}" -le 63 ] || die "name '$name' must be 2-63 characters"
case "$name" in platform-admin|root|admin|system|mnms*) die "name '$name' is reserved; ask for another" ;; esac

OUT="${OUT:-./operator-bundle-$name}"
install -d -m 0755 "$OUT"
ext="$(mktemp)"; trap 'rm -f "$ext"' EXIT
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' > "$ext"
openssl x509 -req -in "$CSR" -CA "$PKI/host-ca.crt" -CAkey "$PKI/host-ca.key" -CAcreateserial \
  -days "$DAYS" -sha256 -extfile "$ext" -out "$OUT/$name.crt" 2>/dev/null
openssl verify -CAfile "$PKI/host-ca.crt" "$OUT/$name.crt" >/dev/null || die "issued certificate does not verify"
install -m 0644 "$PKI/host-ca.crt" "$OUT/host-ca.crt"
printf '%s\n' "$GATEWAY" > "$OUT/gateway.txt"
cp "$(dirname "$0")/mnm-operator.sh" "$OUT/" && chmod 0755 "$OUT/mnm-operator.sh"
[ -f "$(dirname "$0")/README.md" ] && cp "$(dirname "$0")/README.md" "$OUT/"
if [ -n "$MNM_BIN" ]; then
  [ -x "$MNM_BIN" ] || die "--mnm $MNM_BIN is not an executable"
  install -m 0755 "$MNM_BIN" "$OUT/mnm-linux-x86_64"
fi
(cd "$OUT" && sha256sum ./* > SHA256SUMS)

end="$(openssl x509 -in "$OUT/$name.crt" -noout -enddate | cut -d= -f2)"
echo "issued   $OUT/$name.crt  (CN=$name,O=$TENANT, client auth, until $end)"
echo "bundle   $OUT  (send the whole directory; it holds no private key)"
echo ""
echo "Next, after deciding what $name may do:"
echo "  # 1. a role (examples: builtin/appops = see + restart services; builtin/platform-owner = everything)"
echo "  mnm authz assign $name builtin/appops --tenant $TENANT"
echo "  # 2. their IP on the control plane's entrance (run on the control plane, then save):"
echo "  iptables -I INPUT 1 -s <their-ip>/32 -p tcp --dport 9443 -m comment --comment \"MnMs entrance 9443: operator $name\" -j ACCEPT && netfilter-persistent save"
