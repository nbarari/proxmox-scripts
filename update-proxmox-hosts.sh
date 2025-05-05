#!/bin/bash
# ===============================================================================
# Proxmox Hosts File Updater
# ===============================================================================
# Description: Updates /etc/hosts only if the IP address for vmbr0 has changed.
# Author: nbarari
# GitHub: https://github.com/nbarari/proxmox-scripts
# ===============================================================================

set -e # Exit on error

HOSTNAME=$(hostname)
# Try harder to get a proper FQDN
FQDN=$(hostname -f 2>/dev/null)
if [ -z "$FQDN" ] || [ "$FQDN" == "$HOSTNAME" ]; then
    # Fallback if hostname -f doesn't work or returns only short name
    DOMAIN=$(dnsdomainname 2>/dev/null)
    if [ -n "$DOMAIN" ]; then
        FQDN="$HOSTNAME.$DOMAIN"
    else
        FQDN="$HOSTNAME" # Worst case, use short name
    fi
fi

INTERFACE="vmbr0"
HOSTS_FILE="/etc/hosts"
NEEDS_UPDATE=false
SERVICES_TO_RESTART="pvedaemon pveproxy pvestatd" # Consider if pve-cluster is really needed

# --- Get Current IPv4 Address ---
CURRENT_IP=$(ip -4 addr show $INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)

if [ -z "$CURRENT_IP" ]; then
    echo "$(date): Error: Could not detect IPv4 address for interface $INTERFACE" >&2
    exit 1
fi

# --- Check /etc/hosts for current IP and hostnames ---
# Check if the current IP already maps to the correct FQDN or hostname
if ! grep -q -E "^\s*$CURRENT_IP\s+.*\b($FQDN|$HOSTNAME)\b" "$HOSTS_FILE"; then
    # If the IP isn't mapped correctly, we definitely need an update
    NEEDS_UPDATE=true
    echo "$(date): IP $CURRENT_IP not correctly mapped to $FQDN/$HOSTNAME in $HOSTS_FILE."
else
    # If IP is mapped, check if *other* IPs are mapped to our hostnames (stale entries)
    if grep -q -E "^\s*[0-9.]+\s+.*\b($FQDN|$HOSTNAME)\b" "$HOSTS_FILE" | grep -v "^\s*$CURRENT_IP\s"; then
       NEEDS_UPDATE=true
       echo "$(date): Found stale IP entries for $FQDN/$HOSTNAME in $HOSTS_FILE."
    else
       echo "$(date): Hosts file ($HOSTS_FILE) appears up-to-date for $CURRENT_IP -> $FQDN/$HOSTNAME."
    fi
fi

# --- Update /etc/hosts if needed ---
if [ "$NEEDS_UPDATE" = true ]; then
    echo "$(date): Updating $HOSTS_FILE..."
    # Create a temporary file
    TMP_HOSTS=$(mktemp)
    if [ -z "$TMP_HOSTS" ]; then
        echo "$(date): Error: Could not create temporary file." >&2
        exit 1
    fi

    # Copy non-hostname lines and the correct new line to temp file
    # Remove any line mapping ANY IP to our hostname/FQDN
    grep -v -E "\s+.*\b($FQDN|$HOSTNAME)\b" "$HOSTS_FILE" > "$TMP_HOSTS"
    # Add the correct line
    echo "$CURRENT_IP    $FQDN $HOSTNAME" >> "$TMP_HOSTS"

    # Check if the temp file is valid (basic check)
    if [ -s "$TMP_HOSTS" ]; then
        # Replace the original file
        if ! cp "$TMP_HOSTS" "$HOSTS_FILE"; then
             echo "$(date): Error: Failed to overwrite $HOSTS_FILE." >&2
             rm "$TMP_HOSTS"
             exit 1
        fi
        chmod 644 "$HOSTS_FILE" # Ensure correct permissions
        echo "$(date): Successfully updated $HOSTS_FILE with $CURRENT_IP -> $FQDN $HOSTNAME"

        # --- Restart Services only after successful update ---
        echo "$(date): Restarting Proxmox services due to hosts file change..."
        # Consider if pve-cluster restart is essential or too disruptive
        # if systemctl restart pve-cluster; then
        #    systemctl restart $SERVICES_TO_RESTART || echo "$(date): Warning: Failed to restart some services ($SERVICES_TO_RESTART)" >&2
        # else
        #    echo "$(date): Warning: Failed to restart pve-cluster. Other services not restarted." >&2
        # fi
        # Alternative: Less disruptive restart/reload
         systemctl restart $SERVICES_TO_RESTART || echo "$(date): Warning: Failed to restart some services ($SERVICES_TO_RESTART)" >&2
         # Or maybe just: systemctl reload pveproxy || echo ...

    else
        echo "$(date): Error: Temporary hosts file was empty. Original $HOSTS_FILE not changed." >&2
        rm "$TMP_HOSTS"
        exit 1
    fi
    rm "$TMP_HOSTS"
else
    echo "$(date): No hosts file update required."
fi

exit 0
