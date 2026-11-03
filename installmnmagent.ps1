# Provisions the MnMs Agent host stack (mnms-host, mnms-vaultd, mnms-agent-supervisor,
# mnms-haproxy-adapter) on a fresh Linux VM from Windows, via OpenSSH (not Posh-SSH/password auth).
#
# Usage: .\installmnmagent.ps1 -IpAddress <IP> -TrustBundle host-trust.json -MtlsKey mnms-mtls.key
#                              -ManagersJson managers.json -ManagerCert manager.crt
#                              [-MachineId <IP>] [-PgHost <host>] [-PgPort <port>]
#                              [-SshUser root] [-KeyPath <path>]
#
#   -ManagersJson  the manager pool (`mnm pool show manager`) the Agent finds its Managers in
#   -ManagerCert   the Manager's exported QUIC certificate the Agent pins
#   -PgHost/-PgPort  the Postgres cluster for tenant service databases (MNMS_PG_HOST / MNMS_PG_PORT
#                  of install-agent.sh; default: the local socket, 5432)
#
# Checked before anything is built or installed (ADR-0027 §2b, §2c):
#   - the host trust bundle, against the MnMs root key hardcoded in verify-host-trust.sh;
#   - the host's shared mTLS certificate hardcoded below: issued by the hardcoded Host CA, still
#     valid, and -MtlsKey is its private key (the key is never in this script).
# Windows rarely has openssl, so both checks run on the target machine, in a directory only the
# SSH user can read; if either fails, nothing is installed.
#
# Auth is SSH key-based. No password is accepted as a parameter (visible in shell
# history / process listings) — configure an SSH key or agent identity first.

param(
    [Parameter(Mandatory = $true)]
    [string]$IpAddress,
    [Parameter(Mandatory = $true)]
    [string]$TrustBundle,
    [Parameter(Mandatory = $true)]
    [string]$MtlsKey,
    [Parameter(Mandatory = $true)]
    [string]$ManagersJson,
    [Parameter(Mandatory = $true)]
    [string]$ManagerCert,
    [string]$MachineId = "",
    [string]$PgHost = "",
    [string]$PgPort = "",
    [string]$SshUser = "root",
    [string]$KeyPath = ""
)

# Made by hand with make-host-mtls.sh, written in with `make-host-mtls.sh embed <dir> installmnmagent.sh installmnmagent.ps1`.
$HostCaCertPem = 'REPLACE: make-host-mtls.sh embed <dir> installmnmagent.ps1'
$MtlsCertPem = 'REPLACE: make-host-mtls.sh embed <dir> installmnmagent.ps1'

$ErrorActionPreference = "Stop"
if (-not $MachineId) { $MachineId = $IpAddress }
if ($HostCaCertPem.StartsWith("REPLACE") -or $MtlsCertPem.StartsWith("REPLACE")) {
    throw "this script has no mTLS certificates yet: run make-host-mtls.sh embed <dir> installmnmagent.ps1"
}
if (-not (Test-Path $TrustBundle)) { throw "-TrustBundle $TrustBundle does not exist" }
if (-not (Test-Path $MtlsKey)) { throw "-MtlsKey $MtlsKey does not exist" }
# Where the Agent finds its Managers and the certificate it pins (field test F19).
if (-not (Test-Path $ManagersJson)) { throw "-ManagersJson $ManagersJson does not exist" }
if (-not (Test-Path $ManagerCert)) { throw "-ManagerCert $ManagerCert does not exist" }
$membership = Get-Content -Raw $ManagersJson | ConvertFrom-Json
if (-not $membership.generation -or -not $membership.slots) { throw "-ManagersJson is not a manager membership document (generation, slots)" }
# These values end up in remote command lines: allow only an IP address and a plain file name.
if ($MachineId -notmatch '^[0-9A-Fa-f.:]+$') { throw "-MachineId must be an IP address" }
if ($PgHost -notmatch '^[A-Za-z0-9._/:-]*$') { throw "-PgHost may only contain letters, digits, '.', '_', '/', ':' and '-'" }
if ($PgPort -notmatch '^[0-9]*$') { throw "-PgPort must be a port number" }
$trustName = Split-Path -Leaf $TrustBundle
if ($trustName -notmatch '^[A-Za-z0-9._-]+$') { throw "-TrustBundle file name may only contain letters, digits, '.', '_' and '-'" }

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AgentDir = Join-Path $RepoRoot "mnms-agent"
$HostDir = Join-Path $RepoRoot "mnms-host"
$ScriptsDir = Join-Path $RepoRoot "mnms-scripts"
$DeployDir = Join-Path $RepoRoot "mnms-deploy"
$Verifier = Join-Path $PSScriptRoot "verify-host-trust.sh"

foreach ($d in @($AgentDir, $HostDir, $ScriptsDir, $DeployDir)) {
    if (-not (Test-Path $d)) {
        throw "expected sibling checkout at $d (run from a MnMs workspace checkout, next to mnms-agent, mnms-host, mnms-scripts and mnms-deploy)"
    }
}

$sshArgs = @("-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10")
if ($KeyPath) { $sshArgs += @("-i", $KeyPath) }
$target = "$SshUser@$IpAddress"
$R = "/tmp/mnms-onboard"   # created 0700 on the target, removed at the end or on failure

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("mnms-onboard-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    Write-Host "Testing SSH connection to $IpAddress..."
    & ssh @sshArgs $target "rm -rf $R && install -d -m 700 $R && echo SSH connection successful"
    if ($LASTEXITCODE -ne 0) { throw "SSH connection failed" }

    # The checks come first: nothing is built or installed for a host MnMs has not licensed.
    Write-Host "Verifying the host trust bundle and the mTLS certificate on $IpAddress..."
    Set-Content -NoNewline -Path (Join-Path $stage "host-ca.crt") -Value ($HostCaCertPem + "`n")
    Set-Content -NoNewline -Path (Join-Path $stage "mnms-mtls.crt") -Value ($MtlsCertPem + "`n")
    & scp @sshArgs $Verifier $TrustBundle (Join-Path $stage "host-ca.crt") (Join-Path $stage "mnms-mtls.crt") "${target}:$R/"
    if ($LASTEXITCODE -ne 0) { throw "scp failed" }
    & scp @sshArgs $MtlsKey "${target}:$R/mnms-mtls.key"
    if ($LASTEXITCODE -ne 0) { throw "scp failed" }
    & scp @sshArgs $ManagersJson "${target}:$R/managers.json"
    if ($LASTEXITCODE -ne 0) { throw "scp failed" }
    & scp @sshArgs $ManagerCert "${target}:$R/manager.crt"
    if ($LASTEXITCODE -ne 0) { throw "scp failed" }
    $checks = @'
set -euo pipefail
R="$1" TRUST_NAME="$2"
chmod 600 "$R/mnms-mtls.key"
bash "$R/verify-host-trust.sh" "$R/$TRUST_NAME"
openssl verify -CAfile "$R/host-ca.crt" "$R/mnms-mtls.crt" >/dev/null 2>&1 \
  || { echo "ERROR: the hardcoded mTLS certificate is not issued by the hardcoded Host CA" >&2; exit 1; }
openssl x509 -in "$R/mnms-mtls.crt" -noout -checkend 0 >/dev/null \
  || { echo "ERROR: the hardcoded mTLS certificate has expired" >&2; exit 1; }
[ "$(openssl pkey -in "$R/mnms-mtls.key" -pubout 2>/dev/null)" = "$(openssl x509 -in "$R/mnms-mtls.crt" -noout -pubkey)" ] \
  || { echo "ERROR: -MtlsKey is not the private key of the hardcoded mTLS certificate" >&2; exit 1; }
echo "mTLS certificate verified: $(openssl x509 -in "$R/mnms-mtls.crt" -noout -subject)"
'@
    $checks | & ssh @sshArgs $target "bash -s -- '$R' '$trustName'"
    if ($LASTEXITCODE -ne 0) { throw "a check failed (see above); nothing was installed" }

    Write-Host "Building release binaries (mnms-host, mnms-vaultd, mnms-agent-supervisor, mnms-agent-runtime, mnms-haproxy-adapter)..."
    Push-Location $HostDir
    try {
        cargo build --release
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed (mnms-host)" }
    } finally {
        Pop-Location
    }
    Push-Location $AgentDir
    try {
        cargo build --release -p mnms-agent-supervisor -p mnms-agent-runtime -p mnms-vaultd -p mnms-haproxy-adapter
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed (mnms-agent)" }
    } finally {
        Pop-Location
    }

    # install-agent.sh installs the provisioning scripts mnms-host runs (tenant users, service
    # databases) and needs them next to it, so the whole mnms-scripts set travels as one archive,
    # and mnms-host's systemd units and polkit policy and mnms-deploy's units travel with it.
    $archive = Join-Path $stage "mnms-scripts.tgz"
    & tar.exe -czf $archive --exclude=.git --exclude=lab --exclude=tests --exclude=docs -C $ScriptsDir .
    if ($LASTEXITCODE -ne 0) { throw "tar failed (Windows 10+ ships tar.exe)" }
    $hostFiles = Join-Path $stage "mnms-host-files.tgz"
    & tar.exe -czf $hostFiles -C $HostDir systemd polkit
    if ($LASTEXITCODE -ne 0) { throw "tar failed" }
    $deployUnits = Join-Path $stage "mnms-deploy-units.tgz"
    & tar.exe -czf $deployUnits -C $DeployDir systemd
    if ($LASTEXITCODE -ne 0) { throw "tar failed" }

    Write-Host "Copying binaries and mnms-scripts to $IpAddress..."
    $files = @(
        (Join-Path $HostDir "target\release\mnms-host"),
        (Join-Path $AgentDir "target\release\mnms-vaultd"),
        (Join-Path $AgentDir "target\release\mnms-agent-supervisor"),
        (Join-Path $AgentDir "target\release\mnms-agent-runtime"),
        (Join-Path $AgentDir "target\release\mnms-haproxy-adapter"),
        $archive,
        $hostFiles,
        $deployUnits
    )
    & scp @sshArgs $files "${target}:$R/"
    if ($LASTEXITCODE -ne 0) { throw "scp failed" }

    Write-Host "Installing on $IpAddress..."
    # The machine id, bundle name and Postgres settings are passed as arguments, never pasted into
    # the script text.
    $remoteScript = @'
set -euo pipefail
R="$1" MACHINE_ID="$2" TRUST_NAME="$3" PG_HOST="$4" PG_PORT="$5"
sudo mkdir -p /usr/local/bin
sudo install -d -m 0755 /mnm/identity
sudo install -m 0644 -o root -g root "$R/manager.crt" /mnm/identity/manager.crt
sudo install -m 0644 "$R/managers.json" /mnm/identity/managers.json
sudo install -m 755 "$R/mnms-vaultd" "$R/mnms-agent-supervisor" "$R/mnms-agent-runtime" "$R/mnms-haproxy-adapter" /usr/local/bin/
mkdir -p "$R/mnms-scripts" "$R/mnms-host-files" "$R/mnms-deploy-units"
tar xzf "$R/mnms-scripts.tgz" -C "$R/mnms-scripts"
tar xzf "$R/mnms-host-files.tgz" -C "$R/mnms-host-files"
tar xzf "$R/mnms-deploy-units.tgz" -C "$R/mnms-deploy-units"
sudo MNMS_HOST_BIN="$R/mnms-host" MNMS_HOST_TRUST_BUNDLE="$R/$TRUST_NAME" MNMS_MACHINE_ID="$MACHINE_ID" \
  MNMS_HOST_UNITS_DIR="$R/mnms-host-files/systemd" MNMS_HOST_POLKIT_DIR="$R/mnms-host-files/polkit" \
  MNMS_DEPLOY_UNITS_DIR="$R/mnms-deploy-units/systemd" MNMS_PG_HOST="$PG_HOST" MNMS_PG_PORT="$PG_PORT" \
  bash "$R/mnms-scripts/install-agent.sh"

# The host's mTLS material: certificates public, the key root-only; HAProxy reads the combined PEM.
sudo install -d -m 0755 -o root -g root /etc/mnms/pki
sudo install -m 0644 -o root -g root "$R/host-ca.crt" "$R/mnms-mtls.crt" /etc/mnms/pki/
sudo install -m 0600 -o root -g root "$R/mnms-mtls.key" /etc/mnms/pki/mnms-mtls.key
# mnms-haproxy-adapter runs HAProxy as the Agent user (systemd/mnms-haproxy-adapter.service).
GRP=mnms-agent
sudo sh -c 'umask 077; cat /etc/mnms/pki/mnms-mtls.crt /etc/mnms/pki/mnms-mtls.key >/etc/mnms/pki/mnms-mtls.pem'
sudo chgrp "$GRP" /etc/mnms/pki/mnms-mtls.pem && sudo chmod 0640 /etc/mnms/pki/mnms-mtls.pem
# The adapter reads the mTLS files at start: restart it so the platform entrance (9443) comes up.
sudo systemctl restart mnms-haproxy-adapter.service
'@
    $remoteScript | & ssh @sshArgs $target "bash -s -- '$R' '$MachineId' '$trustName' '$PgHost' '$PgPort'"
    if ($LASTEXITCODE -ne 0) { throw "remote install failed" }
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
    & ssh @sshArgs $target "rm -rf $R" 2>$null
}

Write-Host "Agent host stack installed on $IpAddress; the platform mTLS entrance is port 9443 (mnms-haproxy-adapter)."
Write-Host "The vault master key is in /etc/mnms/vaultd.env on ${IpAddress}: back it up, the vault cannot be read without it."
Write-Host "Note: mnms-agent-supervisor.service (from mnms-deploy) expects a Podman OCI image"
Write-Host "(MNMS_RUNTIME_IMAGE) by default. For a bare VM without a registry yet, set"
Write-Host "MNMS_RUNTIME_DEV_BINARY=/usr/local/bin/mnms-agent-runtime in an override instead;"
Write-Host "see mnms-agent/README.md."
