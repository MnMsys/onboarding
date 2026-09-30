
# Onboarding Scripts

Provisions the MnMs Agent host stack — `mnms-hostd` and `mnms-vaultd` (root, immutable)
plus `mnms-agent-supervisor` (rootless launcher) — on a fresh Linux VM. Builds release
binaries from the sibling `mnms-agent` checkout and installs them via
`mnms-scripts/install-agent.sh`, which also creates the `mnms-agent` system user and
the systemd units.

Run these from a MnMs workspace checkout (so `../mnms-agent` and `../mnms-scripts`
exist next to this repo).

## Scripts

### 1. `installmnmagent.sh`
Bash, for Linux/macOS.

```sh
./installmnmagent.sh <ip> [--user root] [--key ~/.ssh/id_ed25519]
```

### 2. `installmnmagent.ps1`
PowerShell, for Windows (uses OpenSSH, not a third-party SSH module).

```powershell
.\installmnmagent.ps1 -IpAddress <ip> [-SshUser root] [-KeyPath ~\.ssh\id_ed25519]
```

## Auth

Both scripts are **SSH key-based** — neither accepts a password as a parameter or
hardcodes one. Configure an SSH key or agent identity on the target VM before running
these (e.g. via your VM provider's cloud-init / key injection at creation time).

## What gets installed

See `mnms-scripts/install-agent.sh` and `mnms-agent/README.md` for the resulting
service topology: `mnms-hostd`/`mnms-vaultd` (root) never run a shell or arbitrary
exec on the caller's behalf — only typed, allowlisted operations — and are the only
things on the host running as root. Everything else, including the Agent runtime
itself, runs rootless.

The Agent runtime container needs a Podman image (`MNMS_RUNTIME_IMAGE`) by default;
for a host without a registry yet, override with `MNMS_RUNTIME_DEV_BINARY` to run the
copied `mnms-agent-runtime` binary directly instead (see `mnms-agent/README.md`).

## License
See [LICENSE](LICENSE) for details.
