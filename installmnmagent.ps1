# Provisions the MnMs Agent host stack (mnms-hostd, mnms-vaultd, mnms-agent-supervisor)
# on a fresh Linux VM from Windows, via OpenSSH (not Posh-SSH/password auth).
#
# Usage: .\installmnmagent.ps1 -IpAddress <IP> [-SshUser root] [-KeyPath <path>]
#
# Auth is SSH key-based. No password is accepted as a parameter (visible in shell
# history / process listings) — configure an SSH key or agent identity first.

param(
    [Parameter(Mandatory = $true)]
    [string]$IpAddress,
    [string]$SshUser = "root",
    [string]$KeyPath = ""
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$AgentDir = Join-Path $RepoRoot "mnms-agent"
$ScriptsDir = Join-Path $RepoRoot "mnms-scripts"

foreach ($d in @($AgentDir, $ScriptsDir)) {
    if (-not (Test-Path $d)) {
        throw "expected sibling checkout at $d (run from a MnMs workspace checkout, next to mnms-agent and mnms-scripts)"
    }
}

$sshArgs = @("-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10")
if ($KeyPath) { $sshArgs += @("-i", $KeyPath) }

Write-Host "Building release binaries (mnms-hostd, mnms-vaultd, mnms-agent-supervisor, mnms-agent-runtime)..."
Push-Location $AgentDir
try {
    cargo build --release -p mnms-agent-supervisor -p mnms-agent-runtime -p mnms-hostd
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
} finally {
    Pop-Location
}

Write-Host "Testing SSH connection to $IpAddress..."
& ssh @sshArgs "$SshUser@$IpAddress" "echo SSH connection successful"
if ($LASTEXITCODE -ne 0) { throw "SSH connection failed" }

Write-Host "Copying binaries and install script to $IpAddress..."
$releaseDir = Join-Path $AgentDir "target\release"
$files = @(
    (Join-Path $releaseDir "mnms-hostd"),
    (Join-Path $releaseDir "mnms-vaultd"),
    (Join-Path $releaseDir "mnms-agent-supervisor"),
    (Join-Path $releaseDir "mnms-agent-runtime"),
    (Join-Path $ScriptsDir "install-agent.sh")
)
& scp @sshArgs $files "${SshUser}@${IpAddress}:/tmp/"
if ($LASTEXITCODE -ne 0) { throw "scp failed" }

Write-Host "Installing on $IpAddress..."
$remoteScript = @'
set -euo pipefail
sudo mkdir -p /usr/local/bin
sudo install -m 755 /tmp/mnms-hostd /tmp/mnms-vaultd /tmp/mnms-agent-supervisor /tmp/mnms-agent-runtime /usr/local/bin/
chmod +x /tmp/install-agent.sh
sudo bash /tmp/install-agent.sh
rm -f /tmp/mnms-hostd /tmp/mnms-vaultd /tmp/mnms-agent-supervisor /tmp/mnms-agent-runtime /tmp/install-agent.sh
'@
& ssh @sshArgs "$SshUser@$IpAddress" $remoteScript
if ($LASTEXITCODE -ne 0) { throw "remote install failed" }

Write-Host "Agent host stack installed on $IpAddress."
Write-Host "Note: install-agent.sh's mnms-agent-supervisor.service expects a Podman OCI image"
Write-Host "(MNMS_RUNTIME_IMAGE) by default. For a bare VM without a registry yet, set"
Write-Host "MNMS_RUNTIME_DEV_BINARY=/usr/local/bin/mnms-agent-runtime in an override instead;"
Write-Host "see mnms-agent/README.md."
