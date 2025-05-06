#!/bin/bash
# ===============================================================================
# Proxmox DHCP Configuration Script
# ===============================================================================
# Description: Automatically configures a Proxmox host to use DHCP instead of
#              static IP addressing, supporting bonding, IPv6, and static fallback.
#              Dynamically detects network interfaces and allows user selection.
# Original Author: nbarari
# GitHub: https://github.com/nbarari/proxmox-scripts
# ===============================================================================

# Exit on error
# set -e

# Add dry-run mode
DRY_RUN=false
if [[ "$1" == "--dry-run" || "$1" == "-d" ]]; then
    DRY_RUN=true
    echo -e "\n*** DRY RUN MODE ENABLED ***\n"
fi

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions ---

# Function to print colored messages
info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; } # Don't exit immediately from error func

progress() {
    local message="$1"
    local total="$2"
    local current="$3"
    local percent=$((current * 100 / total))
    local completed=$((current * 20 / total))
    local remaining=$((20 - completed))
    printf "${BLUE}[PROGRESS]${NC} %s [%-20s] %d%%\r" "$message" "$(printf '#%.0s' $(seq 1 $completed))$(printf ' %.0s' $(seq 1 $remaining))" "$percent"
    if [ "$current" -eq "$total" ]; then echo; fi
}

# Execute commands or simulate execution in dry-run mode
execute() {
    if [ "$DRY_RUN" = "true" ]; then
        info "DRY RUN: Would execute: $*"
        return 0
    else
        # Only log in debug mode or be quiet for production runs
        # info "Executing: $*"  # Comment this out to reduce output noise
        "$@"
        local status=$?
        if [ $status -ne 0 ]; then
            error "Command failed with status $status: $*"
            return $status
        fi
        return 0
    fi
}

# --- Network Interface Functions ---

# Function to verify if an interface is a suitable physical interface
is_physical_interface() {
    local iface="$1"
    # Check if interface exists
    if [ ! -d "/sys/class/net/$iface" ]; then return 1; fi
    # Check if it's loopback
    if [ "$iface" == "lo" ]; then return 1; fi
    # Check if it's a known virtual type (bond, bridge, veth, tap)
    if [[ "$iface" =~ ^(bond|vmbr|veth|tap) ]]; then return 1; fi
    # Check if it's a VLAN interface (e.g., eth0.100)
    if echo "$iface" | grep -qE '\.[0-9]+$'; then return 1; fi
    # Check standard naming patterns (more inclusive)
    if ! echo "$iface" | grep -qE '^(eth|en[ospx]|wl)[a-zA-Z0-9]+'; then return 1; fi
    # Final check: presence of a 'device' symlink is a strong indicator of physical hardware
    if [ -L "/sys/class/net/$iface/device" ]; then return 0; fi
    return 1
}

# Function to detect suitable interfaces
detect_suitable_interfaces() {
    local interfaces=""
    # List all interfaces, exclude loopback and known master types
    for iface in $(ls /sys/class/net | grep -v -E '^(lo|bonding_masters)$'); do
        if is_physical_interface "$iface"; then
            interfaces="$interfaces $iface"
        fi
    done
    echo "$interfaces" | xargs # Trim leading/trailing whitespace
}

# Function to get network link status
get_link_status() {
    local iface="$1"
    cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown"
}

# Function to get the default interface (best effort)
get_default_interface() {
    ip route | grep "^default" | head -n 1 | awk '{print $5}'
}

# --- User Interaction & Validation Functions ---

# Function to select bond mode
select_bond_mode() {
    # Send informational output to stderr (>&2)
    echo >&2
    info "Select bonding mode:" >&2
    echo " 1) active-backup (mode 1) - Fault tolerance (Recommended default)" >&2
    echo " 2) 802.3ad (mode 4)      - LACP (Requires switch configuration)" >&2
    echo " 3) balance-alb (mode 6)   - Adaptive load balancing (No switch config needed)" >&2
    echo " 4) balance-tlb (mode 5)   - Adaptive transmit load balancing" >&2
    echo " 5) balance-xor (mode 2)   - Static load balancing (Needs switch config sometimes)" >&2
    echo >&2

    local choice
    while true; do
        # read prompt goes to stderr automatically
        read -p "Enter choice [1-5, default 1]: " choice
        choice=${choice:-1} # Default to 1 if empty
        case $choice in
            # ONLY echo the final result to stdout
            1) echo "active-backup"; return 0 ;;
            2) echo "802.3ad"; return 0 ;;
            3) echo "balance-alb"; return 0 ;;
            4) echo "balance-tlb"; return 0 ;;
            5) echo "balance-xor"; return 0 ;;
            # Send errors to stderr
            *) error "Invalid choice. Please select 1-5." >&2 ;;
        esac
    done
}

# Function to select interfaces for bonding
select_bond_interfaces() {
    local available_ifaces=($@) # Pass available interfaces as arguments
    local num_ifaces=${#available_ifaces[@]}
    local selected_indices=()
    local bond_slaves=()

    if [ "$num_ifaces" -lt 2 ]; then
        # Send errors to stderr
        error "At least two suitable interfaces are required for bonding." >&2
        return 1
    fi

    # Send informational prompts/lists to stderr
    echo >&2 # Print newline to stderr
    info "Select interfaces to include in the bond:" >&2
    for i in "${!available_ifaces[@]}"; do
        printf " %d) %s\n" "$((i+1))" "${available_ifaces[$i]}" >&2
    done
    echo >&2 # Print newline to stderr

    while true; do
        # The read prompt goes to stderr automatically
        read -p "Enter numbers (space-separated) of interfaces to bond [e.g., 1 2]: " -a selected_indices
        bond_slaves=() # Reset slaves for validation
        local valid_selection=true
        if [ ${#selected_indices[@]} -eq 0 ]; then
            error "No interfaces selected." >&2 # Send errors to stderr
            valid_selection=false
        elif [ ${#selected_indices[@]} -lt 2 ]; then
            error "Please select at least two interfaces for bonding." >&2 # Send errors to stderr
            valid_selection=false
        else
            for index in "${selected_indices[@]}"; do
                if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -lt 1 ] || [ "$index" -gt "$num_ifaces" ]; then
                    error "Invalid selection: '$index'. Please use numbers from the list." >&2 # Send errors to stderr
                    valid_selection=false
                    break
                fi
                 # Check for duplicate selections (minor logic fix here too)
                 local current_iface="${available_ifaces[$((index-1))]}"
                 local is_duplicate=false
                 for slave in "${bond_slaves[@]}"; do
                     if [[ "$slave" == "$current_iface" ]]; then
                         is_duplicate=true
                         break
                     fi
                 done
                 if $is_duplicate; then
                      error "Duplicate selection: $current_iface." >&2 # Send errors to stderr
                      valid_selection=false
                      break
                 fi
                bond_slaves+=("$current_iface")
            done
        fi

        if [ "$valid_selection" = true ]; then
            # ONLY print the result to stdout for command substitution
            echo "${bond_slaves[@]}"
            return 0
        fi
    done
}

# Validate hostname format
validate_hostname() {
    local hostname="$1"
    if [ ${#hostname} -lt 2 ] || [ ${#hostname} -gt 63 ]; then error "Hostname must be 2-63 characters."; return 1; fi
    if ! echo "$hostname" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$'; then error "Invalid hostname format (RFC 1123)."; return 1; fi
    return 0
}

# Validate IP address format
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do if [ "$octet" -gt 255 ]; then return 1; fi; done
        return 0
    fi
    return 1
}

# Validate network prefix (CIDR notation)
validate_prefix() {
    local prefix=$1
    if [[ "$prefix" =~ ^[0-9]+$ ]] && [ "$prefix" -ge 1 ] && [ "$prefix" -le 32 ]; then return 0; fi
    return 1
}

# Validate DNS IP address format
validate_dns_ip() {
    local ip=$1
    # Verify it's a valid IPv4 address
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do if [ "$octet" -gt 255 ]; then return 1; fi; done
        return 0
    fi
    return 1
}

# --- Configuration & Application Functions ---

# Function to check for common misconfigurations
check_misconfigurations() {
    local interfaces_to_check="$1" # Pass selected interfaces
    local has_issues=0

    info "Performing pre-configuration checks..."
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        warning "NetworkManager is active. This often interferes with Proxmox networking."
        warning "Consider disabling it: 'systemctl disable --now NetworkManager'"
        has_issues=1
    fi
    if ls /etc/network/interfaces.d/* 1> /dev/null 2>&1; then
        warning "Files found in /etc/network/interfaces.d/ might conflict or override settings."
        has_issues=1
    fi
    # Check if selected interfaces are possibly used by VMs (basic check)
    for iface in $interfaces_to_check; do
        if grep -Eq "net[0-9]+=[^,]+,bridge=([^,]+|\Q$iface\E)" /etc/pve/qemu-server/*.conf 2>/dev/null || \
           grep -Eq "net[0-9]+=[^,]+,tag=[^,]+,bridge=([^,]+|\Q$iface\E)" /etc/pve/qemu-server/*.conf 2>/dev/null; then
            # This check is tricky. The real issue is if the *physical* interface is directly bridged
            # by a VM *instead* of being part of vmbr0. Grepping is imperfect.
            # A simpler check: is the interface *itself* listed as a bridge in a VM config?
             if grep -Eq "bridge=\Q$iface\E" /etc/pve/qemu-server/*.conf 2>/dev/null; then
                warning "Interface $iface might be directly used as a bridge by VMs. It should be part of vmbr0."
                has_issues=1
             fi
        fi
        local status=$(get_link_status "$iface")
        if [ "$status" != "up" ]; then
            warning "Interface $iface link status is '$status' (not 'up')."
            # Don't set has_issues=1 just for link down, it might be intentional or temporary.
        fi
    done

    if [ $has_issues -eq 0 ]; then
        success "Pre-configuration checks passed."
    fi
    return $has_issues # Return 0 if no issues, 1 if issues found
}

# Create static fallback configuration snippet
generate_static_fallback() {
    local iface="$1" ip="$2" prefix="$3" gateway="$4"
    if [ -z "$ip" ] || [ -z "$prefix" ] || [ -z "$gateway" ]; then error "Missing parameters for static fallback."; return 1; fi
    # Use more robust check: attempt ping gateway after assigning IP, only add route if successful
    cat << EOF

# Static fallback configuration for $iface
# Applied if DHCP fails after interface comes up
post-up /bin/bash -c 'ip link set \$IFACE up; sleep 2; if ! ip -4 addr show dev \$IFACE | grep -q "inet "; then echo "Applying static fallback $ip/$prefix"; ip addr add $ip/$prefix dev \$IFACE; if ping -c 1 -W 2 $gateway >/dev/null 2>&1; then ip route add default via $gateway dev \$IFACE metric 100; else echo Fallback IP set, but gateway $gateway unreachable; fi; fi'
EOF
}

# Function to configure interfaces file content
configure_interfaces() {
    local bonding_enabled=$1 selected_ifaces="$2" bond_mode="$3" \
          ipv6_enabled=$4 ipv6_method="$5" fallback_enabled=$6 \
          fallback_ip="$7" fallback_prefix="$8" fallback_gateway="$9"

    local config_content=""
    local bridge_port=""

    # Base loopback
    config_content+="auto lo\niface lo inet loopback\n\n"

    # Configure bond if enabled
    if [ "$bonding_enabled" = true ]; then
        config_content+="auto bond0\n"
        config_content+="iface bond0 inet manual\n"
        config_content+="    bond-slaves $selected_ifaces\n"
        config_content+="    bond-miimon 100\n"
        config_content+="    bond-mode $bond_mode\n"
        # Add LACP rate for 802.3ad if desired (optional)
        # if [ "$bond_mode" == "802.3ad" ]; then config_content+="    bond-lacp-rate 1\n"; fi
        config_content+="\n"
        bridge_port="bond0"
    else
        # If not bonding, ensure the selected interface is brought up manually
        # as it will be enslaved by the bridge.
        for iface in $selected_ifaces; do
             config_content+="auto $iface\n"
             config_content+="iface $iface inet manual\n\n"
        done
        bridge_port="$selected_ifaces"
    fi

    # Configure bridge vmbr0
    config_content+="auto vmbr0\n"
    config_content+="iface vmbr0 inet dhcp\n"
    config_content+="    bridge-ports $bridge_port\n"
    config_content+="    bridge-stp off\n"
    config_content+="    bridge-fd 0\n"
    # Optional: Add bridge_maxwait
    # config_content+="    bridge_maxwait 10\n"

    # Add static fallback if enabled
    if [ "$fallback_enabled" = true ]; then
        local fallback_stanza
        fallback_stanza=$(generate_static_fallback "vmbr0" "$fallback_ip" "$fallback_prefix" "$fallback_gateway")
        if [ $? -eq 0 ]; then
            config_content+="$fallback_stanza"
        else
            error "Failed to generate static fallback configuration."
            return 1
        fi
    fi

    # Add IPv6 configuration if enabled
    if [ "$ipv6_enabled" = true ]; then
        config_content+="\niface vmbr0 inet6 $ipv6_method\n"
    fi

    # Add source line for interfaces.d
    config_content+="\n# Include configurations from /etc/network/interfaces.d\n"
    config_content+="source /etc/network/interfaces.d/*\n"

    # Write or display the configuration
    local interfaces_file="/etc/network/interfaces"
    if [ "$DRY_RUN" = "true" ]; then
        info "DRY RUN: Proposed /etc/network/interfaces:"
        echo "--- START ---"
        echo -e "$config_content" # Use echo -e to interpret newlines
        echo "--- END ---"
    else
        # Write the configuration to the file
        echo -e "$config_content" > "$interfaces_file"
        if [ $? -ne 0 ]; then
            error "Failed to write to $interfaces_file"
            return 1
        fi
        success "Updated $interfaces_file with new configuration."
    fi
    return 0
}

# Function to apply network configuration and wait for DHCP
apply_network_configuration() {
    local backup_file="$1" timeout="$2" fallback_enabled="$3" ipv6_enabled="$4"
    local current_ip="" # Ensure variable is defined

    if [ "$DRY_RUN" = "true" ]; then
        info "DRY RUN: Would restart networking service using 'ifreload -a' or 'systemctl restart networking'."
        info "DRY RUN: Would wait up to $timeout seconds for DHCP on vmbr0."
        # Simulate success for dry run to test subsequent steps
        current_ip="192.0.2.123" # Dummy IP for dry run
        echo "$current_ip"
        return 0
    fi

    info "Applying network configuration..."
    # Use ifreload if available (safer), otherwise fallback to systemctl restart
    if command -v ifreload > /dev/null; then
        if ! execute ifreload -a; then
            error "'ifreload -a' failed. Attempting rollback..."
            execute cp "$backup_file" /etc/network/interfaces || error "!!! ROLLBACK FAILED TO COPY $backup_file !!!"
            execute ifreload -a || error "!!! NETWORK RESTART AFTER ROLLBACK FAILED !!!"
            return 1
        fi
    else
        warning "'ifreload' not found, using 'systemctl restart networking'. This might be more disruptive."
        if ! execute systemctl restart networking; then
            error "'systemctl restart networking' failed. Attempting rollback..."
            execute cp "$backup_file" /etc/network/interfaces || error "!!! ROLLBACK FAILED TO COPY $backup_file !!!"
            execute systemctl restart networking || error "!!! NETWORK RESTART AFTER ROLLBACK FAILED !!!"
            return 1
        fi
    fi

    info "Waiting for DHCPv4 lease on vmbr0 (up to $timeout seconds)..." >&2
    for i in $(seq 1 $timeout); do
        # Send progress to stderr
        progress "Waiting for DHCPv4" $timeout $i >&2  
        current_ip=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        if [ -n "$current_ip" ]; then
            echo >&2 # Clear progress line (to stderr)
            success "DHCPv4 lease obtained on vmbr0: $current_ip" >&2
            break
        fi
        sleep 1
    done

    # Check if IP was obtained (either DHCP or fallback)
    if [ -z "$current_ip" ]; then
        # Re-check IP after loop in case fallback applied late
        current_ip=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        if [ -n "$current_ip" ] && [ "$fallback_enabled" = true ]; then
             echo # Clear progress line
             success "Static fallback IP activated on vmbr0: $current_ip"
        else
             echo # Clear progress line
             error "Timeout waiting for DHCPv4 lease on vmbr0, and fallback did not activate or wasn't configured."
             error "Consider checking DHCP server, network cables, or rolling back:"
             error "  cp $backup_file /etc/network/interfaces && ifreload -a"
             return 1 # Explicit failure
        fi
    fi

    # Check for IPv6 address if enabled
    if [ "$ipv6_enabled" = true ]; then
        info "Checking for IPv6 address on vmbr0..."
        sleep 5 # Give IPv6 a bit more time
        local ipv6_addr=$(ip -6 addr show vmbr0 scope global 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-f:]+/[0-9]+' | head -n 1)
        if [ -n "$ipv6_addr" ]; then
            success "IPv6 address obtained: $ipv6_addr"
        else
            warning "No global IPv6 address obtained on vmbr0 after wait."
        fi
    fi

    echo "$current_ip" # Output the obtained IPv4 for hosts file update
    return 0 # Success
}

# --- Main Script Execution ---

# Display banner
echo -e "\n${GREEN}=============================================================${NC}"
echo -e "${GREEN}        Proxmox DHCP Configuration Script      ${NC}"
echo -e "${GREEN}=============================================================${NC}"
echo

# Warn about dry-run mode if active
if [ "$DRY_RUN" = "true" ]; then
    info "Running in DRY RUN mode. No changes will be made."
    info "Configuration preview will be shown. Network will not be restarted."
    echo
fi

# Check for root privileges
if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" != "true" ]; then
  error "This script must be run as root unless in dry-run mode."
  exit 1
fi

# Warn if running over SSH
if [ -n "$SSH_CONNECTION" ]; then
    warning "Running over SSH detected. Network changes can disconnect your session."
    warning "Ensure console access or IPMI/KVM is available if issues arise."
    read -p "Proceed anyway? (y/N): " confirm_ssh
    if [[ ! "$confirm_ssh" =~ ^[Yy]$ ]]; then info "Exiting."; exit 0; fi
    echo
fi

# --- Gather Information ---

HOSTNAME=$(hostname)
info "Current hostname: $HOSTNAME"
if ! validate_hostname "$HOSTNAME"; then error "Please fix the hostname and re-run."; exit 1; fi
success "Hostname '$HOSTNAME' is valid."

PHYSICAL_IFACES_LIST=($(detect_suitable_interfaces)) # Store in array
if [ ${#PHYSICAL_IFACES_LIST[@]} -eq 0 ]; then error "No suitable physical network interfaces found. Exiting."; exit 1; fi

info "Detected suitable physical interfaces:"
DEFAULT_IFACE=$(get_default_interface)
for iface in "${PHYSICAL_IFACES_LIST[@]}"; do
    mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || echo "N/A")
    status=$(get_link_status "$iface")
    speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null)
    speed_str=$([ -n "$speed" ] && echo "${speed}Mbps" || echo "Unknown")
    default_tag=$([ "$iface" = "$DEFAULT_IFACE" ] && echo " (Current Default Route)" || echo "")
    echo -e "  - ${BLUE}${iface}${NC}${default_tag}: MAC $mac, Status $status, Speed $speed_str"
done
echo

# --- Select Interfaces and Mode ---
SELECTED_IFACES=""
BONDING_ENABLED=false
BOND_MODE=""

if [ ${#PHYSICAL_IFACES_LIST[@]} -gt 1 ]; then
    info "Multiple interfaces available: ${PHYSICAL_IFACES_LIST[*]}"
    read -p "Do you want to create a bond from these interfaces? (y/N): " use_bond
    if [[ "$use_bond" =~ ^[Yy]$ ]]; then
        BONDING_ENABLED=true
        SELECTED_IFACES_ARRAY=($(select_bond_interfaces "${PHYSICAL_IFACES_LIST[@]}"))
        if [ $? -ne 0 ] || [ ${#SELECTED_IFACES_ARRAY[@]} -lt 2 ]; then
             error "Bonding setup cancelled or failed."
             exit 1
        fi
        SELECTED_IFACES="${SELECTED_IFACES_ARRAY[*]}" # Space separated
        success "Selected interfaces for bonding: $SELECTED_IFACES"
        BOND_MODE=$(select_bond_mode)
        success "Using bond mode: $BOND_MODE"
    else
        info "Bonding not selected. Please choose a single interface for vmbr0:"
        select iface in "${PHYSICAL_IFACES_LIST[@]}" "Cancel"; do
            if [ "$iface" == "Cancel" ]; then info "Operation cancelled."; exit 0; fi
            if [ -n "$iface" ]; then
                SELECTED_IFACES="$iface"
                success "Selected single interface: $SELECTED_IFACES"
                break
            else
                error "Invalid selection. Please choose a number from the list."
            fi
        done
    fi
else
    # Only one interface available, use it directly
    SELECTED_IFACES="${PHYSICAL_IFACES_LIST[0]}"
    BONDING_ENABLED=false
    success "Using the only available interface: $SELECTED_IFACES"
fi

if [ -z "$SELECTED_IFACES" ]; then error "No interface was selected. Exiting."; exit 1; fi

# --- Pre-Checks ---
if ! check_misconfigurations "$SELECTED_IFACES"; then
    warning "Potential issues detected. Review warnings above."
    read -p "Continue despite warnings? (y/N): " continue_anyway
    if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then info "Exiting."; exit 0; fi
fi

# --- Configure Options (IPv6, Fallback) ---
read -p "Configure IPv6 on vmbr0? (y/N): " configure_ipv6
IPV6_ENABLED=false
IPV6_METHOD=""
PRIMARY_DNS=""
SECONDARY_DNS=""

if [[ "$configure_ipv6" =~ ^[Yy]$ ]]; then
    IPV6_ENABLED=true
    read -p "Use DHCPv6 or SLAAC (auto)? [dhcp/auto, default: auto]: " ipv6_choice
    if [[ "$ipv6_choice" =~ ^[Dd][Hh][Cc][Pp]$ ]]; then IPV6_METHOD="dhcp"; else IPV6_METHOD="auto"; fi
    success "IPv6 enabled using: $IPV6_METHOD"
    
    # Ask for IPv4 DNS servers to preserve
    read -p "Configure IPv4 DNS servers to ensure dual-stack DNS resolution? (Y/n): " configure_dns
    if [[ ! "$configure_dns" =~ ^[Nn]$ ]]; then
        # Ask for primary IPv4 DNS server
        while true; do
            read -p "Enter primary IPv4 DNS server [8.8.8.8]: " PRIMARY_DNS
            PRIMARY_DNS=${PRIMARY_DNS:-8.8.8.8} # Default to Google DNS if empty
            if validate_dns_ip "$PRIMARY_DNS"; then break; else error "Invalid IPv4 address format."; fi
        done
        
        # Ask for secondary IPv4 DNS server
        while true; do
            read -p "Enter secondary IPv4 DNS server [1.1.1.1]: " SECONDARY_DNS
            SECONDARY_DNS=${SECONDARY_DNS:-1.1.1.1} # Default to Cloudflare DNS if empty
            if validate_dns_ip "$SECONDARY_DNS"; then
                if [ "$SECONDARY_DNS" = "$PRIMARY_DNS" ]; then
                    warning "Secondary DNS is the same as primary. Continuing anyway."
                fi
                break
            else
                error "Invalid IPv4 address format."
            fi
        done
        
        success "IPv4 DNS servers set: $PRIMARY_DNS, $SECONDARY_DNS"
        
        # Configure DHCP client to preserve IPv4 DNS servers
        info "Configuring DHCP client to preserve IPv4 DNS servers..."
        if [ -f "/etc/dhcp/dhclient.conf" ]; then
            if [ "$DRY_RUN" = "true" ]; then
                info "DRY RUN: Would update dhclient.conf to prepend DNS servers: $PRIMARY_DNS, $SECONDARY_DNS"
            else
                if grep -q "^#prepend domain-name-servers" /etc/dhcp/dhclient.conf; then
                    execute sed -i "s/#prepend domain-name-servers.*/prepend domain-name-servers $PRIMARY_DNS, $SECONDARY_DNS;/" /etc/dhcp/dhclient.conf
                    success "Updated dhclient.conf to preserve IPv4 DNS servers"
                elif ! grep -q "^prepend domain-name-servers" /etc/dhcp/dhclient.conf; then
                    execute sed -i "/request subnet-mask/a prepend domain-name-servers $PRIMARY_DNS, $SECONDARY_DNS;" /etc/dhcp/dhclient.conf
                    success "Added IPv4 DNS configuration to dhclient.conf"
                else
                    # Replace existing prepend line
                    execute sed -i "s/^prepend domain-name-servers.*/prepend domain-name-servers $PRIMARY_DNS, $SECONDARY_DNS;/" /etc/dhcp/dhclient.conf
                    success "Updated existing IPv4 DNS servers in dhclient.conf"
                fi
            fi
        else
            warning "dhclient.conf not found at /etc/dhcp/dhclient.conf"
        fi
    fi
fi

read -p "Configure a static IPv4 fallback if DHCP fails? (y/N): " use_fallback
FALLBACK_ENABLED=false
FALLBACK_IP=""
FALLBACK_PREFIX=""
FALLBACK_GATEWAY=""
if [[ "$use_fallback" =~ ^[Yy]$ ]]; then
    while true; do read -p "Enter static fallback IP address: " FALLBACK_IP; if validate_ip "$FALLBACK_IP"; then break; else error "Invalid IP."; fi; done
    while true; do read -p "Enter fallback network prefix length (e.g., 24): " FALLBACK_PREFIX; if validate_prefix "$FALLBACK_PREFIX"; then break; else error "Invalid prefix (1-32)."; fi; done
    while true; do read -p "Enter fallback gateway IP address: " FALLBACK_GATEWAY; if validate_ip "$FALLBACK_GATEWAY"; then break; else error "Invalid IP."; fi; done
    FALLBACK_ENABLED=true
    success "Static fallback configured: $FALLBACK_IP/$FALLBACK_PREFIX via $FALLBACK_GATEWAY"
fi

# --- Summary and Confirmation ---
echo
info "--- Configuration Summary ---"
info "Hostname:          $HOSTNAME"
info "Configure bridge:  vmbr0"
if $BONDING_ENABLED; then
    info "Mode:              Bonding"
    info "Bond Mode:         $BOND_MODE"
    info "Bond Slaves:       $SELECTED_IFACES"
    info "Bridge Port:       bond0"
else
    info "Mode:              Single Interface"
    info "Physical Port:     $SELECTED_IFACES"
    info "Bridge Port:       $SELECTED_IFACES"
fi
info "IPv4 Method:       DHCP"
info "IPv6 Enabled:      $IPV6_ENABLED"
if $IPV6_ENABLED; then 
    info "IPv6 Method:       $IPV6_METHOD"
    if [ -n "$PRIMARY_DNS" ] && [ -n "$SECONDARY_DNS" ]; then
        info "IPv4 DNS Servers:  $PRIMARY_DNS, $SECONDARY_DNS"
    fi
fi
info "Static Fallback:   $FALLBACK_ENABLED"
if $FALLBACK_ENABLED; then info "Fallback IP:       $FALLBACK_IP/$FALLBACK_PREFIX via $FALLBACK_GATEWAY"; fi
echo "---------------------------"

if [ "$DRY_RUN" != "true" ]; then
    read -p "Proceed with applying this configuration? (y/N): " confirm_apply
    if [[ ! "$confirm_apply" =~ ^[Yy]$ ]]; then
        info "Aborted by user. No changes made."
        exit 0
    fi
else
    info "Dry run mode: Configuration will be generated but not applied."
fi

# --- Backup ---
BACKUP_FILE="/etc/network/interfaces.backup.$(date +%Y%m%d%H%M%S)"
if [ "$DRY_RUN" != "true" ]; then
    if ! execute cp /etc/network/interfaces "$BACKUP_FILE"; then
        error "Failed to backup /etc/network/interfaces. Aborting."
        exit 1
    fi
    success "Backed up current network config to $BACKUP_FILE"
else
    info "DRY RUN: Would backup /etc/network/interfaces to $BACKUP_FILE"
fi

# --- Configure ---
if ! configure_interfaces "$BONDING_ENABLED" "$SELECTED_IFACES" "$BOND_MODE" \
                         "$IPV6_ENABLED" "$IPV6_METHOD" "$FALLBACK_ENABLED" \
                         "$FALLBACK_IP" "$FALLBACK_PREFIX" "$FALLBACK_GATEWAY"; then
    error "Failed to generate or write network configuration. Aborting."
    # Attempt to restore backup immediately if write failed? Less likely needed.
    exit 1
fi

# --- Apply and Verify ---
OBTAINED_IP=""
NETWORK_APPLY_SUCCESS=false
if [ "$DRY_RUN" != "true" ]; then
    APPLY_RESULT=$(apply_network_configuration "$BACKUP_FILE" 60 "$FALLBACK_ENABLED" "$IPV6_ENABLED")
    APPLY_STATUS=$? # Capture return status

    if [ $APPLY_STATUS -eq 0 ] && [ -n "$APPLY_RESULT" ]; then
        OBTAINED_IP="$APPLY_RESULT"
        NETWORK_APPLY_SUCCESS=true
        success "Network configuration applied successfully. Current IPv4: $OBTAINED_IP"
    else
        error "Network configuration failed to apply or obtain IP address."
        warning "Check network status manually ('ip a', 'ip r')."
        warning "Previous config backed up to: $BACKUP_FILE"
        NETWORK_APPLY_SUCCESS=false
        # Do not proceed to hosts update or tests if network failed
    fi
else
    # Simulate success for dry run post-steps
    OBTAINED_IP="192.0.2.123" # Dummy IP for dry run
    NETWORK_APPLY_SUCCESS=true
    info "DRY RUN: Network apply step simulated."
fi

# --- Post-Apply Steps (Hosts, Tests) ---
if $NETWORK_APPLY_SUCCESS; then
    # Update /etc/hosts
    FQDN=$(hostname -f 2>/dev/null || echo "$HOSTNAME")
    if [ "$DRY_RUN" != "true" ]; then
        # Remove old entries (directly without using execute function)
        sed -i -E "/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+.*\b($HOSTNAME|$FQDN)\b[[:space:]]*$/d" /etc/hosts
        sed -i -E "/^::1[[:space:]]+.*\b($HOSTNAME|$FQDN)\b[[:space:]]*$/d" /etc/hosts
        sed -i "/[[:space:]]$HOSTNAME$/d" /etc/hosts
        
        # Add new entry (separate command from success message)
        if echo "$OBTAINED_IP $FQDN $HOSTNAME" >> /etc/hosts; then
             success "Updated /etc/hosts: $OBTAINED_IP $FQDN $HOSTNAME"
        else
             error "Failed to update /etc/hosts automatically."
        fi
    else
        info "DRY RUN: Would update /etc/hosts with: $OBTAINED_IP $FQDN $HOSTNAME"
    fi

    # Add DHCP client exit hook for DNS preservation
    if $IPV6_ENABLED && [ -n "$PRIMARY_DNS" ] && [ -n "$SECONDARY_DNS" ] && [ "$DRY_RUN" != "true" ]; then
        info "Setting up DHCP client exit hook for DNS preservation..."
        hooks_dir="/etc/dhcp/dhclient-exit-hooks.d"
        hook_file="$hooks_dir/dns-ipv4"
        
        if [ ! -d "$hooks_dir" ]; then
            execute mkdir -p "$hooks_dir"
        fi
        
        cat > "$hook_file.tmp" << EOF
#!/bin/sh
# Always ensure IPv4 DNS servers are present
if [ -f /etc/resolv.conf ]; then
  # Remove duplicate nameserver entries first
  TMP_RESOLV=\$(mktemp)
  awk '!seen[\$0]++' /etc/resolv.conf > "\$TMP_RESOLV"
  cat "\$TMP_RESOLV" > /etc/resolv.conf
  rm -f "\$TMP_RESOLV"
  
  # Add IPv4 DNS servers if not present
  if ! grep -q "nameserver $PRIMARY_DNS" /etc/resolv.conf; then
    sed -i '1i nameserver $PRIMARY_DNS' /etc/resolv.conf
  fi
  if ! grep -q "nameserver $SECONDARY_DNS" /etc/resolv.conf; then
    sed -i '2i nameserver $SECONDARY_DNS' /etc/resolv.conf
  fi
fi
EOF
        
        execute mv "$hook_file.tmp" "$hook_file"
        execute chmod +x "$hook_file"
        success "Created DHCP client exit hook to maintain IPv4 DNS servers"
    fi

    # Connectivity Tests
    info "Performing connectivity tests..."
    TEST_TARGET_IP="8.8.8.8" # Google Public DNS
    TEST_TARGET_HOST="google.com"

    if execute ping -c 1 -W 3 "$TEST_TARGET_IP" >/dev/null 2>&1; then
        success "Internet connectivity (ping $TEST_TARGET_IP): OK"
    else
        warning "Internet connectivity (ping $TEST_TARGET_IP): FAILED"
    fi

    if execute host -W 3 "$TEST_TARGET_HOST" >/dev/null 2>&1; then
        success "DNS resolution (host $TEST_TARGET_HOST): OK"
    else
        warning "DNS resolution (host $TEST_TARGET_HOST): FAILED"
        warning "Check DNS settings from DHCP or '/etc/resolv.conf'."
    fi
fi

# --- Final Output ---
echo
if [ "$DRY_RUN" = "true" ]; then
    success "DRY RUN finished. No system changes were made."
    info "Review the proposed configuration above."
    info "Run without --dry-run or -d to apply."
else
    if $NETWORK_APPLY_SUCCESS; then
        success "DHCP configuration process completed."
        # Check DNS configuration
        if [ -f /etc/resolv.conf ]; then  # Removed redundant DRY_RUN check
            info "Checking DNS configuration..."
            if ! grep -q "nameserver [0-9]" /etc/resolv.conf; then
                warning "No IPv4 DNS servers found in /etc/resolv.conf"
                warning "Adding Google DNS (8.8.8.8) as a fallback"
                echo "nameserver 8.8.8.8" >> /etc/resolv.conf
                success "Added IPv4 DNS server to /etc/resolv.conf"
            fi
            
            # Check for duplicate entries
            RESOLV_TMP=$(mktemp)
            sort -u /etc/resolv.conf > "$RESOLV_TMP"
            if ! cmp -s "$RESOLV_TMP" /etc/resolv.conf; then
                warning "Duplicate entries found in /etc/resolv.conf, fixing..."
                cat "$RESOLV_TMP" > /etc/resolv.conf
                success "Removed duplicate DNS entries"
            fi
            rm -f "$RESOLV_TMP"
        fi
    else
        error "DHCP configuration process FAILED. See errors above."
    fi
    info "Network configuration file: /etc/network/interfaces"
    info "Backup of previous config: $BACKUP_FILE"
    info "To restore: cp $BACKUP_FILE /etc/network/interfaces && ifreload -a"
fi

echo
info "Useful commands to verify:"
echo "  ip addr show vmbr0"
echo "  ip route"
if $IPV6_ENABLED; then
    echo "  ip -6 addr show vmbr0 scope global"
    echo "  ip -6 route"
fi
echo "  cat /etc/resolv.conf"
echo "  cat /etc/hosts"

exit $($NETWORK_APPLY_SUCCESS || echo 1) # Exit 0 on success, 1 on failure (in non-dry-run)