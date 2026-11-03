# Setup

Two machines are involved: the **workstation** that runs the onboarding scripts, and the **target
host** being onboarded. Both need some preparation. What the installer then puts on the target is
described by `mnms-scripts/install-agent.sh` and the
[mnms-host DEPLOYMENT.md](https://github.com/MnMsys/mnms-host/blob/main/DEPLOYMENT.md); it is not
repeated here.

## Workstation

### Sibling checkouts

The install scripts look for their sibling repos one level up and stop if any is missing:

```text
<workspace>/
  mnms-onboarding/     # this repo
  mnms-host/           # built with cargo build --release; systemd/ and polkit/ are shipped
  mnms-agent/          # mnms-agent-supervisor, mnms-agent-runtime, mnms-vaultd, mnms-haproxy-adapter
  mnms-scripts/        # install-agent.sh and the provisioning scripts (lab/, tests/, docs/ excluded)
  mnms-deploy/         # systemd/ is shipped: the vaultd, supervisor and adapter units
  mnms-protocol/       # needed to build mnms-host and mnms-agent
```

### Tools

| Tool | Used by | Notes |
|---|---|---|
| bash | all `.sh` scripts | |
| Rust toolchain (`cargo`) | `installmnmagent.sh`, `.ps1` | Builds mnms-host and mnms-agent in release mode; versions as pinned by those repos |
| OpenSSL 3.x | `verify-host-trust.sh`, `make-host-mtls.sh`, `installmnmagent.sh` | Ed25519 verification needs `pkeyutl -rawin` (3.x) |
| python3 | `verify-host-trust.sh`, `make-host-mtls.sh embed`, `installmnmagent.sh` | Runs with `-I`; standard library only |
| OpenSSH client (`ssh`, `scp`) | install scripts | Key-based auth; see below |
| tar | install scripts | Windows 10+ ships `tar.exe` |
| PowerShell | `installmnmagent.ps1` | On Windows, OpenSSL and python3 are not needed locally: the checks run on the target |

### SSH access

Both install scripts use SSH keys only. They never take a password. Put your public key on the
target before running them (cloud-init, or your VM provider's key injection). Pass the key with
`--key` / `-KeyPath`, or rely on `ssh-agent` or your default identity. The first connection accepts
and records the host key (`StrictHostKeyChecking=accept-new`).

### Files you need before onboarding

| File | Where it comes from |
|---|---|
| `host-trust.json` | The host owner: `mnm host keygen`, the license from MnMs, `mnm host sign-task-key`, `mnm host trust-bundle` (see [USAGE.md](USAGE.md#0-get-the-host-trust-bundle)) |
| `pki/mnms-mtls.key` | `make-host-mtls.sh cert`. Secret. `.gitignore` excludes `pki/` and `*.key` |
| `managers.json` | The Manager pool (`mnm pool show manager`), as `{"generation": N, "slots": [{"id", "endpoint": {"ipv4", "ipv6", "hostname"}}]}` |
| `manager.crt` | The Manager's QUIC certificate, exported by the Manager to `MNMS_MANAGER_CERT_EXPORT_PATH` |

## Target host

- Linux with systemd, reachable over SSH, with `sudo` available to the SSH user. The remote steps
  call `sudo` even when you log in as root.
- `useradd`, `usermod`, `userdel`, `flock`, `install` (checked by
  `install-provision-scripts.sh --check`; it stops if one is missing).
- polkit (`pkcheck`, `polkitd`), `setfacl` (`acl` package), `haproxy` and `openssl`:
  `install-agent.sh` stops without them. HAProxy is run by mnms-haproxy-adapter (the distribution's
  `haproxy.service` is not used); openssl makes the vault master key.
- `loginctl`, for linger of rootless ops users (warning only if missing).
- Rootless Podman, for the Agent runtime container and tenant workloads.
- PostgreSQL, for tenant service databases. By default the database scripts use the local socket on
  5432. Pass `--pg-host` / `--pg-port` (`-PgHost` / `-PgPort`) when the MnMs cluster is another one;
  they become `MNMS_PG_HOST` / `MNMS_PG_PORT` of `install-agent.sh`.
- For the PowerShell path only: OpenSSL 3.x and python3 on the target, because the trust and
  certificate checks run there.
- The subuid/subgid range 200000-265535 must be free for `mnms-agent` (`install-agent.sh` checks
  this).
- An Agent runtime image. `mnms-agent-supervisor.service` uses
  `MNMS_RUNTIME_IMAGE=localhost/mnms-agent-runtime:latest`. Without a registry, set
  `MNMS_RUNTIME_DEV_BINARY=/usr/local/bin/mnms-agent-runtime` in a drop-in for that unit (see
  mnms-agent's README).

## Developing and testing this repo

There is no build. To check a change, run what CI runs:

```bash
for f in *.sh .github/scripts/*.sh; do bash -n "$f"; done   # syntax
shellcheck *.sh .github/scripts/*.sh
.github/scripts/smoke.sh                                     # needs openssl 3 and python3
```

`.github/scripts/smoke.sh` exercises the host-side tools in a temp directory, without a host:
`make-host-mtls.sh` `ca`, `cert` (and its refusal to overwrite a CA) and `embed`, and
`verify-host-trust.sh` on bundles it must reject. A valid bundle needs the MnMs root private key,
which CI does not have.

`verify-host-trust.sh` checks against the hardcoded production MnMs root key. Bundles made for a
`test-license-root` build (development and e2e) do not verify with it. Test it with a real bundle,
or with a bundle you have edited to break, to confirm it fails.

`make-host-mtls.sh` can be tried in a scratch directory. It refuses to overwrite an existing CA or
key:

```bash
d=$(mktemp -d)
./make-host-mtls.sh ca "$d" test-host
./make-host-mtls.sh cert "$d" mnms-servers localhost 127.0.0.1
cp installmnmagent.sh "$d/" && ./make-host-mtls.sh embed "$d" "$d/installmnmagent.sh"
```

For a full run, onboard a disposable VM with the install script and check the result there
(`systemctl status mnms-host.socket mnms-vaultd mnms-agent-supervisor mnms-haproxy-adapter`,
`ls -l /etc/mnms/pki /etc/mnms/vaultd.env`, port 9443 listening).

### CI

`.github/workflows/ci.yml` runs on pushes and pull requests to `main`: `bash -n` and `shellcheck` on
`*.sh` and `.github/scripts/*.sh`, PSScriptAnalyzer on `installmnmagent.ps1` (errors and warnings,
`PSAvoidUsingWriteHost` excluded), and `.github/scripts/smoke.sh`. The onboarding scripts change a
real host, so CI only parses and lints them.
