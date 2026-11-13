#!/usr/bin/env bash
# Verify a host trust bundle (host-trust.json, from `mnm host trust-bundle`) before a machine is
# onboarded (ADR-0027 §2b). The MnMs root public key is hardcoded below; changing it is against the
# MnMs terms of service. Checks, in order:
#   1. the host license is signed by the MnMs root key;
#   2. the task-key certificate names that licensed host (its key's fingerprint);
#   3. the certificate is signed by the licensed host key;
#   4. neither the license nor the certificate has expired.
# Prints the host name, fingerprint and expiry, and exits non-zero on any failure.
#
# Needs openssl (3.x, for Ed25519 with -rawin) and python3 (to rebuild the exact signed bytes:
# a domain line, then the document as canonical JSON: sorted keys, no whitespace).
#
# Usage: verify-host-trust.sh <host-trust.json>
set -euo pipefail

MNMS_ROOT_PUBLIC_KEY_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAtf8zUakn1QSP9axXyr3COazJFBRVMpsf8P4PBr4UM4E=
-----END PUBLIC KEY-----'

die() { echo "host trust: $*" >&2; exit 1; }
[[ $# -eq 1 ]] || { echo "usage: $0 <host-trust.json>" >&2; exit 2; }
BUNDLE="$1"
[[ -f "$BUNDLE" ]] || die "$BUNDLE does not exist"
command -v openssl >/dev/null || die "openssl is required"
command -v python3 >/dev/null || die "python3 is required"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
printf '%s\n' "$MNMS_ROOT_PUBLIC_KEY_PEM" >"$W/root.pem"

# Split the bundle into the signed bytes, the signatures and the host key, and check the fields.
python3 -I - "$BUNDLE" "$W" <<'PY' || exit 1
import base64, datetime, hashlib, json, sys

bundle_path, out = sys.argv[1], sys.argv[2]
def fail(msg):
    print(f"host trust: {msg}", file=sys.stderr); sys.exit(1)
try:
    b = json.load(open(bundle_path, encoding="utf-8"))
    lic, lic_sig = b["license"]["license"], b["license"]["signature"]
    cert, cert_sig = b["task_key_certificate"]["certificate"], b["task_key_certificate"]["signature"]
except (OSError, ValueError, KeyError, TypeError) as e:
    fail(f"{bundle_path} is not a host trust bundle ({e})")

def canonical(doc):
    return json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
def write(name, data):
    open(f"{out}/{name}", "wb").write(data)

write("license.msg", b"mnms-host-license-v1\n" + canonical(lic).encode("utf-8"))
write("cert.msg", b"mnms-task-key-certificate-v1\n" + canonical(cert).encode("utf-8"))
try:
    write("license.sig", base64.b64decode(lic_sig, validate=True))
    write("cert.sig", base64.b64decode(cert_sig, validate=True))
    host_key = base64.b64decode(lic["host_public_key"], validate=True)
except (ValueError, KeyError) as e:
    fail(f"a signature or the host key is not base64 ({e})")
if lic.get("v") != 1:
    fail(f"license version {lic.get('v')!r} is not supported")
if len(host_key) != 32:
    fail("the licensed host key is not an Ed25519 key (32 bytes)")
# SubjectPublicKeyInfo for Ed25519 = fixed 12-byte prefix + the raw key
spki = bytes.fromhex("302a300506032b6570032100") + host_key
write("host.pem", b"-----BEGIN PUBLIC KEY-----\n" + base64.b64encode(spki) + b"\n-----END PUBLIC KEY-----\n")

fingerprint = "sha256:" + hashlib.sha256(host_key).hexdigest()
if cert.get("host_fingerprint") != fingerprint:
    fail(f"the task-key certificate is for host {cert.get('host_fingerprint')}, but the license is for {fingerprint}")

def when(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
now = datetime.datetime.now(datetime.timezone.utc)
expires = min(when(lic["expires_at"]), when(cert["expires_at"]))
open(f"{out}/summary", "w").write(f"{lic['host_name']}\t{fingerprint}\t{expires.isoformat()}\t{'expired' if now >= expires else 'valid'}\n")
PY

verify() { # verify <public key pem> <message> <signature> <what>
  openssl pkeyutl -verify -pubin -inkey "$1" -rawin -in "$2" -sigfile "$3" >/dev/null 2>&1 || die "$4"
}
verify "$W/root.pem" "$W/license.msg" "$W/license.sig" "the host license is not signed by the MnMs root key"
verify "$W/host.pem" "$W/cert.msg" "$W/cert.sig" "the task-key certificate is not signed by the licensed host key"

IFS=$'\t' read -r HOST FP EXPIRES STATE <"$W/summary"
[[ "$STATE" == valid ]] || die "the license or task-key certificate of host $HOST expired at $EXPIRES"
echo "host trust verified: host $HOST ($FP), valid until $EXPIRES"
