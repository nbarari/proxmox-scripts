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

# Function to select bond mode
select_bond_mode() {
    echo "Select bonding mode:"
    echo "1) active-backup (mode 1) - Fault tolerance, one active interface"
    echo "2) 802.3ad (mode 4) - LACP, requires switch configuration"
    echo "3) balance-alb (mode 6) - Adaptive load balancing"
    echo "4) balance-xor (mode 2) - Static load balancing"
    
    while true; do
        read -p "Enter choice [1-4]: " bond_choice
        case $bond_choice in
            1) echo "active-backup"; return ;;
            2) echo "802.3ad"; return ;;
            3) echo "balance-alb"; return ;;
            4) echo "balance-xor"; return ;;
            *) echo "Invalid choice. Please select 1-4." ;;
        esac
    done
}

# Warn if running over SSH
if [ -n "$SSH_CONNECTION" ]; then
    echo "WARNING: You are running this script over SSH."
    echo "Changing network configuration may disconnect your SSH session."
    echo "Proceed with caution. Consider running from console or having out-of-band access."
    echo
fi

# Get the hostname
HOSTNAME=$(hostname)

# Detect all physical network interfaces (exclude lo and vmbr*)
AVAILABLE_IFACES=$(ls /sys/class/net | grep -vE '^(lo|vmbr[0-9]+|tailscale0|bonding_masters)$')

# 1. Check if AVAILABLE_IFACES is empty
if [ -z "$AVAILABLE_IFACES" ]; then
    echo "ERROR: No physical network interfaces detected. Exiting."
    exit 1
fi

# 2. Print AVAILABLE_IFACES for debugging
echo "DEBUG: AVAILABLE_IFACES='$AVAILABLE_IFACES'"

if [ $(echo "$AVAILABLE_IFACES" | wc -l) -gt 1 ]; then
    echo "Multiple interfaces detected:"
    echo "$AVAILABLE_IFACES"
    echo "Would you like to bond these interfaces for redundancy/performance? (y/n)"
    read -r use_bond
    if [[ $use_bond =~ ^[Yy]$ ]]; then
        SELECTED_IFACES=$(echo "$AVAILABLE_IFACES" | xargs)
        BONDING_ENABLED=true
        BOND_MODE=$(select_bond_mode)
        echo "Using bond mode: $BOND_MODE"
    else
        echo "Do you want to configure all interfaces for DHCP? (y/n)"
        read -r configure_all
        if [[ $configure_all =~ ^[Yy]$ ]]; then
            SELECTED_IFACES=$(echo "$AVAILABLE_IFACES" | xargs)
        else
            echo "Please select an interface to configure for DHCP:"
            select iface in $AVAILABLE_IFACES; do
                if [ -n "$iface" ]; then
                    SELECTED_IFACES="$iface"
                    break
                fi
            done
        fi
        BONDING_ENABLED=false
    fi
else
    SELECTED_IFACES=$(echo "$AVAILABLE_IFACES" | xargs)
    BONDING_ENABLED=false
fi

# 3. Ensure the selection logic always sets SELECTED_IFACES
if [ -z "$SELECTED_IFACES" ]; then
    echo "No interface selected. Defaulting to all available interfaces: $AVAILABLE_IFACES"
    SELECTED_IFACES=$(echo "$AVAILABLE_IFACES" | xargs)
fi

echo "Selected interfaces for DHCP configuration: $SELECTED_IFACES"

# Backup the current interfaces file
cp /etc/network/interfaces /etc/network/interfaces.backup.$(date +%Y%m%d%H%M%S)

# Generate a new interfaces file with DHCP configuration
if [ "$BONDING_ENABLED" = true ]; then
cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto bond0
iface bond0 inet manual
    bond-slaves $SELECTED_IFACES
    bond-miimon 100
    bond-mode $BOND_MODE

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports bond0
    bridge-stp off
    bridge-fd 0

source /etc/network/interfaces.d/*
EOF
else
cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports $SELECTED_IFACES
    bridge-stp off
    bridge-fd 0

source /etc/network/interfaces.d/*
EOF
fi

echo "Updated /etc/network/interfaces with DHCP configuration for: $SELECTED_IFACES"

# Wait for DHCP lease on vmbr0 (up to 30 seconds)
echo "Waiting for DHCP lease on vmbr0..."
for i in {1..30}; do
    CURRENT_IP=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    if [ -n "$CURRENT_IP" ]; then
        echo "DHCP lease obtained: $CURRENT_IP"
        break
    fi
    sleep 1
done

if [ -z "$CURRENT_IP" ]; then
    echo "Timeout waiting for DHCP lease on vmbr0."
    # If vmbr0 doesn't have an IP yet, try to get it from the first selected interface
    CURRENT_IP=$(ip -4 addr show $(echo "$SELECTED_IFACES" | awk '{print $1}') | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
fi

if [ -n "$CURRENT_IP" ]; then
    # Remove any old entries for this hostname (with or without FQDN)
    sed -i "/[[:space:]]$HOSTNAME(\.[^ ]*)*[[:space:]]*$/d" /etc/hosts
    # Add new entry
    FQDN=$(hostname -f 2>/dev/null || hostname)
    echo "$CURRENT_IP $FQDN $HOSTNAME" >> /etc/hosts
    echo "Updated /etc/hosts with $FQDN $HOSTNAME -> $CURRENT_IP"
else
    echo "Warning: Could not detect an IP address to use in /etc/hosts"
fi

echo
echo "DHCP configuration complete."
echo "You may need to restart networking or reboot for changes to take effect."
echo "After restart, run the following command to verify DHCP is working:"
echo "  ip addr show vmbr0"
