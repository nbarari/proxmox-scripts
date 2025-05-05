# Proxmox DHCP Configuration Scripts

A collection of scripts to configure and maintain Proxmox VE hosts using DHCP networking, with support for advanced features like bonding, IPv6, and static fallback.

## Table of Contents

*   [Overview](#overview)
*   [Scripts](#scripts)
    *   [`proxmox-dhcp.sh` (DHCP Configuration)](#proxmox-dhcpsh-dhcp-configuration)
    *   [`update-proxmox-hosts.sh` (Hosts File Updater)](#update-proxmox-hostssh-hosts-file-updater)
*   [Example `/etc/network/interfaces` Configurations](#example-etcnetworkinterfaces-configurations)
    *   [Example 1: Bonded Interfaces (active-backup mode)](#example-1-bonded-interfaces-active-backup-mode)
    *   [Example 2: Single Interface (non-bonded)](#example-2-single-interface-non-bonded)
*   [Installation](#installation)
    *   [Method 1: Clone the Repository](#method-1-clone-the-repository)
    *   [Method 2: Manual Download](#method-2-manual-download)
*   [Usage](#usage)
    *   [First-Time DHCP Configuration](#first-time-dhcp-configuration)
    *   [Setting Up Automatic Hosts File Updates](#setting-up-automatic-hosts-file-updates)
        *   [Method 1: Systemd (Recommended)](#method-1-systemd-recommended)
        *   [Method 2: Cron (Alternative/Supplemental)](#method-2-cron-alternativesupplemental)
*   [Troubleshooting](#troubleshooting)

---

## Overview

Using DHCP on a Proxmox host can be convenient, but requires careful setup of the network bridge and ongoing management of the `/etc/hosts` file to ensure Proxmox services function correctly if the IP address changes. These scripts aim to simplify this process:

1.  **Initial Configuration (`proxmox-dhcp.sh`)**: Automatically configures Proxmox networking for DHCP, handling bridge creation, optional bonding, IPv6, and fallback IPs.
2.  **IP Address Updates (`update-proxmox-hosts.sh`)**: Keeps the Proxmox `/etc/hosts` file synchronized with the current IP address assigned via DHCP or static fallback, ensuring service reachability.

## Scripts

### `proxmox-dhcp.sh` (DHCP Configuration)

This script performs the initial, interactive configuration of a Proxmox host to use DHCP for its management interface (`vmbr0`).

**Features:**

*   **Detects Suitable Physical Interfaces**: Identifies physical network interfaces, filtering out loopback, virtual devices (bonds, bridges, veth, tap), and VLAN interfaces.
*   **Network Bonding**:
    *   Prompts to create a network bond if multiple suitable interfaces are found.
    *   Allows interactive selection of specific interfaces to include in the bond (requires at least two).
    *   Supports multiple bonding modes: `active-backup` (default, fault tolerance), `802.3ad` (LACP), `balance-alb`, `balance-tlb`, `balance-xor`.
*   **Single Interface Support**: Configures `vmbr0` using a single selected physical interface if bonding is not desired or only one NIC is available.
*   **DHCP Bridge Setup**: Creates the standard Proxmox bridge (`vmbr0`) configured to obtain an IPv4 address via DHCP.
*   **IPv6 Support**: Optionally configures IPv6 on `vmbr0` using SLAAC (`auto`) or DHCPv6 (`dhcp`).
*   **Static Fallback**: Optionally configures a static IPv4 address, prefix, and gateway that will be applied automatically if DHCP fails.
*   **Safety Features**:
    *   Includes a **`--dry-run`** mode to preview changes without applying them.
    *   Performs **pre-configuration checks** (e.g., warns about active NetworkManager, potential interface usage conflicts).
    *   Creates a **timestamped backup** of `/etc/network/interfaces` before making changes.
    *   Attempts to **rollback** to the backup if applying the new configuration fails.
    *   Requires user confirmation before applying changes (unless in dry-run mode).
    *   Warns and requires confirmation if run over SSH.
*   **Hosts File Update**: Automatically updates `/etc/hosts` with the obtained IP address upon successful configuration.
*   **User Friendly**: Provides colored output, clear prompts, and input validation.

**Note:**
*   You must run this script as root (`sudo`).
*   Applying network changes can disconnect your SSH session. Ensure you have console or out-of-band access available.

### `update-proxmox-hosts.sh` (Hosts File Updater)

This script is designed to run periodically (e.g., via systemd or cron) to ensure the `/etc/hosts` file stays synchronized with the current IP address of the `vmbr0` interface. This is crucial for Proxmox cluster communication and web UI access if the DHCP lease changes.

**Features:**

*   Detects the current primary IPv4 address on the `vmbr0` interface.
*   Retrieves the system's hostname and attempts to determine the Fully Qualified Domain Name (FQDN).
*   **Checks if `/etc/hosts` already reflects the correct IP-to-hostname mapping.**
*   If an update is needed:
    *   Safely removes any old/stale entries for the hostname or FQDN.
    *   Adds the correct `IP FQDN HOSTNAME` line.
    *   **(Recommended Enhancement)** Restarts necessary Proxmox services (e.g., `pvedaemon`, `pveproxy`, `pvestatd`) *only if* the hosts file was actually modified. *Consider customizing which services are restarted for your environment.*
*   Currently focuses on the primary IPv4 address.

## Example `/etc/network/interfaces` Configurations

The `proxmox-dhcp.sh` script generates configurations like these:

### Example 1: Bonded Interfaces (active-backup mode)

```ini
auto lo
iface lo inet loopback

auto bond0
iface bond0 inet manual
    bond-slaves enp2s0 enp3s0  # Your selected interfaces
    bond-miimon 100
    bond-mode active-backup   # Your selected bond mode

# Physical interfaces included in the bond need manual stanzas
auto enp2s0
iface enp2s0 inet manual

auto enp3s0
iface enp3s0 inet manual

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports bond0
    bridge-stp off
    bridge-fd 0
# --- Optional Additions (if selected in script) ---
# iface vmbr0 inet6 auto  # Or inet6 dhcp
# post-up /bin/bash -c '...' # Static fallback scriptlet

# Include configurations from /etc/network/interfaces.d
source /etc/network/interfaces.d/*
```

### Example 2: Single Interface (non-bonded)

```ini
auto lo
iface lo inet loopback

# Physical interface needs a manual stanza to be included in bridge
auto enp2s0  # Your selected interface
iface enp2s0 inet manual

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports enp2s0  # Your selected interface
    bridge-stp off
    bridge-fd 0
# --- Optional Additions (if selected in script) ---
# iface vmbr0 inet6 auto  # Or inet6 dhcp
# post-up /bin/bash -c '...' # Static fallback scriptlet

# Include configurations from /etc/network/interfaces.d
source /etc/network/interfaces.d/*
```

## Installation

Choose one method:

### Method 1: Clone the Repository

```bash
# Clone the repository
git clone https://github.com/nbarari/proxmox-scripts.git
cd proxmox-scripts

# Copy files to appropriate locations (adjust script names if you renamed them)
sudo cp proxmox-dhcp.sh /usr/local/bin/
sudo cp update-proxmox-hosts.sh /usr/local/bin/
# Assuming systemd files are in a 'systemd' subdirectory
sudo cp systemd/update-proxmox-hosts.service /etc/systemd/system/
sudo cp systemd/update-proxmox-hosts.path /etc/systemd/system/

# Make scripts executable
sudo chmod +x /usr/local/bin/proxmox-dhcp.sh
sudo chmod +x /usr/local/bin/update-proxmox-hosts.sh

# Reload systemd daemon
sudo systemctl daemon-reload
```

### Method 2: Manual Download

```bash
# Download the configuration script (adjust URL/filename if needed)
sudo wget -O /usr/local/bin/proxmox-dhcp.sh https://raw.githubusercontent.com/nbarari/proxmox-scripts/main/proxmox-dhcp.sh
sudo chmod +x /usr/local/bin/proxmox-dhcp.sh

# Download the hosts updater script (adjust URL/filename if needed)
sudo wget -O /usr/local/bin/update-proxmox-hosts.sh https://raw.githubusercontent.com/nbarari/proxmox-scripts/main/update-proxmox-hosts.sh
sudo chmod +x /usr/local/bin/update-proxmox-hosts.sh

# Download systemd service files (adjust URLs if needed)
sudo wget -O /etc/systemd/system/update-proxmox-hosts.service https://raw.githubusercontent.com/nbarari/proxmox-scripts/main/systemd/update-proxmox-hosts.service
sudo wget -O /etc/systemd/system/update-proxmox-hosts.path https://raw.githubusercontent.com/nbarari/proxmox-scripts/main/systemd/update-proxmox-hosts.path

# Reload systemd daemon
sudo systemctl daemon-reload
```

## Usage

### First-Time DHCP Configuration

1.  **Run the configuration script with `--dry-run` first:**
    ```bash
    sudo /usr/local/bin/proxmox-dhcp.sh --dry-run
    ```
    Review the detected interfaces, options selected, and the proposed `/etc/network/interfaces` configuration.

2.  **Run the script without `--dry-run`:**
    ```bash
    sudo /usr/local/bin/proxmox-dhcp.sh
    ```
    *   Follow the prompts to select interfaces, bonding mode (if applicable), IPv6 options, and static fallback.
    *   Confirm the summary to proceed.
    *   The script will:
        *   Backup your current configuration.
        *   Write the new `/etc/network/interfaces`.
        *   Attempt to apply the configuration (using `ifreload -a` or `systemctl restart networking`).
        *   Wait for an IP address on `vmbr0`.
        *   Update `/etc/hosts` if successful.

3.  **Verify Configuration:**
    After the script completes (or if you encounter issues), verify the network status:
    ```bash
    ip addr show vmbr0
    ip route
    cat /etc/network/interfaces # Verify the generated config
    cat /etc/hosts             # Verify hosts file entry
    ```
    If the script failed to apply the configuration or you lost connection, use the console/OOB access to restore the backup (`sudo cp /etc/network/interfaces.backup.YYYYMMDDHHMMSS /etc/network/interfaces`) and restart networking (`sudo ifreload -a` or `sudo systemctl restart networking`). A reboot may also help apply changes cleanly.

### Setting Up Automatic Hosts File Updates

To keep `/etc/hosts` synchronized automatically when the IP changes, use the provided systemd units or set up cron jobs. Systemd is generally recommended.

#### Method 1: Systemd (Recommended)

The `.path` unit monitors for network changes (specifically, the `vmbr0` interface status), and the `.service` unit runs the `update-proxmox-hosts.sh` script when triggered.

1.  Enable and start the systemd path unit (this will automatically activate the service when needed):
    ```bash
    sudo systemctl enable update-proxmox-hosts.path
    sudo systemctl start update-proxmox-hosts.path
    ```

2.  Verify the path unit is active:
    ```bash
    systemctl status update-proxmox-hosts.path
    ```
    You can also check when the service last ran:
    ```bash
    systemctl status update-proxmox-hosts.service
    ```

#### Method 2: Cron (Alternative/Supplemental)

This provides purely time-based checks. It can be used alongside systemd or as an alternative if systemd units are not preferred.

```bash
# Check and update on reboot
(crontab -l 2>/dev/null; echo "@reboot /usr/local/bin/update-proxmox-hosts.sh >> /var/log/update-hosts.log 2>&1") | sudo crontab -u root -

# Check and update every 15 minutes
(crontab -l 2>/dev/null; echo "*/15 * * * * /usr/local/bin/update-proxmox-hosts.sh >> /var/log/update-hosts.log 2>&1") | sudo crontab -u root -
```
*(Note: Using cron adds periodic checks but might be redundant if the systemd `.path` unit reliably triggers updates.)*

## Troubleshooting

If you encounter issues with Proxmox services after IP changes:

1.  **Check Hostname Resolution:**
    ```bash
    ping $(hostname)    # Should resolve to the current vmbr0 IP
    ping $(hostname -f) # Should also resolve correctly
    ```

2.  **Verify Hosts File:**
    ```bash
    cat /etc/hosts
    # Ensure the line with your current vmbr0 IP correctly lists the FQDN and short hostname.
    # Ensure there are no other lines mapping different IPs to your hostname/FQDN.
    ```

3.  **Check Proxmox Service Status:**
    ```bash
    systemctl status pve-cluster pvedaemon pveproxy pvestatd
    ```
    If services are down or logs indicate resolution errors, manually run the update script (`sudo /usr/local/bin/update-proxmox-hosts.sh`) and/or restart the services.

4.  **Check Updater Service/Cron Logs:**
    *   Systemd: `journalctl -u update-proxmox-hosts.service`
    *   Cron (if configured as above): `cat /var/log/update-hosts.log`

```
