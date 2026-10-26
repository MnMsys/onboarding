# Onboarding Scripts

Provisions the MnMs Agent host stack — `mnms-host` and `mnms-vaultd` (root, immutable) plus
`mnms-agent-supervisor` (rootless launcher) — on a fresh Linux VM. Builds release binaries from the
sibling `mnms-host` and `mnms-agent` checkouts and installs them via
`mnms-scripts/install-agent.sh`, which also creates the `mnms-agent` system user and the systemd
units. The whole `mnms-scripts` set is copied to the host with it: the installer puts the
provisioning scripts `mnms-host` runs (tenant users, service databases) into `/usr/local/lib/mnms`
and aborts before changing anything if any are missing.

Run these from a MnMs workspace checkout (so `../mnms-host`, `../mnms-agent` and `../mnms-scripts`
exist next to this repo).

## The license check comes first

Every machine needs the host's trust bundle, `host-trust.json`: the host's license from MnMs and the
host's certificate for its Manager's task key (ADR-0027 §2b). Both scripts verify it **before
anything is built, copied or installed**, with `verify-host-trust.sh`, which has the MnMs root
public key hardcoded (changing it is against the MnMs terms of service). The check fails if:

- the license is not signed by the MnMs root key;
- the certificate is for another host, or not signed by the licensed host key;
- the license or the certificate has expired.

`verify-host-trust.sh host-trust.json` also runs on its own. It needs `openssl` (3.x) and `python3`.
The bash script runs it locally; the PowerShell script runs it on the target machine, since
Windows rarely has openssl. On the machine, `mnms-host` checks the bundle again once, when it starts.

Getting the files: the host owner runs `mnm host keygen --name <host>`, sends
`host-license-request.json` to MnMs and receives `host-license.json`, then runs
`mnm host sign-task-key --task-key "$(mnms-manager task-key)"` and `mnm host trust-bundle`.

## The host's mTLS certificate

For now one host serves all tenants, and its servers share **one** mTLS certificate, made by hand
(ADR-0027 §2c, lead 2026-10-26). HAProxy's platform entrance (port 9443, rendered by
mnms-haproxy-adapter) accepts only clients presenting a certificate from the Host CA.

```sh
./make-host-mtls.sh ca   pki <host-name>                       # Host CA: pki/host-ca.key stays offline
./make-host-mtls.sh cert pki mnms-servers <dns-or-ip> ...      # the shared certificate + its key
./make-host-mtls.sh embed pki installmnmagent.sh installmnmagent.ps1   # writes in the two certificates
```

The scripts carry only the two **certificates** (public). The certificate's private key
`pki/mnms-mtls.key` is passed at onboarding (`--mtls-key` / `-MtlsKey`); it is checked against the
hardcoded certificate and installed root-only in `/etc/mnms/pki` on the machine. Never commit it.

## Scripts

### 1. `installmnmagent.sh`
Bash, for Linux/macOS.

```sh
./installmnmagent.sh <ip> --trust host-trust.json --mtls-key pki/mnms-mtls.key [--machine-id <ip>] [--user root] [--key ~/.ssh/id_ed25519]
```

### 2. `installmnmagent.ps1`
PowerShell, for Windows (uses OpenSSH, not a third-party SSH module).

```powershell
.\installmnmagent.ps1 -IpAddress <ip> -TrustBundle host-trust.json -MtlsKey pki\mnms-mtls.key [-MachineId <ip>] [-SshUser root] [-KeyPath ~\.ssh\id_ed25519]
```

`--machine-id` / `-MachineId` is the machine's IP as the Manager sees it (default: the target address).

## Auth

Both scripts are **SSH key-based** — neither accepts a password as a parameter or
hardcodes one. Configure an SSH key or agent identity on the target VM before running
these (e.g. via your VM provider's cloud-init / key injection at creation time).

## What gets installed

See `mnms-scripts/install-agent.sh` and `mnms-agent/README.md` for the resulting
service topology: `mnms-host`/`mnms-vaultd` (root) never run a shell or arbitrary
exec on the caller's behalf — only typed, allowlisted operations — and are the only
things on the host running as root. Everything else, including the Agent runtime
itself, runs rootless.

The Agent runtime container needs a Podman image (`MNMS_RUNTIME_IMAGE`) by default;
for a host without a registry yet, override with `MNMS_RUNTIME_DEV_BINARY` to run the
copied `mnms-agent-runtime` binary directly instead (see `mnms-agent/README.md`).

## License
See [LICENSE](LICENSE) for details.
