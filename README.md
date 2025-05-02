# Proxmox DHCP Configuration Scripts
A collection of scripts to configure and maintain Proxmox VE hosts with DHCP instead of static IP addressing.

## Overview
These scripts solve two common issues when using DHCP with Proxmox:
1. **Initial Configuration**: Automatically configure Proxmox to use DHCP networking with the correct bridge setup
2. **IP Address Changes**: Keep the Proxmox web interface and services working correctly when DHCP assigns a new IP address

## Scripts
### configure-proxmox-dhcp.sh
This script performs initial configuration of a Proxmox host to use DHCP:
- Automatically detects your primary network interface
- Creates a proper bridge (vmbr0) configuration using DHCP
- Updates /etc/hosts with the correct IP address
- Preserves your existing configuration by creating backups

### update-proxmox-hosts.sh
This script maintains proper hostname resolution when your IP address changes:
- Monitors your current IP address on the bridge interface
- Updates /etc/hosts whenever the IP changes
- Restarts necessary Proxmox services
- Prevents duplicate entries in your hosts file

## Installation
### Method 1: Manual Download
```bash
# Download the configuration script
wget -O /usr/local/bin/configure-proxmox-dhcp.sh https://raw.githubusercontent.com/nbarari/proxmox-scripts/main/configure-proxmox-dhcp.sh
chmod +x /usr/local/bin/configure-proxmox-dhcp.sh

# Download the hosts updater script
wget -O /usr/local/bin/update-proxmox-hosts.sh https://raw.githubusercontent.com/nbarari/proxmox-scripts/main/update-proxmox-hosts.sh
chmod +x /usr/local/bin/update-proxmox-hosts.sh

# Download systemd service files
wget -O /etc/systemd/system/update-proxmox-hosts.service https://raw.githubusercontent.com/nbarari/proxmox-scripts/main/systemd/update-proxmox-hosts.service
wget -O /etc/systemd/system/update-proxmox-hosts.path https://raw.githubusercontent.com/nbarari/proxmox-scripts/main/systemd/update-proxmox-hosts.path
```

### Method 2: Clone the Repository
```bash
# Clone the repository
git clone https://github.com/nbarari/proxmox-scripts.git
cd proxmox-scripts

# Copy files to the appropriate locations
cp configure-proxmox-dhcp.sh /usr/local/bin/
cp update-proxmox-hosts.sh /usr/local/bin/
cp systemd/update-proxmox-hosts.service /etc/systemd/system/
cp systemd/update-proxmox-hosts.path /etc/systemd/system/

# Make scripts executable
chmod +x /usr/local/bin/configure-proxmox-dhcp.sh
chmod +x /usr/local/bin/update-proxmox-hosts.sh
```

## Usage
### First-Time DHCP Configuration
1. Run the configuration script:
   ```bash
   /usr/local/bin/configure-proxmox-dhcp.sh
   ```

2. Restart networking or reboot:
   ```bash
   systemctl restart networking
   # or
   reboot
   ```

3. Verify DHCP is working:
   ```bash
   ip addr show vmbr0
   ```

### Setting Up Automatic Hosts File Updates
1. Enable and start the systemd services:
   ```bash
   systemctl enable update-proxmox-hosts.path
   systemctl start update-proxmox-hosts.path
   systemctl enable update-proxmox-hosts.service
   systemctl start update-proxmox-hosts.service
   ```

2. Optional: Add a cron job for additional reliability:
   ```bash
   (crontab -l 2>/dev/null; echo "@reboot /usr/local/bin/update-proxmox-hosts.sh") | crontab -
   (crontab -l 2>/dev/null; echo "*/15 * * * * /usr/local/bin/update-proxmox-hosts.sh") | crontab -
   ```

## Troubleshooting
If you encounter any issues:

1. Check if the hostname can be resolved:
   ```bash
   ping $(hostname)
   ```

2. Verify the content of your hosts file:
   ```bash
   cat /etc/hosts
   ```

3. Check the status of Proxmox services:
   ```bash
   systemctl status pve-cluster pvedaemon pveproxy pvestatd
   ```

## License
MIT License

## Author
nbarari
