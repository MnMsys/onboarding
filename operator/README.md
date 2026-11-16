# Operator kit: using the `mnm` CLI

`mnm` is how people work with MnMs: see machines and services, read logs, restart, roll out and
roll back. Each person signs in with **their own client certificate**, issued by the host's CA;
the control plane's entrance (port 9443) refuses anyone without one, and the API knows you by the
certificate's name. What you may do comes from the **role** DevOps assigns to that name.

Setup is once per person, about 10 minutes, in two steps.

## For the operator

You need Linux, macOS or Windows with **WSL** (Ubuntu): `mnm` does not run natively on Windows.
On Windows, run everything below inside WSL.

**Step 1: ask for access.** Pick your name (lowercase, e.g. `jane-doe`; it appears in the audit
trail) and run:

```bash
bash mnm-operator.sh request jane-doe
```

It makes your private key in `~/.config/mnm/certs/` (it never leaves your machine) and prints a
certificate request. Send DevOps the request **and the public IP you connect from**
(`curl -s https://ifconfig.me`). Say what you need to do, so they can pick your role.

**Step 2: install.** DevOps sends back a directory (no secrets in it): your certificate, the
host's CA certificate, the gateway address and, for Linux/WSL, the `mnm` binary. Then:

```bash
bash mnm-operator.sh install --bundle ./operator-bundle-jane-doe
```

It checks the certificate is yours and valid, installs `mnm` as `~/.local/bin/mnm`, adds the
host (`mnm host add`, whose document is verified against the MnMs root key), selects your tenant,
adds one line to `~/.bashrc` / `~/.zshrc`, and runs `mnm health`.

Open a new shell, then:

```bash
mnm whoami
mnm authz effective                 # what you may do
mnm service list
mnm run container ps <machine-ip>
mnm run container logs <machine-ip> <service> --lines 50
```

`bash mnm-operator.sh status` shows your setup and when your certificate expires (30 days by
default). Before it expires, run step 1 again with the same name (your key is kept) and send the
new request.

`mnm host add` through the entrance needs an `mnm` built with mnms-cli `69a44a1` or later
(`fix/host-add-tls`): older builds fetch the host document without the CA and client certificate
and fail with "error sending request". The bundle's binary has it.

**Not available yet:** `mnm logs follow`, `mnm shell` (live streams are not routed through the
entrance yet) and `mnm ssh` (the SSH gateway is not deployed).

**If something fails:**

| Message | Meaning |
|---|---|
| `mnm health` times out | your IP is not allowed on the gateway yet: ask DevOps |
| `alert certificate required` / `unknown ca` | `~/.config/mnm/env.sh` not loaded (new shell), or not the certificate from the bundle |
| `certificate has expired` | ask for a new one (step 1 again) |
| `denied: … roles that grant …` | your role does not include that action; the message names the roles that would |
| `Cannot find module` from `mnm` | an old Node.js `mnm-cli` from npm is on your PATH first; open a new shell, or `npm unlink -g mnm-cli` |

## For DevOps

From the build machine, where the Host CA lives (`~/mnms-keys/pki`):

```bash
./issue-operator-cert.sh --csr jane-doe.csr --pki ~/mnms-keys/pki \
    --gateway https://95.216.156.203:9443 \
    --mnm ~/mnms-release/mnms-cli/target/release/mnm      # optional, Linux/WSL binary
```

It refuses a request whose subject is not exactly `CN=<name>,O=<tenant>`, a reserved name
(`platform-admin`, `root`, …) or a bad signature; issues a client-only certificate (30 days,
`--days` up to 90); and writes `operator-bundle-<name>/` with a `SHA256SUMS`. Then, after deciding
what the person may do:

```bash
mnm authz assign jane-doe builtin/appops --tenant scomm        # role (see: mnm authz roles)
# on the control plane: their IP on the entrance, then save
iptables -I INPUT 1 -s <ip>/32 -p tcp --dport 9443 -m comment --comment "MnMs entrance 9443: operator jane-doe" -j ACCEPT
netfilter-persistent save
```

Common roles: `builtin/viewer` (read only), `builtin/appops` (see and restart services),
`builtin/tenant-admin`, `builtin/platform-owner` (everything; keep to a few people). Container root
always needs `builtin/container-root` **and** an elevation approved by someone else.

**Offboarding:** `mnm authz revoke <assignment>` (see `mnm authz assignments`), remove their
firewall rule; the certificate then expires by itself.

The host document `mnm host add` reads is served by the API from `MNMS_API_HOST_DOCUMENT`
(`mnm host document --gateway https://<cp>:9443`, signed with the host key; re-sign it when the
gateway address or the license changes).
