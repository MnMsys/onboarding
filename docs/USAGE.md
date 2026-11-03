# Usage

Run every script from this repo's directory, inside a workspace checkout (see [SETUP.md](SETUP.md)).

## Order

| Step | When | Command |
|---|---|---|
| 0 | once per host, by the host owner | `mnm host keygen`, the license from MnMs, `mnm host sign-task-key`, `mnm host trust-bundle` (produces `host-trust.json`) |
| 1 | once per host | `make-host-mtls.sh ca` |
| 2 | once per host, and when the certificate expires (1 year by default) | `make-host-mtls.sh cert` |
| 3 | after step 2 | `make-host-mtls.sh embed` (writes the public certificates into both install scripts) |
| 4 | optional, any time | `verify-host-trust.sh host-trust.json` |
| 5 | per machine | `installmnmagent.sh` or `installmnmagent.ps1` |

## 0. Get the host trust bundle

These are `mnm` (mnms-cli) commands, not scripts in this repo. They run offline on the host owner's
machine:

```bash
mnm host keygen --name <host>             # host key + host-license-request.json
# send host-license-request.json to MnMs, receive host-license.json
mnm host sign-task-key --task-key "$(mnms-manager task-key)"
mnm host trust-bundle                     # writes host-trust.json
```

See mnms-cli's docs for the full flags. `host-trust.json` is public: it holds the host's license
(signed by the MnMs root) and the certificate for the Manager pool's task key (signed by the host
key).

## `make-host-mtls.sh`

Makes the host's mTLS material by hand: one Host CA and one certificate that all of the host's
servers share. HAProxy's platform entrance (port 9443, rendered by mnms-haproxy-adapter) accepts only
clients presenting a certificate from this CA. Keys are ECDSA P-256. Files are created with
`umask 077`; certificates are then made `0644`.

| Subcommand | Arguments | Output |
|---|---|---|
| `ca` | `<dir> <host-name>` | `<dir>/host-ca.key` (secret, keep offline), `<dir>/host-ca.crt`. Valid 10 years. Refuses to overwrite an existing CA key |
| `cert` | `<dir> <name> [DNS-name-or-IP ...]` | `<dir>/mnms-mtls.key` (secret), `<dir>/mnms-mtls.crt`, signed by the CA in `<dir>`. CN and first SAN = `<name>`; each extra argument is added as `IP:` (digits and dots, or contains `:`) or `DNS:`. `serverAuth` and `clientAuth`. Refuses to overwrite an existing key |
| `embed` | `<dir> <script> [<script> ...]` | Replaces the `HOST_CA_CERT_PEM=` / `MTLS_CERT_PEM=` lines (bash) or `$HostCaCertPem = ` / `$MtlsCertPem = ` lines (`.ps1`) with `host-ca.crt` and `mnms-mtls.crt` from `<dir>`. Checks first that the certificate is signed by the CA |

| Variable | Default | Purpose |
|---|---|---|
| `MNMS_MTLS_DAYS` | `365` | Validity of the shared certificate (`cert`) |

No subcommand prints the usage and exits 2.

```bash
./make-host-mtls.sh ca   pki acme-host
./make-host-mtls.sh cert pki mnms-servers mnms.example.com
./make-host-mtls.sh embed pki installmnmagent.sh installmnmagent.ps1
```

Only the certificates go into the scripts. The install scripts refuse to run until `embed` has
replaced the `REPLACE: ...` placeholders.

## `verify-host-trust.sh`

```bash
./verify-host-trust.sh <host-trust.json>
```

Verifies the bundle against the MnMs root public key hardcoded in the script. Changing that key is
against the MnMs terms of service. Checks, in order:

1. the bundle has `license.license`, `license.signature`, `task_key_certificate.certificate` and
   `task_key_certificate.signature`, and the license version is `1`;
2. the task-key certificate's `host_fingerprint` is the SHA-256 of the licensed host key;
3. the license is signed by the MnMs root key (domain `mnms-host-license-v1`, canonical JSON);
4. the certificate is signed by the licensed host key (domain `mnms-task-key-certificate-v1`);
5. neither the license nor the certificate has expired.

On success it prints `host trust verified: host <name> (<fingerprint>), valid until <time>` and exits
0. It exits 1 on any failure (message prefixed `host trust:`) and 2 on wrong usage. `mnms-host` checks
the same chain again when it starts on the machine.

## `installmnmagent.sh`

```bash
./installmnmagent.sh <ip> --trust host-trust.json --mtls-key pki/mnms-mtls.key \
    --managers-json managers.json --manager-cert manager.crt \
    [--machine-id <ip>] [--pg-host <host>] [--pg-port <port>] [--user root] [--key ~/.ssh/id_ed25519]
```

| Argument | Required | Default | Meaning |
|---|---|---|---|
| `<ip>` | yes | | Target machine address (first argument) |
| `--trust PATH` | yes | | Host trust bundle; verified before anything else |
| `--mtls-key PATH` | yes | | Private key of the shared mTLS certificate; must match the embedded certificate |
| `--managers-json PATH` | yes | | Manager pool document (`generation >= 1`, at least one slot with an address) |
| `--manager-cert PATH` | yes | | The Manager's QUIC certificate the Agent pins; must be valid and unexpired |
| `--machine-id IP` | no | `<ip>` | The machine's IP as the Manager sees it (`MNMS_HOST_MACHINE_ID` on the machine). Must be an IP address |
| `--pg-host HOST` | no | local socket (`/var/run/postgresql`) | Postgres cluster for tenant service databases (`MNMS_PG_HOST` of `install-agent.sh`) |
| `--pg-port PORT` | no | `5432` | Its port (`MNMS_PG_PORT`) |
| `--user USER` | no | `root` | SSH user |
| `--key PATH` | no | ssh-agent / default identity | SSH private key |

What it does, in order (it stops at the first failure):

1. `verify-host-trust.sh` on the bundle.
2. Checks the embedded certificates: the mTLS certificate is issued by the Host CA, not expired, and
   `--mtls-key` is its key.
3. Checks `managers.json` and `manager.crt`.
4. Checks the sibling checkouts, then runs `cargo build --release` in mnms-host and
   `cargo build --release -p mnms-agent-supervisor -p mnms-agent-runtime -p mnms-vaultd -p mnms-haproxy-adapter`
   in mnms-agent.
5. Tests SSH, packs `mnms-scripts` (without `.git`, `lab`, `tests`, `docs`), mnms-host's
   `systemd/` and `polkit/`, and mnms-deploy's `systemd/`, and copies everything to `/tmp` on the
   target.
6. On the target: installs `managers.json` and `manager.crt` to `/mnm/identity/`, the four Agent
   binaries to `/usr/local/bin/`, then runs `install-agent.sh` with `MNMS_HOST_BIN`,
   `MNMS_HOST_TRUST_BUNDLE`, `MNMS_MACHINE_ID`, `MNMS_HOST_UNITS_DIR`, `MNMS_HOST_POLKIT_DIR`,
   `MNMS_DEPLOY_UNITS_DIR`, `MNMS_PG_HOST` and `MNMS_PG_PORT` set. It installs and enables mnms-host,
   mnms-vaultd, mnms-haproxy-adapter and the supervisor, and creates the vault master key
   `/etc/mnms/vaultd.env` if it does not exist.
7. Installs `/etc/mnms/pki/host-ca.crt`, `mnms-mtls.crt` (0644), `mnms-mtls.key` (0600 root) and
   the combined `mnms-mtls.pem` (0640 `root:mnms-agent`, read by HAProxy), removes the copies
   from `/tmp`, and restarts mnms-haproxy-adapter so the platform entrance (9443) comes up.

Re-running it replaces `managers.json` and `manager.crt` on the machine and keeps the vault master
key. **Back up `/etc/mnms/vaultd.env`**: without it the vault's secrets cannot be read.

## `installmnmagent.ps1`

```powershell
.\installmnmagent.ps1 -IpAddress <ip> -TrustBundle host-trust.json -MtlsKey pki\mnms-mtls.key `
    -ManagersJson managers.json -ManagerCert manager.crt `
    [-MachineId <ip>] [-PgHost <host>] [-PgPort <port>] [-SshUser root] [-KeyPath ~\.ssh\id_ed25519]
```

| Parameter | Required | Default | Meaning |
|---|---|---|---|
| `-IpAddress` | yes | | Target machine address |
| `-TrustBundle` | yes | | Host trust bundle. The file name may contain only letters, digits, `.`, `_`, `-` |
| `-MtlsKey` | yes | | Private key of the shared mTLS certificate |
| `-ManagersJson` | yes | | Manager pool document (must have `generation` and `slots`) |
| `-ManagerCert` | yes | | The Manager's QUIC certificate |
| `-MachineId` | no | `-IpAddress` | Must be an IP address |
| `-PgHost` | no | local socket | Same as `--pg-host`; letters, digits, `.`, `_`, `/`, `:`, `-` only |
| `-PgPort` | no | `5432` | Same as `--pg-port` |
| `-SshUser` | no | `root` | SSH user |
| `-KeyPath` | no | ssh-agent / default identity | SSH private key |

It does the same as the bash script, with one difference: Windows rarely has OpenSSL, so it first
creates `/tmp/mnms-onboard` (0700) on the target and runs `verify-host-trust.sh` and the certificate
checks **there**, before building anything. The directory is removed at the end, also on failure.

## Examples

Onboard a machine whose Manager-facing address differs from the SSH address:

```bash
./installmnmagent.sh <ssh-address> --machine-id <manager-facing-ip> --user admin --key ~/.ssh/mnms \
    --trust host-trust.json --mtls-key pki/mnms-mtls.key \
    --managers-json managers.json --manager-cert manager.crt
```

Renew the shared certificate (the old key must be moved away first, `cert` will not overwrite it):

```bash
mv pki/mnms-mtls.key pki/mnms-mtls.key.old && mv pki/mnms-mtls.crt pki/mnms-mtls.crt.old
./make-host-mtls.sh cert pki mnms-servers mnms.example.com
./make-host-mtls.sh embed pki installmnmagent.sh installmnmagent.ps1
# then re-run the install script for every machine of the host
```
