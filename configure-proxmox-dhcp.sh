#!/bin/bash
# ===============================================================================
# Proxmox DHCP Configuration Script
# ===============================================================================
# Description: Automatically configures a Proxmox host to use DHCP instead of
#              static IP addressing and updates /etc/hosts accordingly.
#              Dynamically detects network interfaces and allows user selection.
# Original Author: nbarari
# GitHub: https://github.com/nbarari/proxmox-scripts
# ===============================================================================

# Exit on error
set -e

# Add dry-run mode
DRY_RUN=false
if [[ "$1" == "--dry-run" || "$1" == "-d" ]]; then
    DRY_RUN=true
fi

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
    echo -e "${RED}[ERROR]${NC} $1" >&2
    if [ "$DRY_RUN" != "true" ]; then
        return 1
    fi
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

# Execute commands or simulate execution in dry-run mode
execute() {
    if [ "$DRY_RUN" = "true" ]; then
        info "DRY RUN: Would execute: $*"
        return 0
    else
        "$@" || { error "Command failed: $*"; return 1; }
    fi
}

# Function to verify if an interface is a physical interface
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
    
    # Enhanced interface validation - only accept common interface naming patterns
    if ! echo "$iface" | grep -qE '^(en|eth|ens|enp|wl)[a-zA-Z0-9]*'; then
        # Not a standard interface name
        return 1
    fi
    
    # Check for device driver to confirm it's physical
    if [ -L "/sys/class/net/$iface/device" ]; then
        return 0
    else
        return 1
    fi
}

# Function to detect suitable interfaces
detect_suitable_interfaces() {
    local interfaces=""
    for iface in $(ls /sys/class/net | grep -v -E '^(lo|bonding_masters)$'); do
        if is_physical_interface "$iface"; then
            interfaces="$interfaces $iface"
        fi
    done
    echo "$interfaces" | xargs
}

# Function to get network link status
get_link_status() {
    local iface="$1"
    local status=$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo "unknown")
    echo "$status"
}

# Function to get the default interface
get_default_interface() {
    ip route | grep "^default" | head -n 1 | awk '{print $5}'
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

# Validate IP address format
validate_ip() {
    local ip=$1
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if [[ ! $ip =~ $regex ]]; then
        return 1
    fi
    
    # Check each octet is less than or equal to 255
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [ "$octet" -gt 255 ]; then
            return 1
        fi
    done
    
    return 0
}

# Validate network prefix (CIDR notation)
validate_prefix() {
    local prefix=$1
    
    if ! [[ "$prefix" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    if [ "$prefix" -lt 1 ] || [ "$prefix" -gt 32 ]; then
        return 1
    fi
    
    return 0
}

# Function to check for common misconfigurations
check_misconfigurations() {
    local has_issues=0
    
    # Check if network-manager is running (might interfere)
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        warning "NetworkManager is active. This might interfere with Proxmox networking."
        warning "Consider disabling NetworkManager: 'systemctl disable --now NetworkManager'"
        has_issues=1
    fi
    
    # Check for conflicting network configurations - fixed shell globbing issue
    if ls /etc/network/interfaces.d/* 1> /dev/null 2>&1; then
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

# Function to configure interfaces
configure_interfaces() {
    local bonding_enabled=$1
    local selected_ifaces=$2
    local bond_mode=$3
    local ipv6_enabled=$4
    local ipv6_method=$5
    local fallback_enabled=$6
    local fallback_ip=$7
    local fallback_prefix=$8
    local fallback_gateway=$9
    
    # Create the interfaces file path based on dry run mode
    local interfaces_file
    if [ "$DRY_RUN" = "true" ]; then
        interfaces_file="/tmp/interfaces.new"
        info "DRY RUN: Configuration would be written to /etc/network/interfaces"
        info "Writing preview to $interfaces_file"
    else
        interfaces_file="/etc/network/interfaces"
    fi
    
    # Create the basic configuration
    if [ "$bonding_enabled" = true ]; then
        cat > "$interfaces_file" << EOF
auto lo
iface lo inet loopback

auto bond0
iface bond0 inet manual
    bond-slaves $selected_ifaces
    bond-miimon 100
    bond-mode $bond_mode

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports bond0
    bridge-stp off
    bridge-fd 0
EOF
    else
        cat > "$interfaces_file" << EOF
auto lo
iface lo inet loopback

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports $selected_ifaces
    bridge-stp off
    bridge-fd 0
EOF
    fi

    # Add static fallback if enabled
    if [ "$fallback_enabled" = true ]; then
        FALLBACK_CONFIG=$(generate_static_fallback "vmbr0" "$fallback_ip" "$fallback_prefix" "$fallback_gateway")
        echo "$FALLBACK_CONFIG" >> "$interfaces_file"
    fi

    # Add IPv6 configuration if enabled
    if [ "$ipv6_enabled" = true ]; then
        cat >> "$interfaces_file" << EOF

iface vmbr0 inet6 $ipv6_method
EOF
    fi
    
    # Add source line for interfaces.d
    echo "" >> "$interfaces_file"
    echo "source /etc/network/interfaces.d/*" >> "$interfaces_file"
    
    if [ "$DRY_RUN" = "true" ]; then
        info "DRY RUN: Preview of network configuration:"
        cat "$interfaces_file"
    else
        success "Updated $interfaces_file with DHCP configuration for: $selected_ifaces"
    fi
    
    return 0
}

# Function to apply network configuration and wait for DHCP
apply_network_configuration() {
    local backup_file=$1
    local timeout=$2
    local fallback_enabled=$3
    local ipv6_enabled=$4
    
    if [ "$DRY_RUN" = "true" ]; then
        info "DRY RUN: Would restart networking service"
        info "DRY RUN: Would wait for DHCP lease for up to $timeout seconds"
        return 0
    fi
    
    info "Applying network configuration..."
    if ! systemctl restart networking; then
        error "Failed to restart networking. Rolling back to previous configuration."
        if ! cp "$backup_file" /etc/network/interfaces; then
            error "Failed to restore backup configuration from $backup_file"
            return 1
        fi
        if ! systemctl restart networking; then
            error "Failed to restart networking with rolled back configuration."
            return 1
        fi
        return 1
    fi

    info "Waiting for DHCP lease on vmbr0..."
    for i in $(seq 1 $timeout); do
        progress "Waiting for DHCP" $timeout $i
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
        if [ -n "$FALLBACK_ACTIVE" ] && [ "$fallback_enabled" = true ]; then
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
                error "Consider rolling back to the previous configuration: cp $backup_file /etc/network/interfaces"
                return 1
            fi
        fi
    fi

    # Check for IPv6 address if enabled
    if [ "$ipv6_enabled" = true ]; then
        IPV6_ADDR=$(ip -6 addr show vmbr0 2>/dev/null | grep -v fe80 | grep -oP '(?<=inet6\s)[0-9a-f:]+')
        if [ -n "$IPV6_ADDR" ]; then
            success "IPv6 address obtained: $IPV6_ADDR"
        else
            warning "No global IPv6 address obtained on vmbr0."
        fi
    fi
    
    return 0
}

# Main script execution starts here

# Display banner
echo -e "\n${GREEN}=============================================================${NC}"
echo -e "${GREEN}        Proxmox DHCP Configuration Script      ${NC}"
echo -e "${GREEN}=============================================================${NC}"
echo

# Warn about dry-run mode if active
if [ "$DRY_RUN" = "true" ]; then
    info "Running in DRY RUN mode. No changes will be made to your system."
    info "Use without --dry-run or -d flag to apply changes."
    echo
fi

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

# Detect all network interfaces using our improved detection method
PHYSICAL_IFACES=$(detect_suitable_interfaces)

# Check if we have physical interfaces
if [ -z "$PHYSICAL_IFACES" ]; then
    error "No suitable physical network interfaces detected. Exiting."
    exit 1
fi

# Attempt to identify default interface
DEFAULT_IFACE=$(get_default_interface)
if [ -n "$DEFAULT_IFACE" ]; then
    info "Detected default interface: $DEFAULT_IFACE"
fi

# Display all detected interfaces with details
info "Available physical interfaces:"
for iface in $PHYSICAL_IFACES; do
    echo -e "  ${BLUE}$iface${NC}"
    mac=$(cat /sys/class/net/$iface/address 2>/dev/null || echo "unknown")
    status=$(get_link_status "$iface")
    speed=$(cat /sys/class/net/$iface/speed 2>/dev/null || echo "unknown")
    echo "  - MAC: $mac"
    echo "  - Status: $status"
    if [ "$speed" != "unknown" ]; then
        echo "  - Speed: ${speed}Mbps"
    else
        echo "  - Speed: unknown"
    fi
    
    # Highlight if this is the default interface
    if [ "$iface" = "$DEFAULT_IFACE" ]; then
        echo "  - CURRENT DEFAULT INTERFACE"
    fi
    echo
done

# Exclude existing bridge and bond interfaces
AVAILABLE_IFACES="$PHYSICAL_IFACES"

# Check if AVAILABLE_IFACES is empty
if [ -z "$AVAILABLE_IFACES" ]; then
    error "No available physical network interfaces detected after filtering. Exiting."
    exit 1
fi

info "Interfaces available for configuration: $AVAILABLE_IFACES"

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
            # Improved interface selection with better error handling
            while true; do
                info "Please select an interface to configure for DHCP:"
                select iface in $AVAILABLE_IFACES "Cancel selection"; do
                    if [ -z "$iface" ]; then
                        error "Invalid selection. Please try again."
                        break
                    elif [ "$iface" = "Cancel selection" ]; then
                        info "Selection cancelled. Exiting script."
                        exit 0
                    else
                        SELECTED_IFACES="$iface"
                        success "Selected interface: $iface"
                        break 2  # Break out of both loops
                    fi
                done
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
    
    # Validate IP address with improved error handling
    while true; do
        info "Enter static fallback IP address (e.g., 192.168.1.100):"
        read -r FALLBACK_IP
        if validate_ip "$FALLBACK_IP"; then
            success "Valid IP address: $FALLBACK_IP"
            break
        else
            error "Invalid IP address format. Please enter a valid IPv4 address (e.g., 192.168.1.100)."
        fi
    done
    
    # Validate network prefix with improved error handling
    while true; do
        info "Enter network prefix length (e.g., 24 for /24):"
        read -r FALLBACK_PREFIX
        if validate_prefix "$FALLBACK_PREFIX"; then
            success "Valid prefix length: $FALLBACK_PREFIX"
            break
        else
            error "Invalid prefix length. Please enter a number between 1 and 32."
        fi
    done
    
    # Validate gateway with improved error handling
    while true; do
        info "Enter default gateway:"
        read -r FALLBACK_GATEWAY
        if validate_ip "$FALLBACK_GATEWAY"; then
            success "Valid gateway address: $FALLBACK_GATEWAY"
            break
        else
            error "Invalid gateway address format. Please enter a valid IPv4 address."
        fi
    done
else
    FALLBACK_ENABLED=false
fi

# Backup the current interfaces file
BACKUP_FILE="/etc/network/interfaces.backup.$(date +%Y%m%d%H%M%S)"
if [ "$DRY_RUN" != "true" ]; then
    if ! cp /etc/network/interfaces "$BACKUP_FILE"; then
        error "Failed to backup current network configuration. Exiting."
        exit 1
    fi
    success "Backed up current network configuration to $BACKUP_FILE"
else
    info "DRY RUN: Would backup current configuration to $BACKUP_FILE"
fi

# Use the modularized function to generate interfaces file
configure_interfaces "$BONDING_ENABLED" "$SELECTED_IFACES" "$BOND_MODE" "$IPV6_ENABLED" "$IPV6_METHOD" "$FALLBACK_ENABLED" "$FALLBACK_IP" "$FALLBACK_PREFIX" "$FALLBACK_GATEWAY"

# Use the modularized function to apply network configuration
TIMEOUT=30
if [ "$DRY_RUN" != "true" ]; then
    if ! apply_network_configuration "$BACKUP_FILE" "$TIMEOUT" "$FALLBACK_ENABLED" "$IPV6_ENABLED"; then
        warning "Network configuration application encountered issues."
    fi
fi

if [ -n "$CURRENT_IP" ]; then
    # Remove any old entries for this hostname (with or without FQDN)
    if [ "$DRY_RUN" != "true" ]; then
        sed -i "/[[:space:]]$HOSTNAME(\.[^ ]*)*[[:space:]]*$/d" /etc/hosts || {
            error "Failed to update /etc/hosts - removing old entries"
        }
        # Add new entry
        FQDN=$(hostname -f 2>/dev/null || hostname)
        echo "$CURRENT_IP $FQDN $HOSTNAME" >> /etc/hosts || {
            error "Failed to update /etc/hosts - adding new entry"
        }
        success "Updated /etc/hosts with $FQDN $HOSTNAME -> $CURRENT_IP"
    else
        info "DRY RUN: Would update /etc/hosts with host entries"
    fi
elif [ "$DRY_RUN" != "true" ]; then
    error "Could not update /etc/hosts due to missing IP address."
fi

# Connectivity test
if [ "$DRY_RUN" != "true" ]; then
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
else
    info "DRY RUN: Would test connectivity and DNS resolution"
fi

echo
if [ "$DRY_RUN" = "true" ]; then
    success "DRY RUN completed. No changes were made."
    info "Run the script without --dry-run to apply changes."
else
    success "DHCP configuration complete."
fi

info "Network configuration file: /etc/network/interfaces"
if [ "$DRY_RUN" != "true" ]; then
    info "Backup file: $BACKUP_FILE"
    info "If needed, restore the original configuration with: cp $BACKUP_FILE /etc/network/interfaces"
    info "Then restart networking with: systemctl restart networking"
fi

echo
info "To verify your configuration, run:"
echo "  ip addr show vmbr0"
echo "  ip route"
if [ "$IPV6_ENABLED" = true ]; then
    echo "  ip -6 addr show vmbr0"
    echo "  ip -6 route"
fi
