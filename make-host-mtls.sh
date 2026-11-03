#!/usr/bin/env bash
# Make the host's mTLS material by hand (ADR-0027 §2c, lead 2026-10-26): one Host CA key pair and
# ONE certificate that every server of the host shares. HAProxy accepts only clients presenting a
# certificate from this CA. No automation on purpose: run it once, keep the two private keys safe.
#
#   make-host-mtls.sh ca   <dir> <host-name>              Host CA: host-ca.key (secret), host-ca.crt
#   make-host-mtls.sh cert <dir> <name> [SAN ...]         the shared certificate, signed by the CA:
#                                                         mnms-mtls.key (secret), mnms-mtls.crt
#   make-host-mtls.sh embed <dir> <script>...             put host-ca.crt and mnms-mtls.crt (public)
#                                                         into the onboarding scripts (.sh, .ps1)
#
# SAN entries are DNS names or IP addresses the servers are reached by (e.g. mnms.example.com,
# 10.0.0.5); the name is the certificate's common name. Keys are ECDSA P-256, which every TLS
# client accepts. The CA lasts 10 years, the certificate 1 year (MNMS_MTLS_DAYS to change).
# The private keys never go into the onboarding script: it reads mnms-mtls.key from a file.
set -euo pipefail

die() { echo "make-host-mtls: $*" >&2; exit 1; }
command -v openssl >/dev/null || die "openssl is required"
umask 077

case "${1:-}" in
  ca)
    [[ $# -eq 3 ]] || die "usage: $0 ca <dir> <host-name>"
    dir="$2" host="$3"
    mkdir -p "$dir"
    [[ -e "$dir/host-ca.key" ]] && die "$dir/host-ca.key exists; refusing to overwrite a CA"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$dir/host-ca.key"
    openssl req -new -x509 -key "$dir/host-ca.key" -out "$dir/host-ca.crt" -days 3650 -sha256 \
      -subj "/O=MnMs host $host/CN=MnMs Host CA $host" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "subjectKeyIdentifier=hash"
    chmod 0644 "$dir/host-ca.crt"
    echo "Host CA: $dir/host-ca.crt (public); $dir/host-ca.key is SECRET: keep it offline"
    ;;
  cert)
    [[ $# -ge 3 ]] || die "usage: $0 cert <dir> <name> [DNS-name-or-IP ...]"
    dir="$2" name="$3"; shift 3
    [[ -f "$dir/host-ca.key" && -f "$dir/host-ca.crt" ]] || die "no Host CA in $dir (run: $0 ca $dir <host-name>)"
    [[ -e "$dir/mnms-mtls.key" ]] && die "$dir/mnms-mtls.key exists; refusing to overwrite"
    san="DNS:$name"
    for s in "$@"; do
      if [[ "$s" =~ ^[0-9.]+$ || "$s" == *:* ]]; then san+=",IP:$s"; else san+=",DNS:$s"; fi
    done
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$dir/mnms-mtls.key"
    openssl req -new -key "$dir/mnms-mtls.key" -out "$dir/mnms-mtls.csr" -subj "/O=MnMs/CN=$name"
    ext="$(mktemp)"; trap 'rm -f "$ext"' EXIT
    printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
      "extendedKeyUsage=serverAuth,clientAuth" "subjectAltName=$san" \
      "authorityKeyIdentifier=keyid" "subjectKeyIdentifier=hash" >"$ext"
    openssl x509 -req -in "$dir/mnms-mtls.csr" -CA "$dir/host-ca.crt" -CAkey "$dir/host-ca.key" \
      -CAcreateserial -out "$dir/mnms-mtls.crt" -days "${MNMS_MTLS_DAYS:-365}" -sha256 -extfile "$ext"
    rm -f "$dir/mnms-mtls.csr"
    chmod 0644 "$dir/mnms-mtls.crt"
    openssl verify -CAfile "$dir/host-ca.crt" "$dir/mnms-mtls.crt" >/dev/null
    echo "Shared certificate: $dir/mnms-mtls.crt (public, SAN $san)"
    echo "$dir/mnms-mtls.key is SECRET: give it to whoever runs onboarding, never commit it"
    ;;
  embed)
    [[ $# -ge 3 ]] || die "usage: $0 embed <dir> <installmnmagent.sh> [installmnmagent.ps1]"
    dir="$2"; shift 2
    for f in host-ca.crt mnms-mtls.crt; do [[ -f "$dir/$f" ]] || die "$dir/$f is missing"; done
    openssl verify -CAfile "$dir/host-ca.crt" "$dir/mnms-mtls.crt" >/dev/null || die "mnms-mtls.crt is not signed by host-ca.crt"
    for script in "$@"; do
      python3 -I - "$script" "$dir/host-ca.crt" "$dir/mnms-mtls.crt" <<'PY'
import re, sys
path, ca, cert = sys.argv[1], open(sys.argv[2]).read().strip(), open(sys.argv[3]).read().strip()
s = open(path).read()
# bash: HOST_CA_CERT_PEM='...'   PowerShell: $HostCaCertPem = '...'  (PEM has no single quotes)
names = (("$HostCaCertPem = ", ca), ("$MtlsCertPem = ", cert)) if path.endswith(".ps1") else (("HOST_CA_CERT_PEM=", ca), ("MTLS_CERT_PEM=", cert))
for prefix, pem in names:
    s, n = re.subn(rf"^{re.escape(prefix)}'[^']*'$", lambda m: f"{prefix}'{pem}'", s, count=1, flags=re.M)
    if n != 1:
        sys.exit(f"make-host-mtls: {path} has no {prefix}'...' line")
open(path, "w").write(s)
PY
      echo "Embedded host-ca.crt and mnms-mtls.crt into $script"
    done
    ;;
  *)
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
