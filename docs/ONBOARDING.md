# Onboarding (for engineers)

## Role in MnMs

An MnMs **host** is the operator's installation: a Manager pool and the machines it runs tenants
on. This repo turns a bare Linux machine into one of those machines. It sits at the start of every
machine's life:

```text
host owner: mnm host keygen -> MnMs signs the license -> mnm host sign-task-key -> mnm host trust-bundle
                                                                                  |
operator workstation: make-host-mtls.sh (once) -> installmnmagent.sh/.ps1 <-------+ host-trust.json
   verify-host-trust.sh -> cargo build (mnms-host, mnms-agent) -> scp -> ssh
                                                                         |
target machine: mnms-scripts/install-agent.sh
   -> mnms-host (root, socket-activated), mnms-vaultd (root), mnms-agent-supervisor (rootless),
      mnms-haproxy-adapter (rootless; platform entrance 9443), units from mnms-host and mnms-deploy
   -> /mnm/identity/{host-trust.json, managers.json, manager.crt}, /etc/mnms/pki/*,
      /etc/mnms/vaultd.env (vault master key, made once)
   -> Agent connects to the Manager over QUIC and registers (machine key held by mnms-host)
```

After onboarding, nothing in this repo runs again on the machine. Day-to-day work goes through the
Manager, the Agent and mnms-host.

## The three trust pieces (ADR-0027 §2b, §2c; lead decision 2026-10-26)

The lead decided to build the core first, without automation. So trust is wired by hand:

- **Hardcoded root key.** `verify-host-trust.sh` holds the MnMs root public key. mnms-protocol
  compiles the same key into mnms-host and the Agent (`MNMS_ROOT_PUBLIC_KEY_B64`). Keep the two
  identical.
- **Hand-made license.** The host owner makes a key and a license request with `mnm host keygen`.
  MnMs signs the license. The owner then certifies the Manager pool's task key and builds
  `host-trust.json`. The chain is MnMs root, then host license, then host key, then task key.
  The onboarding scripts refuse to build or copy anything for an unlicensed host. mnms-host
  checks the chain again once at startup and takes the Manager's task key only from it.
- **Shared mTLS certificate.** One Host CA and one certificate shared by all of the host's servers,
  made with `make-host-mtls.sh`. Only the public certificates are embedded in the install scripts.
  The private key is passed at onboarding time and stored root-only on the machine.

## Code map

| File | Responsibility |
|---|---|
| `installmnmagent.sh` | Bash onboarding: checks, build, copy, remote install, mTLS material |
| `installmnmagent.ps1` | Same for Windows; runs the checks on the target |
| `verify-host-trust.sh` | Trust-bundle verifier with the hardcoded root key (OpenSSL + Python) |
| `make-host-mtls.sh` | Host CA, shared certificate, and `embed` into the two install scripts |
| `.github/workflows/ci.yml`, `.github/scripts/smoke.sh` | CI: `bash -n`, shellcheck, PSScriptAnalyzer, smoke test of `make-host-mtls.sh` and `verify-host-trust.sh` |

The work on the machine is done by `mnms-scripts/install-agent.sh` and
`mnms-scripts/install-provision-scripts.sh`. Change those in mnms-scripts, not here.

## Invariants

- Check first, then act. The license, certificates and Manager files are all verified before
  anything is built, copied or installed.
- No secrets in the scripts and no passwords on command lines. SSH is key-based. The mTLS private
  key comes from a file and is installed `0600 root`. `pki/` and `*.key` are git-ignored.
- Values from the operator reach the remote shell as arguments (`bash -s -- ...`), never pasted
  into the script text. Both restrict the machine id to an IP address and the Postgres host and port
  to safe characters; the `.ps1` also restricts the bundle file name.
- The bash and PowerShell scripts do the same thing. A change to one needs the same change in the
  other.

## Making a typical change

Example: pass a new setting through to `install-agent.sh`.

1. Add the flag to `usage()` and the argument loop in `installmnmagent.sh`. Validate it locally.
2. Pass it to the remote heredoc as an argument and export it for `install-agent.sh` on the `sudo`
   line.
3. Do the same in `installmnmagent.ps1`: a `param()` entry, validation, and an argument of the remote
   script.
4. If `install-agent.sh` must read it, change that in mnms-scripts.
5. Update [USAGE.md](USAGE.md).
6. Test: `bash -n`, then onboard a disposable VM and check the units and files there.

## Workspace conventions

- Greenfield: no legacy paths or compatibility shims. Fix wrong things directly.
- One privileged host authority (mnms-host). The onboarding only installs it; it never adds another
  root service.
- Keep files under about 500 lines.

## Gotchas

- The install scripts need the sibling checkouts (mnms-agent, mnms-host, mnms-scripts, mnms-deploy,
  and mnms-protocol to build), and they build them on the workstation.
  The binaries must match the target's architecture and libc.
- `make-host-mtls.sh embed` edits the install scripts in place. Do not commit a script with
  embedded certificates unless that is intended for this host.
- `verify-host-trust.sh` trusts only the production root. Bundles for `test-license-root` builds fail
  it. The e2e harness in mnms-scripts does not use these scripts.
- The remote steps use `sudo` even for the root user, so `sudo` must exist on the target.
- `/etc/mnms/vaultd.env` holds the vault master key. `install-agent.sh` makes it once and never
  overwrites it; a reinstalled machine without a backup of it cannot read its vault.
- mnms-haproxy-adapter reads `/etc/mnms/pki` only at start, so the scripts restart it after
  installing the mTLS files.
- `mnms-agent-supervisor` is enabled only if `host-trust.json`, `managers.json` and `manager.crt`
  are present, which these scripts guarantee. It still needs the Agent runtime image, or
  `MNMS_RUNTIME_DEV_BINARY`.

## Read first

- ADR-0027, platform data model (host license, trust bundle, mTLS):
  https://github.com/MnMsys/mnms-design/blob/main/docs/adr/ADR-0027-platform-data-model.md
- ADR-0025, host privilege boundary:
  https://github.com/MnMsys/mnms-design/blob/main/docs/adr/ADR-0025-host-privilege-boundary-polkit.md
- Agent transport: https://github.com/MnMsys/mnms-design/blob/main/docs/AGENT_QUIC_TRANSPORT.md
- mnms-host `DEPLOYMENT.md` and `mnms-scripts/install-agent.sh` for what ends up on the machine
