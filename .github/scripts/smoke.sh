#!/usr/bin/env bash
# CI smoke test of the host-side tools, in a temp dir, without a host:
#   make-host-mtls.sh ca | cert | embed, and verify-host-trust.sh on bundles it must reject
#   (a valid bundle needs the MnMs root private key, which CI does not have).
# Usage: .github/scripts/smoke.sh   (from anywhere; needs openssl 3 and python3)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail() { echo "smoke: FAIL: $*" >&2; exit 1; }
ok() { echo "smoke: ok: $*"; }

# make-host-mtls.sh: CA, shared certificate, refusal to overwrite, embedding.
"$REPO/make-host-mtls.sh" ca "$T/m" ci-host >/dev/null
"$REPO/make-host-mtls.sh" cert "$T/m" mnms.example.test 10.0.0.5 >/dev/null
openssl verify -CAfile "$T/m/host-ca.crt" "$T/m/mnms-mtls.crt" >/dev/null || fail "certificate does not verify"
openssl x509 -in "$T/m/mnms-mtls.crt" -noout -ext subjectAltName | grep -q 'IP Address:10.0.0.5' \
  || fail "IP SAN missing"
ok "ca + cert"
if "$REPO/make-host-mtls.sh" ca "$T/m" ci-host >/dev/null 2>&1; then fail "ca overwrote an existing CA"; fi
ok "ca refuses to overwrite"

cp "$REPO/installmnmagent.sh" "$REPO/installmnmagent.ps1" "$T/"
"$REPO/make-host-mtls.sh" embed "$T/m" "$T/installmnmagent.sh" "$T/installmnmagent.ps1" >/dev/null
for f in "$T/installmnmagent.sh" "$T/installmnmagent.ps1"; do
  grep -q "REPLACE: make-host-mtls.sh" "$f" && fail "placeholder left in $(basename "$f")"
  grep -q "$(sed -n 2p "$T/m/mnms-mtls.crt")" "$f" || fail "certificate not embedded in $(basename "$f")"
done
bash -n "$T/installmnmagent.sh" || fail "embedded installmnmagent.sh does not parse"
ok "embed"

# verify-host-trust.sh: rejects a non-bundle, and a well-formed bundle not signed by the MnMs root.
echo '{}' >"$T/empty.json"
if "$REPO/verify-host-trust.sh" "$T/empty.json" 2>"$T/err"; then fail "accepted an empty bundle"; fi
grep -q "is not a host trust bundle" "$T/err" || fail "unexpected error: $(cat "$T/err")"
ok "verify-host-trust rejects a non-bundle"

openssl genpkey -algorithm ED25519 -out "$T/fake-root.key"
openssl genpkey -algorithm ED25519 -out "$T/host.key"
python3 -I - "$T" <<'PY'
import base64, json, subprocess, sys, hashlib
t = sys.argv[1]
der = subprocess.run(["openssl", "pkey", "-in", f"{t}/host.key", "-pubout", "-outform", "DER"],
                     check=True, capture_output=True).stdout
host_key = der[-32:]
def canonical(doc): return json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
def sign(key, domain, doc):
    open(f"{t}/msg", "wb").write(domain + canonical(doc).encode())
    sig = subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", key, "-rawin", "-in", f"{t}/msg"],
                         check=True, capture_output=True).stdout
    return base64.b64encode(sig).decode()
lic = {"v": 1, "host_name": "ci-host", "host_public_key": base64.b64encode(host_key).decode(),
       "expires_at": "2099-01-01T00:00:00Z"}
cert = {"host_fingerprint": "sha256:" + hashlib.sha256(host_key).hexdigest(),
        "expires_at": "2099-01-01T00:00:00Z"}
bundle = {"license": {"license": lic, "signature": sign(f"{t}/fake-root.key", b"mnms-host-license-v1\n", lic)},
          "task_key_certificate": {"certificate": cert,
                                   "signature": sign(f"{t}/host.key", b"mnms-task-key-certificate-v1\n", cert)}}
json.dump(bundle, open(f"{t}/forged.json", "w"))
PY
if "$REPO/verify-host-trust.sh" "$T/forged.json" 2>"$T/err"; then fail "accepted a bundle not signed by the MnMs root"; fi
grep -q "not signed by the MnMs root key" "$T/err" || fail "unexpected error: $(cat "$T/err")"
ok "verify-host-trust rejects a license not signed by the MnMs root key"
echo "smoke: all passed"
