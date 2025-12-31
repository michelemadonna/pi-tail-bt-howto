#!/bin/bash

LOGFILE="/var/log/bluetooth-pan.log"

# List of devices in priority order
# FORMAT: MAC|TYPE|STATIC_IP|GATEWAY|DNS
DEVICES=(
"xx:xx:xx:xx:xx:xx|iPhone|172.20.10.2|172.20.10.1|1.1.1.1"
"yy:yy:yy:yy:yy:yy|Android|192.168.44.2|192.168.44.1|1.1.1.1"
)

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOGFILE" | logger -t bluetooth-monitor
}

# Function to check connectivity with the gateway
check_connection() {
    local gateway=$1
    ping -c 1 "$gateway" > /dev/null 2>&1
    return $?
}
# Infinite loop
while true; do
    
    log "================================================================================================"
    ACTIVE_DEVICE=""
    REACHABLE_DEVICES=()

    for entry in "${DEVICES[@]}"; do
        IFS="|" read -r MAC TYPE STATIC_IP GATEWAY DNS <<< "$entry"

        # Attempt l2ping
        l2ping -c 1 "$MAC" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            log "[INFO] $TYPE ($MAC) è in portata Bluetooth."
            REACHABLE_DEVICES+=("$entry")
            # Check gateway connectivity
            if check_connection "$GATEWAY"; then
                log "[INFO] Connessione al gateway $GATEWAY riuscita per $TYPE."
                ACTIVE_DEVICE=$TYPE
                log "[INFO] ACTIVE_DEVICE impostato a $ACTIVE_DEVICE"
            fi
        else
            log "[WARN] $TYPE ($MAC) non è in portata Bluetooth."
        fi
    done

    # Check if no active device was found
    if [ "$ACTIVE_DEVICE" == "" ]; then
        log "[INFO] Nessun dispositivo Bluetooth attivo connesso al gateway."
		
        for entry in "${REACHABLE_DEVICES[@]}"; do 
            IFS="|" read -r MAC TYPE STATIC_IP GATEWAY DNS <<< "$entry"
	    
            
                log "[INFO] $TYPE ($MAC) è in portata Bluetooth. Provo a configurarlo"

                log "[INFO] Connecting PAN to $MAC..."
                killall bt-network /dev/null 2>&1
                bt-network -c $MAC nap &
                BTNET_PID=$!
                sleep 2
		
		if ip link show bnep0 2>/dev/null | grep -q "bnep0"; then
                	log "[INFO] Configuring IP for $TYPE"
                	dhclient bnep0
                	IP=$(ip addr show bnep0 | grep "inet " | awk '{print $2}' | cut -d/ -f1)

                	if [ -z "$IP" ]; then
                    		log "[WARN] DHCP failed, setting static IP for $TYPE"
                    		ip addr flush dev bnep0

                    		ip addr add $STATIC_IP/28 dev bnep0
                    		echo "nameserver $DNS" | sudo tee /etc/resolv.conf
                	fi

			ip route del default 
			ip route add default via $GATEWAY dev bnep0
                
			log "[INFO] PAN connection active on bnep0 ($TYPE)"
			break
	     	fi
        done
    fi

    sleep 10
done



