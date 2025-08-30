
# Onboarding Scripts

This repository contains scripts to automate the installation of Node.js and the `mnmagent` package on remote Linux machines. These scripts are designed to simplify onboarding and agent deployment for new or freshly provisioned VMs.

## Scripts

### 1. `installmnmagent.sh`
A Bash script to remotely install Node.js and `mnmagent` on a Linux VM using SSH and password authentication.

#### Features
- Installs `sshpass` automatically if not present (supports Debian/Ubuntu, RedHat/CentOS, Alpine Linux).
- Connects to the remote host using SSH with the provided root password.
- Installs Node.js (LTS) and `mnmagent` globally via npm on the remote machine.

#### Usage
```sh
./installmnmagent.sh <IP_ADDRESS> <ROOT_PASSWORD>
```
- `<IP_ADDRESS>`: The IP address of the remote Linux VM.
- `<ROOT_PASSWORD>`: The root password for the remote VM.

#### Requirements
- Run this script from a Linux machine with Bash.
- The remote VM must be accessible via SSH as root.
- The script will attempt to install `sshpass` if it is not already installed.

### 2. `Install-MnmAgent.ps1`
A PowerShell script to perform the same installation from a Windows environment.

#### Features
- Uses the `Posh-SSH` PowerShell module to connect to the remote Linux host.
- Installs Node.js (LTS) and `mnmagent` globally via npm on the remote machine.

#### Usage
```powershell
./Install-MnmAgent.ps1 -IpAddress <IP_ADDRESS> -RootPassword <ROOT_PASSWORD>
```
- `<IP_ADDRESS>`: The IP address of the remote Linux VM.
- `<ROOT_PASSWORD>`: The root password for the remote VM.

#### Requirements
- Windows PowerShell 5.1 or later.
- Internet access to install the `Posh-SSH` module if not already present.

## Security Note
- These scripts require the root password for the remote machine. Use with caution and only on trusted networks.
- Consider using SSH keys for improved security in production environments.

## License
See [LICENSE](LICENSE) for details.
