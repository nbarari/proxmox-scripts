#!/bin/bash
# ===============================================================================
# Proxmox DHCP Configuration Script (Enhanced)
# ===============================================================================
# Description: Automatically configures a Proxmox host to use DHCP instead of
#              static IP addressing and updates /etc/hosts accordingly.
#              Dynamically detects network interfaces and allows user selection.
# Author: nbarari (original script)
# GitHub: https://github.com/nbarari/proxmox-scripts
# ===============================================================================

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

progress() {
    local message="$1"
    local total="$2"
    local current="$3"
    local percent=$((current * 100 / total))
    local completed=$((current * 20 / total))
    local remaining=$((20 - completed))
    
    printf "${BLUE}[PROGRESS]${NC} %s [%-20s] %d%%\r" "$message" "$(printf '#%.0s' $(seq 1 $completed))$(printf ' %.0s' $(seq 1 $remaining))" "$percent"
    if [ "$current" -eq "$total" ]; then
        echo
    fi
}

# Function to select bond mode
select_bond_mode() {
    info "Select bonding mode:"
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
            *) error "Invalid choice. Please select 1-4." ;;
        esac
    done
}

# Validate hostname format
validate_hostname() {
    local hostname="$1"
    
    # Check hostname length (2-63 characters)
    if [ ${#hostname} -lt 2 ] || [ ${#hostname} -gt 63 ]; then
        error "Hostname must be between 2 and 63 characters long."
        return 1
    fi
    
    # Check hostname format (RFC 1123)
    if ! echo "$hostname" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$'; then
        error "Invalid hostname format. Hostname must:"
        error "- Start and end with alphanumeric characters"
        error "- Contain only alphanumeric characters and hyphens"
        error "- Not contain consecutive hyphens"
        return 1
    fi
    
    success "Hostname '$hostname' is valid."
    return 0
}

# Verify if an interface is a physical interface
is_physical_interface() {
    local iface="$1"
    
    # Check if interface exists
    if [ ! -d "/sys/class/net/$iface" ]; then
        error "Interface $iface does not exist."
        return 1
    fi
    
    # Check if interface is virtual
    if [ -d "/sys/devices/virtual/net/$iface" ]; then
        # Some virtual interfaces might be useful (bridges, bonds)
        # But we'll exclude them from being considered "physical"
        return 1
    fi
    
    # Check for device driver to confirm it's physical
    if [ -L "/sys/class/net/$iface/device" ]; then
        return 0
    else
        return 1
    fi
}

# Function to get network link status
get_link_status() {
    local iface="$1"
    local status=$(cat /sys/class/net/$iface/operstate 2>/dev/null)
    echo "$status"
}

# Function to check for common misconfigurations
check_misconfigurations() {
    local has_issues=0
    
    # Check if network-manager is running (might interfere)
    if systemctl is-active --quiet NetworkManager; then
        warning "NetworkManager is active. This might interfere with Proxmox networking."
        warning "Consider disabling NetworkManager: 'systemctl disable --now NetworkManager'"
        has_issues=1
    fi
    
    # Check for conflicting network configurations
    if [ -f /etc/network/interfaces.d/* ]; then
        warning "Files found in /etc/network/interfaces.d/ might override main configuration."
        has_issues=1
    fi
    
    # Check for unusual interface names
    if ls /sys/class/net/ | grep -qE '^eth[0-9]+$|^ens[0-9]+$|^enp[0-9]+s[0-9]+$'; then
        info "Standard interface naming detected."
    else
        warning "Non-standard interface naming detected. Verify interface names carefully."
        has_issues=1
    fi
    
    # Check for existing interface usage in VMs
    for iface in $(echo "$SELECTED_IFACES"); do
        if grep -q "$iface" /etc/pve/qemu-server/*.conf 2>/dev/null; then
            error "Interface $iface appears to be directly used by VMs. This may cause issues."
            has_issues=1
        fi
    done
    
    # Check if any selected interfaces have no link
    for iface in $(echo "$SELECTED_IFACES"); do
        local status=$(get_link_status "$iface")
        if [ "$status" != "up" ]; then
            warning "Interface $iface does not have link (status: $status)."
            has_issues=1
        fi
    done
    
    # Return result
    return $has_issues
}

# Create static fallback configuration
generate_static_fallback() {
    local iface="$1"
    local ip="$2"
    local prefix="$3"
    local gateway="$4"
    
    if [ -z "$ip" ] || [ -z "$prefix" ] || [ -z "$gateway" ]; then
        error "Missing parameters for static fallback configuration."
        return 1
    fi
    
    info "Creating static fallback configuration for $iface:"
    info "  IP: $ip/$prefix"
    info "  Gateway: $gateway"
    
    cat << EOF
    # Static fallback configuration
    post-up /bin/bash -c 'if ! ip -4 addr show dev \$IFACE | grep -q "inet "; then ip addr add $ip/$prefix dev \$IFACE && ip route add default via $gateway dev \$IFACE; fi'
EOF
}

# Warn if running over SSH
if [ -n "$SSH_CONNECTION" ]; then
    warning "You are running this script over SSH."
    warning "Changing network configuration may disconnect your SSH session."
    warning "Proceed with caution. Consider running from console or having out-of-band access."
    echo
fi

# Get the hostname
HOSTNAME=$(hostname)
info "Current hostname: $HOSTNAME"

# Validate hostname
if ! validate_hostname "$HOSTNAME"; then
    error "Please fix your hostname before continuing."
    exit 1
fi

# Detect all network interfaces
ALL_IFACES=$(ls /sys/class/net | grep -v -E '^(lo|bonding_masters)$')

# Filter to get only physical interfaces
PHYSICAL_IFACES=""
for iface in $ALL_IFACES; do
    if is_physical_interface "$iface"; then
        if [ -z "$PHYSICAL_IFACES" ]; then
            PHYSICAL_IFACES="$iface"
        else
            PHYSICAL_IFACES="$PHYSICAL_IFACES $iface"
        fi
        
        # Display interface details
        info "Physical interface detected: $iface"
        local mac=$(cat /sys/class/net/$iface/address 2>/dev/null)
        local status=$(get_link_status "$iface")
        local speed=$(cat /sys/class/net/$iface/speed 2>/dev/null || echo "unknown")
        echo "  - MAC: $mac"
        echo "  - Status: $status"
        if [ "$speed" != "unknown" ]; then
            echo "  - Speed: ${speed}Mbps"
        else
            echo "  - Speed: unknown"
        fi
    fi
done

# Check if we have physical interfaces
if [ -z "$PHYSICAL_IFACES" ]; then
    error "No physical network interfaces detected. Exiting."
    exit 1
fi

# Exclude existing bridge and bond interfaces
AVAILABLE_IFACES=$(echo "$PHYSICAL_IFACES" | tr ' ' '\n' | grep -vE '^(vmbr[0-9]+|bond[0-9]+|tailscale0)$' | tr '\n' ' ')

# Check if AVAILABLE_IFACES is empty
if [ -z "$AVAILABLE_IFACES" ]; then
    error "No available physical network interfaces detected after filtering. Exiting."
    exit 1
fi

info "Available interfaces: $AVAILABLE_IFACES"

if [ $(echo "$AVAILABLE_IFACES" | wc -w) -gt 1 ]; then
    info "Multiple interfaces detected. Would you like to bond these interfaces for redundancy/performance? (y/n)"
    read -r use_bond
    if [[ $use_bond =~ ^[Yy]$ ]]; then
        SELECTED_IFACES=$(echo "$AVAILABLE_IFACES" | xargs)
        BONDING_ENABLED=true
        BOND_MODE=$(select_bond_mode)
        success "Using bond mode: $BOND_MODE"
    else
        info "Do you want to configure all interfaces for DHCP? (y/n)"
        read -r configure_all
        if [[ $configure_all =~ ^[Yy]$ ]]; then
            SELECTED_IFACES=$(echo "$AVAILABLE_IFACES" | xargs)
        else
            info "Please select an interface to configure for DHCP:"
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

# Ensure the selection logic always sets SELECTED_IFACES
if [ -z "$SELECTED_IFACES" ]; then
    warning "No interface selected. Defaulting to all available interfaces: $AVAILABLE_IFACES"
    SELECTED_IFACES=$(echo "$AVAILABLE_IFACES" | xargs)
fi

success "Selected interfaces for DHCP configuration: $SELECTED_IFACES"

# Check for common misconfigurations
info "Checking for common misconfigurations..."
if check_misconfigurations; then
    success "No common issues detected."
else
    warning "Issues detected. Please review the warnings above."
    info "Do you want to continue anyway? (y/n)"
    read -r continue_anyway
    if [[ ! $continue_anyway =~ ^[Yy]$ ]]; then
        info "Exiting script. No changes were made."
        exit 0
    fi
fi

# Configure IPv6
info "Do you want to configure IPv6? (y/n)"
read -r configure_ipv6
if [[ $configure_ipv6 =~ ^[Yy]$ ]]; then
    IPV6_ENABLED=true
    info "Do you want to use DHCPv6 or SLAAC for IPv6? (dhcp/slaac)"
    read -r ipv6_method
    if [[ $ipv6_method =~ ^[Dd][Hh][Cc][Pp]$ ]]; then
        IPV6_METHOD="dhcp"
    else
        IPV6_METHOD="auto"
    fi
else
    IPV6_ENABLED=false
fi

# Configure static fallback
info "Do you want to configure a static fallback IP if DHCP fails? (y/n)"
read -r use_fallback
if [[ $use_fallback =~ ^[Yy]$ ]]; then
    FALLBACK_ENABLED=true
    info "Enter static fallback IP address (e.g., 192.168.1.100):"
    read -r FALLBACK_IP
    info "Enter network prefix length (e.g., 24 for /24):"
    read -r FALLBACK_PREFIX
    info "Enter default gateway:"
    read -r FALLBACK_GATEWAY
else
    FALLBACK_ENABLED=false
fi

# Backup the current interfaces file
BACKUP_FILE="/etc/network/interfaces.backup.$(date +%Y%m%d%H%M%S)"
cp /etc/network/interfaces "$BACKUP_FILE"
success "Backed up current network configuration to $BACKUP_FILE"

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
EOF

    # Add static fallback if enabled
    if [ "$FALLBACK_ENABLED" = true ]; then
        FALLBACK_CONFIG=$(generate_static_fallback "vmbr0" "$FALLBACK_IP" "$FALLBACK_PREFIX" "$FALLBACK_GATEWAY")
        echo "$FALLBACK_CONFIG" >> /etc/network/interfaces
    fi

    # Add IPv6 configuration if enabled
    if [ "$IPV6_ENABLED" = true ]; then
        cat >> /etc/network/interfaces << EOF

iface vmbr0 inet6 $IPV6_METHOD
EOF
    fi
else
    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports $SELECTED_IFACES
    bridge-stp off
    bridge-fd 0
EOF

    # Add static fallback if enabled
    if [ "$FALLBACK_ENABLED" = true ]; then
        FALLBACK_CONFIG=$(generate_static_fallback "vmbr0" "$FALLBACK_IP" "$FALLBACK_PREFIX" "$FALLBACK_GATEWAY")
        echo "$FALLBACK_CONFIG" >> /etc/network/interfaces
    fi

    # Add IPv6 configuration if enabled
    if [ "$IPV6_ENABLED" = true ]; then
        cat >> /etc/network/interfaces << EOF

iface vmbr0 inet6 $IPV6_METHOD
EOF
    fi
fi

# Add source line for interfaces.d
echo "" >> /etc/network/interfaces
echo "source /etc/network/interfaces.d/*" >> /etc/network/interfaces

success "Updated /etc/network/interfaces with DHCP configuration for: $SELECTED_IFACES"

# Wait for DHCP lease on vmbr0 with progress indicator
info "Applying network configuration..."
systemctl restart networking
if [ $? -ne 0 ]; then
    error "Failed to restart networking. Rolling back to previous configuration."
    cp "$BACKUP_FILE" /etc/network/interfaces
    systemctl restart networking
    exit 1
fi

info "Waiting for DHCP lease on vmbr0..."
TIMEOUT=30
for i in $(seq 1 $TIMEOUT); do
    progress "Waiting for DHCP" $TIMEOUT $i
    CURRENT_IP=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    if [ -n "$CURRENT_IP" ]; then
        success "DHCP lease obtained: $CURRENT_IP"
        break
    fi
    sleep 1
done

if [ -z "$CURRENT_IP" ]; then
    warning "Timeout waiting for DHCP lease on vmbr0."
    
    # Check if fallback was configured and activated
    FALLBACK_ACTIVE=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    if [ -n "$FALLBACK_ACTIVE" ] && [ "$FALLBACK_ENABLED" = true ]; then
        success "Static fallback IP activated: $FALLBACK_ACTIVE"
        CURRENT_IP=$FALLBACK_ACTIVE
    else
        # If vmbr0 doesn't have an IP yet, try to get it from the first selected interface
        FIRST_IFACE=$(echo "$SELECTED_IFACES" | awk '{print $1}')
        CURRENT_IP=$(ip -4 addr show $FIRST_IFACE 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        if [ -n "$CURRENT_IP" ]; then
            info "Found IP on $FIRST_IFACE: $CURRENT_IP"
        else
            error "Could not obtain an IP address via DHCP or fallback."
            error "Consider rolling back to the previous configuration: cp $BACKUP_FILE /etc/network/interfaces"
        fi
    fi
fi

# Check for IPv6 address if enabled
if [ "$IPV6_ENABLED" = true ]; then
    IPV6_ADDR=$(ip -6 addr show vmbr0 2>/dev/null | grep -v fe80 | grep -oP '(?<=inet6\s)[0-9a-f:]+')
    if [ -n "$IPV6_ADDR" ]; then
        success "IPv6 address obtained: $IPV6_ADDR"
    else
        warning "No global IPv6 address obtained on vmbr0."
    fi
fi

if [ -n "$CURRENT_IP" ]; then
    # Remove any old entries for this hostname (with or without FQDN)
    sed -i "/[[:space:]]$HOSTNAME(\.[^ ]*)*[[:space:]]*$/d" /etc/hosts
    # Add new entry
    FQDN=$(hostname -f 2>/dev/null || hostname)
    echo "$CURRENT_IP $FQDN $HOSTNAME" >> /etc/hosts
    success "Updated /etc/hosts with $FQDN $HOSTNAME -> $CURRENT_IP"
else
    error "Could not update /etc/hosts due to missing IP address."
fi

# Connectivity test
info "Testing connectivity..."
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    success "Internet connectivity confirmed."
else
    warning "Could not reach the internet. Check your network configuration."
fi

# DNS resolution test
if host -W 2 google.com >/dev/null 2>&1; then
    success "DNS resolution working."
else
    warning "DNS resolution failed. Check your DNS configuration."
fi

echo
success "DHCP configuration complete."
info "Network configuration file: /etc/network/interfaces"
info "Backup file: $BACKUP_FILE"
info "If needed, restore the original configuration with: cp $BACKUP_FILE /etc/network/interfaces"
info "Then restart networking with: systemctl restart networking"
echo
info "To verify your configuration, run:"
echo "  ip addr show vmbr0"
echo "  ip route"
if [ "$IPV6_ENABLED" = true ]; then
    echo "  ip -6 addr show vmbr0"
    echo "  ip -6 route"
fi
