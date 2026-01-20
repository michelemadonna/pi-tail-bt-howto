#!/bin/bash
# Switch default route to specified interface (e.g., usb0, wlan0, bnep0) or auto-detect based on SSH source IP 
# Usage:
#   sudo -E ./switch-route.sh <interface>
#   OR automatically detect based on SSH source IP

IFACE="$1"

# Extract SSH client IP if available
if [ -n "$SSH_CLIENT" ]; then
    SSH_IP=$(echo $SSH_CLIENT | awk '{print $1}')
    echo "Detected SSH client IP: $SSH_IP"
else
    SSH_IP=""
fi

# If no interface provided, try to infer from SSH source IP
if [ -z "$IFACE" ] && [ -n "$SSH_IP" ]; then
    # Match by subnet
    if [[ "$SSH_IP" == 192.168.2.* ]]; then
        IFACE="usb0"
    elif [[ "$SSH_IP" == 192.168.1.* ]]; then
        IFACE="wlan0"
    elif [[ "$SSH_IP" == 172.20.10.* ]]; then
        IFACE="bnep0"
    else
        echo "Unknown SSH source network: $SSH_IP"
        exit 1
    fi

    echo "Auto-selected interface based on SSH IP: $IFACE"
fi

# If still no interface, error
if [ -z "$IFACE" ]; then
    echo "Usage: $0 <interface>"
    echo "Or run via SSH to auto-detect interface"
    exit 1
fi

# Check interface exists
if ! ip link show "$IFACE" > /dev/null 2>&1; then
    echo "Error: interface '$IFACE' not found"
    exit 1
fi

# Detect gateway
GATEWAY=$(ip route show dev "$IFACE" | awk '/default/ {print $3}')

if [ -z "$GATEWAY" ]; then
    IP=$(ip -4 addr show "$IFACE" | awk '/inet / {print $2}' | cut -d/ -f1)
    BASE=$(echo "$IP" | cut -d. -f1-3)
    GATEWAY="${BASE}.1"
fi

echo "Switching default route to: $IFACE via $GATEWAY"

# Remove old default route
sudo ip route del default 2>/dev/null

# Add new default route
sudo ip route add default via "$GATEWAY" dev "$IFACE"

echo "Done."
ip r
