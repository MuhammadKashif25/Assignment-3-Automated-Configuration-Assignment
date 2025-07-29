#!/usr/bin/env bash

# Ignore signals as required
trap '' TERM HUP INT

# Initialize variables
VERBOSE=false
HOST_NAME=""
IP_ADDRESS=""
HOSTENTRY_ARGS=()

# Function for verbose output
verbose_echo() {
    if [ "$VERBOSE" = true ]; then
        echo "$@"
    fi
}

# Function to log changes
log_change() {
    logger -t "configure-host" "$1"
    verbose_echo "$1"
}

# Function to run commands with or without sudo based on current user
run_cmd() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Function to detect the primary network interface
get_primary_interface() {
    # Get the interface used for the default route
    local interface=$(ip route | grep '^default' | head -n1 | awk '{print $5}')
    if [[ -n "$interface" ]]; then
        echo "$interface"
    else
        # Fallback: get first non-loopback interface
        ip link show | grep -E '^[0-9]+: ' | grep -v lo: | head -n1 | cut -d: -f2 | tr -d ' '
    fi
}

# Function to update hostname
update_hostname() {
    local current_hostname=$(hostname)
    
    if [ "$current_hostname" = "$HOST_NAME" ]; then
        verbose_echo "Hostname is already set to $HOST_NAME. No changes needed."
        return 0
    fi
    
    # Update /etc/hostname
    echo "$HOST_NAME" | run_cmd tee /etc/hostname > /dev/null
    
    # Update /etc/hosts for localhost entry
    if grep -q "127.0.1.1" /etc/hosts; then
        run_cmd sed -i "s/127.0.1.1.*/127.0.1.1\t$HOST_NAME/" /etc/hosts
    else
        echo -e "127.0.1.1\t$HOST_NAME" | run_cmd tee -a /etc/hosts > /dev/null
    fi
    
    # Apply hostname to running system
    run_cmd hostname "$HOST_NAME"
    
    log_change "Hostname changed from $current_hostname to $HOST_NAME"
    return 0
}

# Function to update IP address
update_ip() {
    local lan_interface=$(get_primary_interface)
    
    if [[ -z "$lan_interface" ]]; then
        echo "Error: Could not determine network interface" >&2
        return 1
    fi
    
    verbose_echo "Using network interface: $lan_interface"
    
    # Check current IP address
    local current_ip=$(ip addr show "$lan_interface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
    
    if [ "$current_ip" = "$IP_ADDRESS" ]; then
        verbose_echo "IP Address is already set to $IP_ADDRESS. No changes needed."
        return 0
    fi
    
    # Try netplan first (if it exists and is being used)
    if command -v netplan >/dev/null 2>&1 && [[ -d /etc/netplan ]] && [[ -n "$(ls -A /etc/netplan 2>/dev/null)" ]]; then
        verbose_echo "Using netplan for network configuration"
        update_ip_netplan "$lan_interface"
    else
        # Fallback to direct interface configuration
        verbose_echo "Using direct interface configuration"
        update_ip_direct "$lan_interface"
    fi
    
    # Update /etc/hosts for this host
    local hostname_to_use=${HOST_NAME:-$(hostname)}
    if [[ -n "$hostname_to_use" ]]; then
        update_host_entry "$hostname_to_use" "$IP_ADDRESS"
    fi
    
    log_change "IP address changed from ${current_ip:-'none'} to $IP_ADDRESS on interface $lan_interface"
    return 0
}

# Function to update IP using netplan
update_ip_netplan() {
    local interface="$1"
    local netplan_file=$(find /etc/netplan -name "*.yaml" 2>/dev/null | head -1)
    
    if [[ -z "$netplan_file" ]]; then
        # Create a basic netplan file
        netplan_file="/etc/netplan/01-netcfg.yaml"
        verbose_echo "Creating new netplan configuration file: $netplan_file"
        run_cmd tee "$netplan_file" > /dev/null << EOF
network:
  version: 2
  ethernets:
    $interface:
      addresses: [$IP_ADDRESS/24]
EOF
    else
        # Backup existing file
        run_cmd cp "$netplan_file" "${netplan_file}.bak"
        
        # Update existing configuration
        if grep -q "$interface" "$netplan_file"; then
            run_cmd sed -i "/^\s*$interface:/,/^\s*[a-zA-Z]/ s/addresses:.*/addresses: [$IP_ADDRESS\/24]/" "$netplan_file"
        else
            # Add interface configuration
            if grep -q "ethernets:" "$netplan_file"; then
                run_cmd sed -i "/ethernets:/a\\    $interface:\\n      addresses: [$IP_ADDRESS/24]" "$netplan_file"
            else
                run_cmd sed -i "/version: 2/a\\  ethernets:\\n    $interface:\\n      addresses: [$IP_ADDRESS/24]" "$netplan_file"
            fi
        fi
    fi
    
    # Apply configuration
    if ! run_cmd netplan apply 2>/dev/null; then
        verbose_echo "Warning: netplan apply failed, trying direct method"
        update_ip_direct "$interface"
    fi
}

# Function to update IP using direct interface commands
update_ip_direct() {
    local interface="$1"
    
    # Remove existing IP addresses from the interface
    run_cmd ip addr flush dev "$interface" 2>/dev/null || true
    
    # Add new IP address
    if ! run_cmd ip addr add "$IP_ADDRESS/24" dev "$interface" 2>/dev/null; then
        echo "Error: Failed to set IP address $IP_ADDRESS on interface $interface" >&2
        return 1
    fi
    
    # Bring interface up if it's down
    run_cmd ip link set "$interface" up 2>/dev/null || true
}

# Function to update host entry
update_host_entry() {
    local name="$1"
    local ip="$2"
    
    # Check if entry already exists with correct IP
    if grep -q "^$ip[[:space:]].*$name" /etc/hosts; then
        verbose_echo "Host entry for $name ($ip) already exists. No changes needed."
        return 0
    fi
    
    # Remove any existing entries for this hostname to avoid duplicates
    run_cmd sed -i "/[[:space:]]$name[[:space:]]/d; /[[:space:]]$name$/d" /etc/hosts
    
    # Add new entry
    echo -e "$ip\t$name" | run_cmd tee -a /etc/hosts > /dev/null
    
    log_change "Added/updated host entry: $name with IP $ip"
    return 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -verbose)
            VERBOSE=true
            shift
            ;;
        -name)
            if [[ -n "$2" ]]; then
                HOST_NAME="$2"
                shift 2
            else
                echo "Error: -name requires a hostname" >&2
                exit 1
            fi
            ;;
        -ip)
            if [[ -n "$2" ]]; then
                IP_ADDRESS="$2"
                shift 2
            else
                echo "Error: -ip requires an IP address" >&2
                exit 1
            fi
            ;;
        -hostentry)
            if [[ -n "$2" && -n "$3" ]]; then
                HOSTENTRY_ARGS+=("$2" "$3")
                shift 3
            else
                echo "Error: -hostentry requires a hostname and IP address" >&2
                exit 1
            fi
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Execute requested actions in logical order
EXIT_CODE=0

# 1. Update hostname first if requested
if [[ -n "$HOST_NAME" ]]; then
    update_hostname || EXIT_CODE=1
fi

# 2. Update IP address if requested
if [[ -n "$IP_ADDRESS" ]]; then
    update_ip || EXIT_CODE=1
fi

# 3. Process all hostentry requests
if [[ ${#HOSTENTRY_ARGS[@]} -gt 0 ]]; then
    for ((i=0; i<${#HOSTENTRY_ARGS[@]}; i+=2)); do
        name="${HOSTENTRY_ARGS[i]}"
        ip="${HOSTENTRY_ARGS[i+1]}"
        update_host_entry "$name" "$ip" || EXIT_CODE=1
    done
fi

# If no actions were specified and running in verbose mode
if [[ -z "$HOST_NAME" && -z "$IP_ADDRESS" && ${#HOSTENTRY_ARGS[@]} -eq 0 ]]; then
    if [ "$VERBOSE" = true ]; then
        echo "No actions specified. Use -name, -ip, or -hostentry."
    fi
fi

exit $EXIT_CODE
