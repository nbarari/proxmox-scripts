#!/bin/bash
# ===============================================================================
# Proxmox DHCP Configuration Script
# ===============================================================================
# Description: Automatically configures a Proxmox host to use DHCP instead of
#              static IP addressing and updates /etc/hosts accordingly.
#              Dynamically detects network interfaces and allows user selection.
# Author: nbarari
# GitHub: https://github.com/nbarari/proxmox-scripts
# ===============================================================================

# Get the hostname
HOSTNAME=$(hostname)

# Detect all network interfaces with IP addresses (including vmbr0)
AVAILABLE_IFACES=$(ip -o -4 addr show | awk '{print $2}' | grep -v 'lo' | sort -u)

if [ -z "$AVAILABLE_IFACES" ]; then
    echo "Error: No active network interfaces detected."
    exit 1
fi

echo "Detected network interfaces with IP addresses:"
echo "$AVAILABLE_IFACES"

# If multiple interfaces are detected, ask the user to choose or use all
if [ $(echo "$AVAILABLE_IFACES" | wc -l) -gt 1 ]; then
    echo "Multiple interfaces detected. Do you want to configure all for DHCP? (y/n)"
    read -r configure_all
    if [[ $configure_all =~ ^[Yy]$ ]]; then
        SELECTED_IFACES="$AVAILABLE_IFACES"
    else
        echo "Please select an interface to configure for DHCP:"
        select iface in $AVAILABLE_IFACES; do
            if [ -n "$iface" ]; then
                SELECTED_IFACES="$iface"
                break
            fi
        done
    fi
else
    SELECTED_IFACES="$AVAILABLE_IFACES"
fi

echo "Selected interfaces for DHCP configuration: $SELECTED_IFACES"

# Backup the current interfaces file
cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d%H%M%S)

# Generate a new interfaces file with DHCP configuration for selected interfaces
cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

EOF

for iface in $SELECTED_IFACES; do
    cat >> /etc/network/interfaces << EOF
auto $iface
iface $iface inet manual

EOF
done

cat >> /etc/network/interfaces << EOF
auto vmbr0
iface vmbr0 inet dhcp
        bridge-ports $SELECTED_IFACES
        bridge-stp off
        bridge-fd 0

source /etc/network/interfaces.d/*
EOF

echo "Updated /etc/network/interfaces with DHCP configuration for: $SELECTED_IFACES"

# Update /etc/hosts with the current IP
CURRENT_IP=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

if [ -z "$CURRENT_IP" ]; then
    # If vmbr0 doesn't have an IP yet, try to get it from the first selected interface
    CURRENT_IP=$(ip -4 addr show $(echo "$SELECTED_IFACES" | awk '{print $1}') | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
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
