#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Journald is the primary log. Set BLUETOOTH_PAN_LOGFILE to also append a
# traditional file, for example /var/log/bluetooth-pan.log.
LOGFILE="${BLUETOOTH_PAN_LOGFILE:-}"

LOCKFILE="${BLUETOOTH_PAN_LOCKFILE:-/run/auto-bt-pan.lock}"
RUNTIME_DIR="${BLUETOOTH_PAN_RUNTIME_DIR:-/run/auto-bt-pan}"

HELPER="${BLUEZ_PAN_HELPER:-/usr/local/libexec/bluez-pan-connect.py}"
DHCP_SCRIPT="${BLUEZ_PAN_DHCP_SCRIPT:-/usr/local/libexec/auto-bt-pan-dhclient-script}"

[[ -x "$HELPER" ]] || HELPER="$SCRIPT_DIR/bluez-pan-connect.py"
[[ -x "$DHCP_SCRIPT" ]] || DHCP_SCRIPT="$SCRIPT_DIR/auto-bt-pan-dhclient-script"

PAN_PROFILE="${BLUETOOTH_PAN_PROFILE:-nap}"
CONNECT_TIMEOUT="${BLUETOOTH_PAN_CONNECT_TIMEOUT:-20}"
DHCP_TIMEOUT="${BLUETOOTH_PAN_DHCP_TIMEOUT:-15}"
PAN_ROUTE_METRIC="${BLUETOOTH_PAN_ROUTE_METRIC:-50}"
STATIC_PREFIX="${BLUETOOTH_PAN_STATIC_PREFIX:-28}"

# List of devices in priority order.
# FORMAT: MAC|TYPE|STATIC_IP|GATEWAY|DNS
DEVICES=(
    "xx:xx:xx:xx:xx:xx|iPhone|172.20.10.2|172.20.10.1|1.1.1.1"
    "yy:yy:yy:yy:yy:yy|Android|192.168.44.2|192.168.44.1|1.1.1.1"
)

ACTIVE_MAC=""
ACTIVE_IFACE=""
ACTIVE_GATEWAY=""
WATCH_PID=""
DHCLIENT_PIDFILE=""
DHCLIENT_LEASEFILE=""
CLEANED_UP=no

declare -A RETRIES=()


log() {
    local message timestamp line

    message="$*"
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    line="$timestamp $message"

    printf '%s\n' "$line"
    logger -t bluetooth-monitor -- "$line" 2>/dev/null || true

    if [[ -n "$LOGFILE" ]]; then
        printf '%s\n' "$line" >> "$LOGFILE" 2>/dev/null || true
    fi
}


warn() {
    log "[WARN] $*"
}


die() {
    log "[ERROR] $*"
    exit 1
}


is_ipv4() {
    local value="$1"
    local octet
    local -a octets

    [[ "$value" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1

    local IFS=.
    read -r -a octets <<< "$value"
    [[ "${#octets[@]}" -eq 4 ]] || return 1

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        if ((10#$octet > 255)); then
            return 1
        fi
    done
}


is_mac() {
    [[ "$1" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
}


parse_device() {
    local entry="$1"
    local extra=""

    IFS='|' read -r MAC TYPE STATIC_IP GATEWAY DNS extra <<< "$entry"

    [[ -n "${MAC:-}" && -n "${TYPE:-}" && -n "${STATIC_IP:-}" &&
        -n "${GATEWAY:-}" && -n "${DNS:-}" && -z "$extra" ]]
}


validate_configuration() {
    local entry index=0

    [[ -x "$HELPER" ]] ||
        die "BlueZ helper is not executable: $HELPER"
    [[ -x "$DHCP_SCRIPT" ]] ||
        die "dhclient hook is not executable: $DHCP_SCRIPT"
    command -v flock >/dev/null 2>&1 || die "flock is required"
    command -v ip >/dev/null 2>&1 || die "iproute2 is required"
    command -v dhclient >/dev/null 2>&1 || die "dhclient is required"
    command -v timeout >/dev/null 2>&1 || die "timeout is required"

    [[ "$CONNECT_TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
        die "invalid connection timeout: $CONNECT_TIMEOUT"
    [[ "$DHCP_TIMEOUT" =~ ^[0-9]+$ ]] ||
        die "invalid DHCP timeout: $DHCP_TIMEOUT"
    [[ "$PAN_ROUTE_METRIC" =~ ^[0-9]+$ ]] ||
        die "invalid route metric: $PAN_ROUTE_METRIC"
    [[ "$STATIC_PREFIX" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] ||
        die "invalid static prefix: $STATIC_PREFIX"

    ((${#DEVICES[@]} > 0)) || die "no Bluetooth PAN devices configured"

    for entry in "${DEVICES[@]}"; do
        parse_device "$entry" ||
            die "invalid device entry at index $index"

        is_mac "$MAC" || die "invalid MAC for $TYPE: $MAC"
        is_ipv4 "$STATIC_IP" || die "invalid static IP for $TYPE: $STATIC_IP"
        is_ipv4 "$GATEWAY" || die "invalid gateway for $TYPE: $GATEWAY"
        is_ipv4 "$DNS" || die "invalid DNS address for $TYPE: $DNS"
        ((index += 1))
    done
}


retry_delay() {
    local mac="$1"
    local count="${RETRIES[$mac]:-0}"
    local delay

    case "$count" in
        0) delay=2 ;;
        1) delay=4 ;;
        2) delay=8 ;;
        3) delay=16 ;;
        4) delay=30 ;;
        *) delay=60 ;;
    esac

    RETRIES[$mac]=$((count + 1))
    printf '%s\n' "$delay"
}


reset_retry() {
    RETRIES["$1"]=0
}


stop_watch() {
    if [[ -n "$WATCH_PID" ]]; then
        kill "$WATCH_PID" 2>/dev/null || true
        wait "$WATCH_PID" 2>/dev/null || true
        WATCH_PID=""
    fi
}


cleanup_active() {
    local iface="$ACTIVE_IFACE"
    local mac="$ACTIVE_MAC"

    stop_watch

    if [[ -n "$DHCLIENT_PIDFILE" && -n "$iface" ]]; then
        dhclient -r -pf "$DHCLIENT_PIDFILE" "$iface" >/dev/null 2>&1 || true
    fi

    if [[ -n "$iface" ]]; then
        if command -v resolvectl >/dev/null 2>&1; then
            resolvectl revert "$iface" >/dev/null 2>&1 || true
        fi

        ip route del default \
            via "$ACTIVE_GATEWAY" \
            dev "$iface" \
            metric "$PAN_ROUTE_METRIC" \
            >/dev/null 2>&1 || true

        ip -4 addr flush dev "$iface" scope global >/dev/null 2>&1 || true
    fi

    if [[ -n "$mac" ]]; then
        "$HELPER" disconnect "$mac" >/dev/null 2>&1 || true
    fi

    if [[ -n "$DHCLIENT_PIDFILE" ]]; then
        rm -f -- "$DHCLIENT_PIDFILE"
    fi
    if [[ -n "$DHCLIENT_LEASEFILE" ]]; then
        rm -f -- "$DHCLIENT_LEASEFILE"
    fi

    ACTIVE_MAC=""
    ACTIVE_IFACE=""
    ACTIVE_GATEWAY=""
    DHCLIENT_PIDFILE=""
    DHCLIENT_LEASEFILE=""
}


on_exit() {
    [[ "$CLEANED_UP" == yes ]] && return 0
    CLEANED_UP=yes
    cleanup_active
}


on_signal() {
    log "[INFO] Stop richiesto"
    exit 0
}


wait_for_interface() {
    local iface="$1"
    local attempt

    for ((attempt = 1; attempt <= 40; attempt++)); do
        if ip link show dev "$iface" >/dev/null 2>&1; then
            ip link set dev "$iface" up >/dev/null 2>&1 || true
            return 0
        fi
        sleep 0.25
    done

    return 1
}


configure_ip() {
    local iface="$1"
    local static_ip="$2"
    local gateway="$3"
    local dns="$4"
    local pid_suffix
    local ip_address

    pid_suffix="${iface//[^[:alnum:]_.-]/_}"
    DHCLIENT_PIDFILE="$RUNTIME_DIR/dhclient-${pid_suffix}.pid"
    DHCLIENT_LEASEFILE="$RUNTIME_DIR/dhclient-${pid_suffix}.lease"

    ip -4 addr flush dev "$iface" scope global >/dev/null 2>&1 || true
    ip link set dev "$iface" up

    if timeout "$DHCP_TIMEOUT" dhclient \
        -1 \
        -4 \
        -q \
        -pf "$DHCLIENT_PIDFILE" \
        -lf "$DHCLIENT_LEASEFILE" \
        -sf "$DHCP_SCRIPT" \
        "$iface"; then
        ip_address="$(ip -4 -o addr show dev "$iface" scope global | awk 'NR == 1 { print $4 }')"
        if [[ -n "$ip_address" ]]; then
            log "[INFO] DHCP configurato su $iface: $ip_address"
        else
            warn "DHCP terminato senza un indirizzo su $iface"
            ip -4 addr add "$static_ip/$STATIC_PREFIX" dev "$iface"
        fi
    else
        warn "DHCP fallito su $iface; uso configurazione statica $static_ip/$STATIC_PREFIX"
        ip -4 addr replace "$static_ip/$STATIC_PREFIX" dev "$iface"
    fi

    ip route replace default \
        via "$gateway" \
        dev "$iface" \
        metric "$PAN_ROUTE_METRIC"

    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl dns "$iface" "$dns" >/dev/null 2>&1 ||
            warn "impossibile configurare DNS su $iface con resolvectl"
        resolvectl domain "$iface" '~.' >/dev/null 2>&1 ||
            warn "impossibile assegnare il dominio DNS globale a $iface"
    else
        log "[INFO] resolvectl non disponibile: /etc/resolv.conf non viene modificato"
    fi

    ping -I "$iface" -c 1 -W 2 "$gateway" >/dev/null 2>&1
}


attempt_device() {
    local entry="$1"
    local iface
    local delay

    parse_device "$entry" || return 1

    log "[INFO] Provo $TYPE ($MAC) in ordine di priorità"

    if ! iface="$("$HELPER" connect \
        "$MAC" \
        --profile "$PAN_PROFILE" \
        --timeout "$CONNECT_TIMEOUT")"; then
        delay="$(retry_delay "$MAC")"
        warn "connessione PAN fallita per $TYPE; nuovo tentativo tra ${delay}s"
        sleep "$delay"
        return 1
    fi

    iface="${iface##*$'\n'}"
    [[ "$iface" =~ ^[[:alnum:]_.-]+$ ]] || {
        warn "BlueZ ha restituito un nome interfaccia non valido: $iface"
        "$HELPER" disconnect "$MAC" >/dev/null 2>&1 || true
        return 1
    }

    if ! wait_for_interface "$iface"; then
        warn "interfaccia PAN non disponibile: $iface"
        "$HELPER" disconnect "$MAC" >/dev/null 2>&1 || true
        return 1
    fi

    if ! configure_ip "$iface" "$STATIC_IP" "$GATEWAY" "$DNS"; then
        warn "gateway $GATEWAY non raggiungibile su $iface"
        ACTIVE_MAC="$MAC"
        ACTIVE_IFACE="$iface"
        ACTIVE_GATEWAY="$GATEWAY"
        cleanup_active
        delay="$(retry_delay "$MAC")"
        sleep "$delay"
        return 1
    fi

    ACTIVE_MAC="$MAC"
    ACTIVE_IFACE="$iface"
    ACTIVE_GATEWAY="$GATEWAY"
    reset_retry "$MAC"

    log "[INFO] PAN attiva: $TYPE su $iface, gateway $GATEWAY"

    "$HELPER" watch \
        "$MAC" \
        --profile "$PAN_PROFILE" \
        --interface "$iface" &
    WATCH_PID=$!

    return 0
}


monitor_active() {
    while [[ -n "$WATCH_PID" ]] && kill -0 "$WATCH_PID" 2>/dev/null; do
        if ! ip link show dev "$ACTIVE_IFACE" >/dev/null 2>&1; then
            warn "interfaccia $ACTIVE_IFACE scomparsa"
            return 1
        fi

        sleep 1
    done

    return 1
}


mkdir -p -- "$RUNTIME_DIR"
exec 9>"$LOCKFILE"
flock -n 9 || exit 0

trap on_exit EXIT
trap on_signal INT TERM

validate_configuration
log "[INFO] Supervisore Bluetooth PAN avviato"

while :; do
    connected=no

    for entry in "${DEVICES[@]}"; do
        if attempt_device "$entry"; then
            connected=yes
            monitor_active || true
            log "[WARN] Connessione PAN persa; pulizia e failover"
            cleanup_active
            break
        fi
    done

    if [[ "$connected" == no ]]; then
        sleep 1
    fi
done
