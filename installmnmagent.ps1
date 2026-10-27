# Provisions the MnMs Agent host stack (mnms-host, mnms-vaultd, mnms-agent-supervisor)
# on a fresh Linux VM from Windows, via OpenSSH (not Posh-SSH/password auth).
#
# Usage: .\installmnmagent.ps1 -IpAddress <IP> -TrustBundle host-trust.json -MtlsKey mnms-mtls.key
#                              [-MachineId <IP>] [-SshUser root] [-KeyPath <path>]
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
    [string]$MachineId = "",
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
# These values end up in remote command lines: allow only an IP address and a plain file name.
if ($MachineId -notmatch '^[0-9A-Fa-f.:]+$') { throw "-MachineId must be an IP address" }
$trustName = Split-Path -Leaf $TrustBundle
if ($trustName -notmatch '^[A-Za-z0-9._-]+$') { throw "-TrustBundle file name may only contain letters, digits, '.', '_' and '-'" }

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AgentDir = Join-Path $RepoRoot "mnms-agent"
$HostDir = Join-Path $RepoRoot "mnms-host"
$ScriptsDir = Join-Path $RepoRoot "mnms-scripts"
$Verifier = Join-Path $PSScriptRoot "verify-host-trust.sh"

foreach ($d in @($AgentDir, $HostDir, $ScriptsDir)) {
    if (-not (Test-Path $d)) {
        throw "expected sibling checkout at $d (run from a MnMs workspace checkout, next to mnms-agent, mnms-host and mnms-scripts)"
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

    Write-Host "Building release binaries (mnms-host, mnms-vaultd, mnms-agent-supervisor, mnms-agent-runtime)..."
    Push-Location $HostDir
    try {
        cargo build --release
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed (mnms-host)" }
    } finally {
        Pop-Location
    }
    Push-Location $AgentDir
    try {
        cargo build --release -p mnms-agent-supervisor -p mnms-agent-runtime -p mnms-vaultd
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed (mnms-agent)" }
    } finally {
        Pop-Location
    }

    # install-agent.sh installs the provisioning scripts mnms-host runs (tenant users, service
    # databases) and needs them next to it, so the whole mnms-scripts set travels as one archive,
    # and mnms-host's systemd units and polkit policy travel with it.
    $archive = Join-Path $stage "mnms-scripts.tgz"
    & tar.exe -czf $archive --exclude=.git --exclude=lab --exclude=tests --exclude=docs -C $ScriptsDir .
    if ($LASTEXITCODE -ne 0) { throw "tar failed (Windows 10+ ships tar.exe)" }
    $hostFiles = Join-Path $stage "mnms-host-files.tgz"
    & tar.exe -czf $hostFiles -C $HostDir systemd polkit
    if ($LASTEXITCODE -ne 0) { throw "tar failed" }

    Write-Host "Copying binaries and mnms-scripts to $IpAddress..."
    $files = @(
        (Join-Path $HostDir "target\release\mnms-host"),
        (Join-Path $AgentDir "target\release\mnms-vaultd"),
        (Join-Path $AgentDir "target\release\mnms-agent-supervisor"),
        (Join-Path $AgentDir "target\release\mnms-agent-runtime"),
        $archive,
        $hostFiles
    )
    & scp @sshArgs $files "${target}:$R/"
    if ($LASTEXITCODE -ne 0) { throw "scp failed" }

    Write-Host "Installing on $IpAddress..."
    # The machine id and bundle name are passed as arguments, never pasted into the script text.
    $remoteScript = @'
set -euo pipefail
R="$1" MACHINE_ID="$2" TRUST_NAME="$3"
sudo mkdir -p /usr/local/bin
sudo install -m 755 "$R/mnms-vaultd" "$R/mnms-agent-supervisor" "$R/mnms-agent-runtime" /usr/local/bin/
mkdir -p "$R/mnms-scripts" "$R/mnms-host-files"
tar xzf "$R/mnms-scripts.tgz" -C "$R/mnms-scripts"
tar xzf "$R/mnms-host-files.tgz" -C "$R/mnms-host-files"
sudo MNMS_HOST_BIN="$R/mnms-host" MNMS_HOST_TRUST_BUNDLE="$R/$TRUST_NAME" MNMS_MACHINE_ID="$MACHINE_ID" \
  MNMS_HOST_UNITS_DIR="$R/mnms-host-files/systemd" MNMS_HOST_POLKIT_DIR="$R/mnms-host-files/polkit" \
  bash "$R/mnms-scripts/install-agent.sh"

# The host's mTLS material: certificates public, the key root-only; HAProxy reads the combined PEM.
sudo install -d -m 0755 -o root -g root /etc/mnms/pki
sudo install -m 0644 -o root -g root "$R/host-ca.crt" "$R/mnms-mtls.crt" /etc/mnms/pki/
sudo install -m 0600 -o root -g root "$R/mnms-mtls.key" /etc/mnms/pki/mnms-mtls.key
# mnms-haproxy-adapter runs HAProxy as the Agent user (systemd/mnms-haproxy-adapter.service).
GRP=mnms-agent
sudo sh -c 'umask 077; cat /etc/mnms/pki/mnms-mtls.crt /etc/mnms/pki/mnms-mtls.key >/etc/mnms/pki/mnms-mtls.pem'
sudo chgrp "$GRP" /etc/mnms/pki/mnms-mtls.pem && sudo chmod 0640 /etc/mnms/pki/mnms-mtls.pem
'@
    $remoteScript | & ssh @sshArgs $target "bash -s -- '$R' '$MachineId' '$trustName'"
    if ($LASTEXITCODE -ne 0) { throw "remote install failed" }
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
    & ssh @sshArgs $target "rm -rf $R" 2>$null
}

Write-Host "Agent host stack installed on $IpAddress; the platform mTLS entrance is port 9443 once mnms-haproxy-adapter runs."
Write-Host "Note: install-agent.sh's mnms-agent-supervisor.service expects a Podman OCI image"
Write-Host "(MNMS_RUNTIME_IMAGE) by default. For a bare VM without a registry yet, set"
Write-Host "MNMS_RUNTIME_DEV_BINARY=/usr/local/bin/mnms-agent-runtime in an override instead;"
Write-Host "see mnms-agent/README.md."
