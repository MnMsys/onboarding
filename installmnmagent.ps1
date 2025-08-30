# Usage: .\Install-MnmAgent.ps1 -IpAddress <IP_ADDRESS> -RootPassword <ROOT_PASSWORD>

param(
    [Parameter(Mandatory=$true)]
    [string]$IpAddress,
    [Parameter(Mandatory=$true)]
    [string]$RootPassword
)

# Install Posh-SSH if not present
if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    Write-Host "Installing Posh-SSH module..."
    Install-Module -Name Posh-SSH -Force -Scope CurrentUser
}

Import-Module Posh-SSH

# Create SSH session
$sshSession = New-SSHSession -ComputerName $IpAddress -Credential (New-Object System.Management.Automation.PSCredential("root", (ConvertTo-SecureString $RootPassword -AsPlainText -Force))) -AcceptKey

# Commands to run on remote Linux machine
$commands = @(
    "apt-get update",
    "apt-get install -y curl",
    "curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -",
    "apt-get install -y nodejs",
    "npm install -g @mnmsys/mnmagent"
)

foreach ($cmd in $commands) {
    $output = Invoke-SSHCommand -SessionId $sshSession.SessionId -Command $cmd
    Write-Host $output.Output
}

# Close SSH session
Remove-SSHSession -SessionId $sshSession.SessionId

Write-Host "Node.js and mnmagent installed on $IpAddress"