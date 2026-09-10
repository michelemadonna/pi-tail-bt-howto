#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_SOURCE_BASE="https://raw.githubusercontent.com/michelemadonna/pi-tail-bt-howto/main"
SOURCE_BASE="${PI_TAIL_SOURCE_BASE:-$DEFAULT_SOURCE_BASE}"
DEVICE_SPEC="${PI_TAIL_DEVICE:-}"
INSTALL_PACKAGES=yes
START_SERVICE=yes

TMP_DIR=""


usage() {
    cat <<'EOF'
Usage:
  curl -fsSL https://raw.githubusercontent.com/michelemadonna/pi-tail-bt-howto/main/install.sh | bash

Optional environment variables:
  PI_TAIL_DEVICE='MAC|TYPE|STATIC_IP|GATEWAY|DNS'
  PI_TAIL_SOURCE_BASE='https://raw.githubusercontent.com/.../main'

Optional arguments:
  --device SPEC       Configure one PAN device without prompting
  --no-packages       Do not install Debian packages
  --no-start          Install files but do not enable/start the service
  --source-base URL   Download project files from URL
  -h, --help          Show this help
EOF
}


die() {
    printf '[pi-tail-bt-howto] ERROR: %s\n' "$*" >&2
    exit 1
}


cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
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


validate_device() {
    local extra=""
    local mac type static_ip gateway dns

    IFS='|' read -r mac type static_ip gateway dns extra <<< "$DEVICE_SPEC"

    [[ -n "${mac:-}" && -n "${type:-}" && -n "${static_ip:-}" &&
        -n "${gateway:-}" && -n "${dns:-}" && -z "$extra" ]] ||
        die "device must use MAC|TYPE|STATIC_IP|GATEWAY|DNS"
    [[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] ||
        die "invalid Bluetooth MAC: $mac"
    local type_regex='^[[:alnum:]_. -]+$'
    [[ "$type" =~ $type_regex ]] ||
        die "invalid device name: $type"
    is_ipv4 "$static_ip" || die "invalid static IP: $static_ip"
    is_ipv4 "$gateway" || die "invalid gateway: $gateway"
    is_ipv4 "$dns" || die "invalid DNS address: $dns"
}


prompt_for_device() {
    [[ -n "$DEVICE_SPEC" ]] && return 0
    [[ -r /dev/tty && -w /dev/tty ]] || return 0

    printf '\nBluetooth PAN device (MAC|TYPE|STATIC_IP|GATEWAY|DNS)\n' >/dev/tty
    printf 'Example: AA:BB:CC:DD:EE:FF|iPhone|172.20.10.2|172.20.10.1|1.1.1.1\n' >/dev/tty
    printf 'Leave empty to install without starting the service.\n> ' >/dev/tty
    IFS= read -r DEVICE_SPEC </dev/tty || true

    [[ -z "$DEVICE_SPEC" ]] || validate_device
}


parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --device)
                (($# >= 2)) || die "--device requires a value"
                DEVICE_SPEC="$2"
                shift 2
                ;;
            --no-packages)
                INSTALL_PACKAGES=no
                shift
                ;;
            --no-start)
                START_SERVICE=no
                shift
                ;;
            --source-base)
                (($# >= 2)) || die "--source-base requires a URL"
                SOURCE_BASE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done
}


download_file() {
    local name="$1"
    local url="${SOURCE_BASE%/}/$name"

    printf '[pi-tail-bt-howto] Downloading %s\n' "$url"
    curl --fail --silent --show-error --location \
        --retry 3 --retry-delay 1 \
        "$url" \
        --output "$TMP_DIR/$name"
    [[ -s "$TMP_DIR/$name" ]] || die "downloaded file is empty: $name"
}


write_config() {
    if [[ -n "$DEVICE_SPEC" ]]; then
        validate_device
        {
            printf '# Managed by pi-tail-bt-howto/install.sh\n'
            printf 'DEVICES=(\n'
            printf '    %q\n' "$DEVICE_SPEC"
            printf ')\n'
        } > "$TMP_DIR/auto-bt-pan.conf"
    else
        cat > "$TMP_DIR/auto-bt-pan.conf" <<'EOF'
# Configure at least one device before starting auto-bt-pan.service.
DEVICES=()
EOF
    fi
}


sudo_cmd() {
    sudo -p '[pi-tail-bt-howto] Password required to install the Bluetooth PAN service: ' "$@"
}


install_files() {
    printf '\n[pi-tail-bt-howto] Administrator privileges are now required to install packages, system files, and the systemd unit.\n'

    if [[ "$INSTALL_PACKAGES" == yes ]]; then
        command -v apt-get >/dev/null 2>&1 || die "apt-get is required on the target system"
        sudo_cmd apt-get update
        sudo_cmd apt-get install -y \
            bluez \
            bluez-tools \
            bluetooth \
            python3-dbus \
            python3-gi \
            isc-dhcp-client
    fi

    sudo_cmd install -D -m 755 "$TMP_DIR/auto-bt-pan.sh" \
        /usr/local/bin/auto-bt-pan.sh
    sudo_cmd install -D -m 755 "$TMP_DIR/bluez-pan-connect.py" \
        /usr/local/libexec/bluez-pan-connect.py
    sudo_cmd install -D -m 755 "$TMP_DIR/auto-bt-pan-dhclient-script" \
        /usr/local/libexec/auto-bt-pan-dhclient-script
    sudo_cmd install -D -m 644 "$TMP_DIR/auto-bt-pan.service" \
        /etc/systemd/system/auto-bt-pan.service
    sudo_cmd install -D -m 644 "$TMP_DIR/auto-bt-pan.conf" \
        /etc/default/auto-bt-pan
}


main() {
    [[ "$(id -u)" -ne 0 ]] ||
        die "do not run this installer as root; it uses sudo only for installation"
    command -v curl >/dev/null 2>&1 || die "curl is required"
    command -v bash >/dev/null 2>&1 || die "bash is required"

    parse_arguments "$@"
    prompt_for_device

    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pi-tail-bt-howto.XXXXXX")"
    trap cleanup EXIT

    for file in \
        auto-bt-pan.sh \
        bluez-pan-connect.py \
        auto-bt-pan-dhclient-script \
        auto-bt-pan.service; do
        download_file "$file"
    done

    write_config

    bash -n "$TMP_DIR/auto-bt-pan.sh"
    sh -n "$TMP_DIR/auto-bt-pan-dhclient-script"

    if [[ "$INSTALL_PACKAGES" == yes ]]; then
        install_files
    else
        command -v python3 >/dev/null 2>&1 || die "python3 is required with --no-packages"
        printf '\n[pi-tail-bt-howto] Administrator privileges are now required to install the downloaded files.\n'
        sudo_cmd install -D -m 755 "$TMP_DIR/auto-bt-pan.sh" /usr/local/bin/auto-bt-pan.sh
        sudo_cmd install -D -m 755 "$TMP_DIR/bluez-pan-connect.py" /usr/local/libexec/bluez-pan-connect.py
        sudo_cmd install -D -m 755 "$TMP_DIR/auto-bt-pan-dhclient-script" /usr/local/libexec/auto-bt-pan-dhclient-script
        sudo_cmd install -D -m 644 "$TMP_DIR/auto-bt-pan.service" /etc/systemd/system/auto-bt-pan.service
        sudo_cmd install -D -m 644 "$TMP_DIR/auto-bt-pan.conf" /etc/default/auto-bt-pan
    fi

    sudo_cmd systemctl daemon-reload

    if [[ -n "$DEVICE_SPEC" && "$START_SERVICE" == yes ]]; then
        sudo_cmd systemctl enable --now auto-bt-pan.service
        printf '\n[pi-tail-bt-howto] Installed and started auto-bt-pan.service.\n'
        printf '[pi-tail-bt-howto] Logs: sudo journalctl -fu auto-bt-pan.service\n'
    else
        printf '\n[pi-tail-bt-howto] Installed without starting the service.\n'
        printf '[pi-tail-bt-howto] Edit /etc/default/auto-bt-pan, then run:\n'
        printf '  sudo systemctl enable --now auto-bt-pan.service\n'
    fi
}


main "$@"
