#!/bin/bash
# ===============================================================================
# Proxmox DHCP Configuration Script
# ===============================================================================
# Description: Automatically configures a Proxmox host to use DHCP instead of
#              static IP addressing and updates /etc/hosts accordingly.
# Author: Your Name
# GitHub: https://github.com/yourusername/proxmox-scripts
# License: MIT
# ===============================================================================

# Get the hostname
HOSTNAME=$(hostname)

# Find primary physical network interface (excluding lo, vmbr, and tap interfaces)
PRIMARY_IFACE=$(ip -o link show | grep -v 'lo\|vmbr\|tap' | grep 'state UP' | awk -F': ' '{print $2}' | head -n1)

if [ -z "$PRIMARY_IFACE" ]; then
    # If no UP interface, take the first non-lo interface
    PRIMARY_IFACE=$(ip -o link show | grep -v 'lo\|vmbr\|tap' | awk -F': ' '{print $2}' | head -n1)
fi

if [ -z "$PRIMARY_IFACE" ]; then
    echo "Error: Could not detect primary network interface"
    exit 1
fi

echo "Detected primary interface: $PRIMARY_IFACE"

# Check if /etc/network/interfaces already has DHCP configured
if grep -q "iface vmbr0 inet dhcp" /etc/network/interfaces; then
    echo "DHCP is already configured for vmbr0"
else
    echo "Configuring DHCP for vmbr0 using physical interface $PRIMARY_IFACE"
    
    # Create a backup of the current interfaces file
    cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d%H%M%S)
    
    # Create a new interfaces file with DHCP configuration
    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto $PRIMARY_IFACE
iface $PRIMARY_IFACE inet manual

auto vmbr0
iface vmbr0 inet dhcp
        bridge-ports $PRIMARY_IFACE
        bridge-stp off
        bridge-fd 0

source /etc/network/interfaces.d/*
EOF

    echo "Updated /etc/network/interfaces with DHCP configuration"
fi

# Update /etc/hosts with the current IP
CURRENT_IP=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

if [ -z "$CURRENT_IP" ]; then
    # If vmbr0 doesn't have an IP yet, try to get it from the primary interface
    CURRENT_IP=$(ip -4 addr show $PRIMARY_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
fi

if [ -n "$CURRENT_IP" ]; then
    # Check if hostname entry exists in /etc/hosts
    if grep -q "^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+ $HOSTNAME" /etc/hosts; then
        # Update existing entry
        sed -i "s/^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+ $HOSTNAME/$CURRENT_IP $HOSTNAME/" /etc/hosts
    else
        # Add new entry
        echo "$CURRENT_IP $HOSTNAME" >> /etc/hosts
    fi
    echo "Updated /etc/hosts with $HOSTNAME -> $CURRENT_IP"
else
    echo "Warning: Could not detect an IP address to use in /etc/hosts"
fi

echo "DHCP configuration complete."
echo "You may need to restart networking or reboot for changes to take effect."
echo "After restart, run the following command to verify DHCP is working:"
echo "  ip addr show vmbr0"
