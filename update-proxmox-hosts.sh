#!/bin/bash
# ===============================================================================
# Proxmox Hosts File Updater
# ===============================================================================
# Description: Automatically updates /etc/hosts with the current IP address of
#              the Proxmox host when using DHCP. This helps ensure Proxmox
#              services work correctly when IP addresses change.
# Author: Your Name
# GitHub: https://github.com/yourusername/proxmox-scripts
# License: MIT
# ===============================================================================

HOSTNAME="proxmox-nuc"
INTERFACE="vmbr0"

# Get current IP address
CURRENT_IP=$(ip -4 addr show $INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

if [ -z "$CURRENT_IP" ]; then
    echo "Error: Could not detect IP address for interface $INTERFACE"
    exit 1
fi

# Check if hostname entry exists in /etc/hosts
if grep -q "^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+ $HOSTNAME" /etc/hosts; then
    # Update existing entry
    sed -i "s/^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+ $HOSTNAME/$CURRENT_IP $HOSTNAME/" /etc/hosts
else
    # Add new entry
    echo "$CURRENT_IP $HOSTNAME" >> /etc/hosts
fi

echo "Updated /etc/hosts with $HOSTNAME -> $CURRENT_IP"

# Restart Proxmox services if IP changed
systemctl restart pve-cluster
if [ $? -eq 0 ]; then
    systemctl restart pvedaemon pveproxy pvestatd
fi
