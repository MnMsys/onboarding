# mnms-onboarding

Scripts that onboard a machine into an MnMs host: they check the host's license before anything
else, then build and install the Agent host stack on a fresh Linux machine over SSH. The stack is
`mnms-host` and `mnms-vaultd` (root) plus `mnms-agent-supervisor`, which runs the Agent rootless, and
`mnms-haproxy-adapter`, the edge with the platform entrance on port 9443. The
scripts run on the operator's workstation, inside an MnMs workspace checkout. They build release
binaries from the sibling `mnms-host` and `mnms-agent` checkouts, copy them, the host trust bundle,
the Manager pool document and certificate, the host's shared mTLS material, the `mnms-scripts` set
and the `mnms-deploy` systemd units to the machine, and run `mnms-scripts/install-agent.sh` there. Trust is set up by hand, with no
automation (ADR-0027, lead decision 2026-10-26): the MnMs root public key is hardcoded in
`verify-host-trust.sh`, the host license is made by hand with `mnm host ...`, and all of a host's
servers share one mTLS certificate made with `make-host-mtls.sh`.

## At a glance

| Script | Runs on | Purpose |
|---|---|---|
| `make-host-mtls.sh` | operator workstation, once per host | Make the Host CA and the shared mTLS certificate; embed the public certificates into the install scripts |
| `verify-host-trust.sh` | workstation (bash path) or target (PowerShell path) | Verify `host-trust.json` against the hardcoded MnMs root key |
| `installmnmagent.sh` | Linux or macOS workstation | Onboard one machine (bash) |
| `installmnmagent.ps1` | Windows workstation | Onboard one machine (PowerShell, OpenSSH) |

Nothing here is compiled; the repo produces no binaries.

## Quick start

```bash
./make-host-mtls.sh ca pki <host-name>                    # once per host
./make-host-mtls.sh cert pki mnms-servers <dns-or-ip> ...
./make-host-mtls.sh embed pki installmnmagent.sh installmnmagent.ps1
./verify-host-trust.sh host-trust.json
./installmnmagent.sh <machine-ip> --trust host-trust.json --mtls-key pki/mnms-mtls.key \
    --managers-json managers.json --manager-cert manager.crt
```

## Documentation

- [Setup](docs/SETUP.md): workstation prerequisites, target host prerequisites, how to test changes
- [Usage](docs/USAGE.md): every script, its arguments, and the order to run them
- [Onboarding](docs/ONBOARDING.md): where this sits in MnMs, what each step does, gotchas
- What gets installed on the machine: `mnms-scripts/install-agent.sh` and
  [mnms-host DEPLOYMENT.md](https://github.com/MnMsys/mnms-host/blob/main/DEPLOYMENT.md)
- The vault master key is created on the machine in `/etc/mnms/vaultd.env` at the first install and
  kept on re-runs. **Back it up**: the vault's secrets cannot be read without it.

## License

See [LICENSE](LICENSE).
