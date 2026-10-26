# Provisions the MnMs Agent host stack (mnms-host, mnms-vaultd, mnms-agent-supervisor)
# on a fresh Linux VM from Windows, via OpenSSH (not Posh-SSH/password auth).
#
# Usage: .\installmnmagent.ps1 -IpAddress <IP> -TrustBundle host-trust.json [-MachineId <IP>]
#                              [-SshUser root] [-KeyPath <path>]
#
# The host trust bundle (`mnm host trust-bundle`) is verified first, against the MnMs root key
# hardcoded in verify-host-trust.sh (ADR-0027 §2b). Windows rarely has openssl, so the check runs
# on the target machine before anything else is built or copied; if it fails, nothing is installed.
#
# Auth is SSH key-based. No password is accepted as a parameter (visible in shell
# history / process listings) — configure an SSH key or agent identity first.

param(
    [Parameter(Mandatory = $true)]
    [string]$IpAddress,
    [Parameter(Mandatory = $true)]
    [string]$TrustBundle,
    [string]$MachineId = "",
    [string]$SshUser = "root",
    [string]$KeyPath = ""
)

$ErrorActionPreference = "Stop"
if (-not $MachineId) { $MachineId = $IpAddress }
if (-not (Test-Path $TrustBundle)) { throw "-TrustBundle $TrustBundle does not exist" }
# Both values end up in remote command lines: allow only an IP address and a plain file name.
if ($MachineId -notmatch '^[0-9A-Fa-f.:]+$') { throw "-MachineId must be an IP address" }
if ((Split-Path -Leaf $TrustBundle) -notmatch '^[A-Za-z0-9._-]+$') { throw "-TrustBundle file name may only contain letters, digits, '.', '_' and '-'" }

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

Write-Host "Testing SSH connection to $IpAddress..."
& ssh @sshArgs "$SshUser@$IpAddress" "echo SSH connection successful"
if ($LASTEXITCODE -ne 0) { throw "SSH connection failed" }

# The license check comes first: nothing is built or installed for a host MnMs has not licensed.
Write-Host "Verifying the host trust bundle on $IpAddress..."
& scp @sshArgs $Verifier $TrustBundle "${SshUser}@${IpAddress}:/tmp/"
if ($LASTEXITCODE -ne 0) { throw "scp failed" }
$trustName = Split-Path -Leaf $TrustBundle
& ssh @sshArgs "$SshUser@$IpAddress" "bash /tmp/verify-host-trust.sh '/tmp/$trustName'"
if ($LASTEXITCODE -ne 0) {
    & ssh @sshArgs "$SshUser@$IpAddress" "rm -f /tmp/verify-host-trust.sh '/tmp/$trustName'"
    throw "the host trust bundle did not verify; nothing was installed"
}

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
# databases) and needs them next to it, so the whole mnms-scripts set travels as one archive, and
# mnms-host's systemd units and polkit policy travel with it.
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("mnms-scripts-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stage | Out-Null
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
& scp @sshArgs $files "${SshUser}@${IpAddress}:/tmp/"
$scpExit = $LASTEXITCODE
Remove-Item -Recurse -Force $stage
if ($scpExit -ne 0) { throw "scp failed" }

Write-Host "Installing on $IpAddress..."
# The machine id and bundle name are passed as arguments, never pasted into the script text.
$remoteScript = @'
set -euo pipefail
MACHINE_ID="$1" TRUST_NAME="$2"
sudo mkdir -p /usr/local/bin
sudo install -m 755 /tmp/mnms-vaultd /tmp/mnms-agent-supervisor /tmp/mnms-agent-runtime /usr/local/bin/
rm -rf /tmp/mnms-scripts /tmp/mnms-host-files && mkdir -p /tmp/mnms-scripts /tmp/mnms-host-files
tar xzf /tmp/mnms-scripts.tgz -C /tmp/mnms-scripts
tar xzf /tmp/mnms-host-files.tgz -C /tmp/mnms-host-files
sudo MNMS_HOST_BIN=/tmp/mnms-host MNMS_HOST_TRUST_BUNDLE="/tmp/$TRUST_NAME" MNMS_MACHINE_ID="$MACHINE_ID" \
  MNMS_HOST_UNITS_DIR=/tmp/mnms-host-files/systemd MNMS_HOST_POLKIT_DIR=/tmp/mnms-host-files/polkit \
  bash /tmp/mnms-scripts/install-agent.sh
rm -rf /tmp/mnms-scripts /tmp/mnms-scripts.tgz /tmp/mnms-host-files /tmp/mnms-host-files.tgz
rm -f /tmp/mnms-host /tmp/mnms-vaultd /tmp/mnms-agent-supervisor /tmp/mnms-agent-runtime "/tmp/$TRUST_NAME" /tmp/verify-host-trust.sh
'@
$remoteScript | & ssh @sshArgs "$SshUser@$IpAddress" "bash -s -- '$MachineId' '$trustName'"
if ($LASTEXITCODE -ne 0) { throw "remote install failed" }

Write-Host "Agent host stack installed on $IpAddress."
Write-Host "Note: install-agent.sh's mnms-agent-supervisor.service expects a Podman OCI image"
Write-Host "(MNMS_RUNTIME_IMAGE) by default. For a bare VM without a registry yet, set"
Write-Host "MNMS_RUNTIME_DEV_BINARY=/usr/local/bin/mnms-agent-runtime in an override instead;"
Write-Host "see mnms-agent/README.md."
