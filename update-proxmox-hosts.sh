#!/bin/bash
# ===============================================================================
# Proxmox Hosts File Updater
# ===============================================================================
# Description: Automatically updates /etc/hosts with the current IP address of
#              the Proxmox host when using DHCP. This helps ensure Proxmox
#              services work correctly when IP addresses change.
# Author: nbarari
# GitHub: https://github.com/nbarari/proxmox-scripts
# ===============================================================================

HOSTNAME=$(hostname)
FQDN=$(hostname -f 2>/dev/null || hostname)
INTERFACE="vmbr0"

# Get current IP address
CURRENT_IP=$(ip -4 addr show $INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

if [ -z "$CURRENT_IP" ]; then
    echo "Error: Could not detect IP address for interface $INTERFACE"
    exit 1
fi

# Remove any old entries for this hostname (short and FQDN)
sed -i "/[[:space:]]$HOSTNAME[[:space:]]*$/d" /etc/hosts
sed -i "/[[:space:]]$FQDN[[:space:]]*$/d" /etc/hosts

# Add new entry with both FQDN and short hostname
echo "$CURRENT_IP $FQDN $HOSTNAME" >> /etc/hosts

echo "Updated /etc/hosts with $FQDN $HOSTNAME -> $CURRENT_IP"

# Restart Proxmox services if IP changed
systemctl restart pve-cluster
if [ $? -eq 0 ]; then
    systemctl restart pvedaemon pveproxy pvestatd
fi
