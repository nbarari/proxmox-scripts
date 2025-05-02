#!/bin/bash
# ===============================================================================
# Proxmox DHCP Configuration Script
# ===============================================================================
# Description: Automatically configures a Proxmox host to use DHCP instead of
#              static IP addressing and updates /etc/hosts accordingly.
#              This version specifically uses the eno1 interface.
# Author: nbarari
# GitHub: https://github.com/nbarari/proxmox-scripts
# ===============================================================================

# Get the hostname
HOSTNAME=$(hostname)

# Explicitly set the primary interface to eno1
PRIMARY_IFACE="eno1"

echo "Using Ethernet interface: $PRIMARY_IFACE"

# Verify the interface exists
if ! ip link show $PRIMARY_IFACE >/dev/null 2>&1; then
    echo "Error: Interface $PRIMARY_IFACE does not exist on this system"
    echo "Available interfaces:"
    ip -o link show | grep -v 'lo\|vmbr\|tap' | awk -F': ' '{print $2}'
    exit 1
fi

# Check if /etc/network/interfaces already has DHCP configured
if grep -q "iface vmbr0 inet dhcp" /etc/network/interfaces; then
    echo "DHCP is already configured for vmbr0"
    
    # Check if the correct interface is being used
    if ! grep -q "bridge-ports $PRIMARY_IFACE" /etc/network/interfaces; then
        echo "Warning: vmbr0 is not using $PRIMARY_IFACE as bridge port"
        echo "Current configuration:"
        grep -A 3 "iface vmbr0" /etc/network/interfaces
        
        # Ask for confirmation before modifying
        echo "Do you want to update the bridge port to use $PRIMARY_IFACE? (y/n)"
        read -r confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            # Update the bridge port
            sed -i "/iface vmbr0/,/bridge-fd/{s/bridge-ports.*/bridge-ports $PRIMARY_IFACE/}" /etc/network/interfaces
            echo "Bridge port updated to use $PRIMARY_IFACE"
        fi
    fi
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
