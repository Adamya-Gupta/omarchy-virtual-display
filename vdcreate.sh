#!/bin/bash

set -u

MONITOR_NAME="virtual_display"

DEFAULT_RESOLUTION="1366x768"
DEFAULT_SIDE="right"
DEFAULT_VNC_MODE="local"

VNC_PORT="5900"
VNC_USERNAME="virtual-display"

# Secure default: VNC is reachable only from this machine.
VNC_LOCAL_ADDRESS="127.0.0.1"

# Explicitly selected Network mode.
VNC_NETWORK_ADDRESS="0.0.0.0"


# ─────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vdcreate"

ACTIVE_STATE_FILE="$STATE_DIR/active"
PREFERRED_SIDE_FILE="$STATE_DIR/side"
PREFERRED_VNC_MODE_FILE="$STATE_DIR/vnc-mode"

VNC_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-virtual-display/wayvnc"

VNC_CONFIG="$VNC_DIR/config"
VNC_PASSWORD_FILE="$VNC_DIR/password"
VNC_KEY_FILE="$VNC_DIR/tls_key.pem"
VNC_CERT_FILE="$VNC_DIR/tls_cert.pem"

mkdir -p "$STATE_DIR"


# ─────────────────────────────────────────────
# Dependencies
# ─────────────────────────────────────────────

check_dependencies() {
    local missing=()

    command -v jq >/dev/null 2>&1 ||
        missing+=("jq")

    command -v wayvnc >/dev/null 2>&1 ||
        missing+=("wayvnc")

    if (( ${#missing[@]} > 0 )); then
        notify-send \
            "VDCreate" \
            "Missing dependencies: ${missing[*]}"

        return 1
    fi

    return 0
}

check_network_dependencies() {
    if ! command -v openssl >/dev/null 2>&1; then
        notify-send \
            "VDCreate" \
            "Network access requires openssl."

        return 1
    fi

    return 0
}


# ─────────────────────────────────────────────
# Preferred side
# ─────────────────────────────────────────────

get_preferred_side() {
    if [[ -f "$PREFERRED_SIDE_FILE" ]]; then
        local side
        side="$(cat "$PREFERRED_SIDE_FILE")"

        if [[ "$side" == "left" || "$side" == "right" ]]; then
            echo "$side"
            return 0
        fi
    fi

    echo "$DEFAULT_SIDE"
}

set_preferred_side() {
    local side="$1"

    if [[ "$side" != "left" && "$side" != "right" ]]; then
        echo "Invalid side: $side" >&2
        return 1
    fi

    printf '%s\n' "$side" > "$PREFERRED_SIDE_FILE"
}


# ─────────────────────────────────────────────
# Preferred VNC mode
# ─────────────────────────────────────────────

get_preferred_vnc_mode() {
    if [[ -f "$PREFERRED_VNC_MODE_FILE" ]]; then
        local mode
        mode="$(cat "$PREFERRED_VNC_MODE_FILE")"

        if [[ "$mode" == "local" || "$mode" == "network" ]]; then
            echo "$mode"
            return 0
        fi

        # Migrate the old preference automatically.
        if [[ "$mode" == "lan" ]]; then
            printf '%s\n' "network" > "$PREFERRED_VNC_MODE_FILE"
            echo "network"
            return 0
        fi
    fi

    echo "$DEFAULT_VNC_MODE"
}

set_preferred_vnc_mode() {
    local mode="$1"

    if [[ "$mode" != "local" && "$mode" != "network" ]]; then
        echo "Invalid VNC mode: $mode" >&2
        return 1
    fi

    printf '%s\n' "$mode" > "$PREFERRED_VNC_MODE_FILE"
}


# ─────────────────────────────────────────────
# Virtual display state
# ─────────────────────────────────────────────

is_virtual_display_active() {
    hyprctl monitors -j 2>/dev/null |
        jq -e --arg name "$MONITOR_NAME" \
        'any(.[]; .name == $name and .disabled == false)' \
        >/dev/null 2>&1
}


# ─────────────────────────────────────────────
# Main/system monitor
# ─────────────────────────────────────────────

get_main_monitor() {
    local monitors
    local monitor

    monitors="$(hyprctl monitors -j 2>/dev/null)"

    if [[ -z "$monitors" ]]; then
        return 1
    fi

    # Prefer an internal laptop display.
    monitor="$(
        jq -c '
            [
                .[]
                | select(.disabled == false)
                | select(.name | test("^(eDP|LVDS|DSI)-"))
            ][0]
            // empty
        ' <<< "$monitors"
    )"

    if [[ -n "$monitor" ]]; then
        echo "$monitor"
        return 0
    fi

    # Fall back to the focused monitor.
    monitor="$(
        jq -c '
            [
                .[]
                | select(.disabled == false)
                | select(.focused == true)
            ][0]
            // empty
        ' <<< "$monitors"
    )"

    if [[ -n "$monitor" ]]; then
        echo "$monitor"
        return 0
    fi

    # Last resort: first active monitor.
    jq -c '
        [
            .[]
            | select(.disabled == false)
        ][0]
        // empty
    ' <<< "$monitors"
}


# ─────────────────────────────────────────────
# Logical monitor width
# ─────────────────────────────────────────────

get_logical_width() {
    local width="$1"
    local height="$2"
    local scale="$3"
    local transform="$4"

    local effective_width

    case "$transform" in
        1|3|5|7)
            effective_width="$height"
            ;;
        *)
            effective_width="$width"
            ;;
    esac

    awk \
        -v value="$effective_width" \
        -v scale="$scale" \
        'BEGIN {
            printf "%.0f", value / scale
        }'
}


# ─────────────────────────────────────────────
# Network addresses
#
# All active non-loopback IPv4 addresses are returned.
# This allows the same VNC listener/certificate to be used
# through Wi-Fi and Ethernet at the same time.
# ─────────────────────────────────────────────

get_network_addresses() {
    ip -4 -o addr show up 2>/dev/null |
        awk '
            {
                interface = $2
                address = $4

                sub(/\/.*/, "", address)

                if (interface != "lo" && address != "127.0.0.1")
                    print address
            }
        ' |
        sort -u
}

get_network_addresses_csv() {
    local addresses

    addresses="$(get_network_addresses)"

    if [[ -z "$addresses" ]]; then
        echo ""
        return 0
    fi

    tr '\n' ',' <<< "$addresses" |
        sed 's/,$//'
}

get_primary_network_address() {
    local ip

    # Prefer the source address for the default route.
    ip="$(
        ip route get 1.1.1.1 2>/dev/null |
            awk '
                /src/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "src") {
                            print $(i + 1)
                            exit
                        }
                    }
                }
            '
    )"

    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi

    # Prefer a conventional private network address.
    ip="$(
        get_network_addresses |
            awk '
                $0 ~ /^10\./ ||
                $0 ~ /^192\.168\./ ||
                $0 ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./ {
                    print
                    exit
                }
            '
    )"

    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi

    # Last resort: first active non-loopback address.
    get_network_addresses | head -n 1
}


# ─────────────────────────────────────────────
# Generate VNC password
# ─────────────────────────────────────────────

generate_vnc_password() {
    local password

    password="$(
        LC_ALL=C \
        tr -dc 'A-Za-z0-9' \
        < /dev/urandom |
        head -c 20
    )"

    if [[ -z "$password" ]]; then
        return 1
    fi

    printf '%s\n' "$password"
}


# ─────────────────────────────────────────────
# TLS certificate helpers
# ─────────────────────────────────────────────

get_certificate_ip_addresses() {
    if [[ ! -s "$VNC_CERT_FILE" ]]; then
        return 1
    fi

    openssl x509 \
        -in "$VNC_CERT_FILE" \
        -noout \
        -ext subjectAltName 2>/dev/null |
        grep -oE 'IP Address:[0-9.]+' |
        cut -d: -f2 |
        sort -u
}

certificate_needs_refresh() {
    local current_addresses
    local certificate_addresses

    [[ ! -s "$VNC_KEY_FILE" ||
       ! -s "$VNC_CERT_FILE" ]] &&
        return 0

    current_addresses="$(
        get_network_addresses
    )"

    certificate_addresses="$(
        get_certificate_ip_addresses
    )"

    if [[ "$current_addresses" != "$certificate_addresses" ]]; then
        return 0
    fi

    return 1
}


generate_tls_certificate() {
    local san
    local hostname
    local ip
    local addresses

    hostname="$(
        hostname -s 2>/dev/null ||
        echo "virtual-display"
    )"

    san="DNS:localhost,IP:127.0.0.1,DNS:${hostname}"

    addresses="$(
        get_network_addresses
    )"

    while read -r ip; do
        [[ -z "$ip" ]] && continue
        san="${san},IP:${ip}"
    done <<< "$addresses"

    mkdir -p "$VNC_DIR"
    chmod 700 "$VNC_DIR"

    local temp_key
    local temp_cert

    temp_key="$VNC_DIR/.tls_key.tmp"
    temp_cert="$VNC_DIR/.tls_cert.tmp"

    rm -f "$temp_key" "$temp_cert"

    umask 077

    if ! openssl req \
        -x509 \
        -newkey ec \
        -pkeyopt ec_paramgen_curve:secp384r1 \
        -sha384 \
        -days 3650 \
        -nodes \
        -keyout "$temp_key" \
        -out "$temp_cert" \
        -subj "/CN=${hostname}" \
        -addext "subjectAltName=${san}" \
        >/dev/null 2>&1
    then
        rm -f "$temp_key" "$temp_cert"
        return 1
    fi

    chmod 600 "$temp_key"
    chmod 644 "$temp_cert"

    mv "$temp_key" "$VNC_KEY_FILE"
    mv "$temp_cert" "$VNC_CERT_FILE"

    return 0
}


# ─────────────────────────────────────────────
# WayVNC network configuration
# ─────────────────────────────────────────────

write_network_config() {
    local password="$1"
    local temp_config

    mkdir -p "$VNC_DIR"
    chmod 700 "$VNC_DIR"

    temp_config="$VNC_DIR/.config.tmp"

    umask 077

    cat > "$temp_config" <<EOF
use_relative_paths=true
address=0.0.0.0
port=${VNC_PORT}
enable_auth=true
username=${VNC_USERNAME}
password=${password}
private_key_file=$(basename "$VNC_KEY_FILE")
certificate_file=$(basename "$VNC_CERT_FILE")
EOF

    chmod 600 "$temp_config"

    mv "$temp_config" "$VNC_CONFIG"
    chmod 600 "$VNC_CONFIG"
}


# ─────────────────────────────────────────────
# Ensure Network Access credentials/config
# ─────────────────────────────────────────────

ensure_network_credentials() {
    if ! check_network_dependencies; then
        return 1
    fi

    mkdir -p "$VNC_DIR"
    chmod 700 "$VNC_DIR"

    # Generate the password once.
    if [[ ! -s "$VNC_PASSWORD_FILE" ]]; then
        local password

        password="$(generate_vnc_password)"

        if [[ -z "$password" ]]; then
            notify-send \
                "VDCreate" \
                "Failed to generate VNC password."

            return 1
        fi

        umask 077

        printf '%s\n' "$password" > "$VNC_PASSWORD_FILE"
        chmod 600 "$VNC_PASSWORD_FILE"
    fi

    # Keep the certificate when the address set hasn't changed.
    # Regenerate it automatically when Wi-Fi/Ethernet addresses change.
    if certificate_needs_refresh; then
        if ! generate_tls_certificate; then
            notify-send \
                "VDCreate" \
                "Failed to generate TLS certificate."

            return 1
        fi
    fi

    local password

    password="$(cat "$VNC_PASSWORD_FILE")"

    write_network_config "$password"

    return 0
}


# ─────────────────────────────────────────────
# Regenerate VNC password only
# ─────────────────────────────────────────────

regenerate_vnc_password() {
    if ! ensure_network_credentials; then
        return 1
    fi

    local password

    password="$(generate_vnc_password)"

    if [[ -z "$password" ]]; then
        return 1
    fi

    umask 077

    printf '%s\n' "$password" > "$VNC_PASSWORD_FILE"
    chmod 600 "$VNC_PASSWORD_FILE"

    # This rewrites only the password while reusing the current TLS
    # certificate/key (unless the address set itself has changed).
    write_network_config "$password"

    return 0
}


# ─────────────────────────────────────────────
# Stop display
# ─────────────────────────────────────────────

stop_display() {
    notify-send \
        "VDCreate" \
        "Turning off extended display..."

    killall wayvnc 2>/dev/null || true

    hyprctl output remove \
        "$MONITOR_NAME" \
        2>/dev/null || true

    rm -f "$ACTIVE_STATE_FILE"
}


# ─────────────────────────────────────────────
# Read active state
# ─────────────────────────────────────────────

read_active_state() {
    if [[ ! -f "$ACTIVE_STATE_FILE" ]]; then
        return 1
    fi

    local state

    state="$(cat "$ACTIVE_STATE_FILE")"

    IFS='|' read -r \
        ACTIVE_RESOLUTION \
        ACTIVE_SIDE \
        ACTIVE_VNC_MODE \
        <<< "$state"

    # Migrate old active-state mode.
    if [[ "$ACTIVE_VNC_MODE" == "lan" ]]; then
        ACTIVE_VNC_MODE="network"
    fi

    return 0
}


# ─────────────────────────────────────────────
# Start display
# ─────────────────────────────────────────────

start_display() {
    local resolution="$1"
    local side="$2"
    local vnc_mode="$3"

    if ! check_dependencies; then
        return 1
    fi

    if [[ "$side" != "left" &&
          "$side" != "right" ]]; then
        side="$DEFAULT_SIDE"
    fi

    # Accept the old "lan" value once for compatibility,
    # but always use "network" internally.
    if [[ "$vnc_mode" == "lan" ]]; then
        vnc_mode="network"
    fi

    if [[ "$vnc_mode" != "local" &&
          "$vnc_mode" != "network" ]]; then
        vnc_mode="$DEFAULT_VNC_MODE"
    fi

    # Network security setup happens BEFORE changing the display.
    if [[ "$vnc_mode" == "network" ]]; then
        if ! ensure_network_credentials; then
            return 1
        fi
    fi


    # ─────────────────────────────────────────
    # Determine main monitor
    # ─────────────────────────────────────────

    local main_monitor

    main_monitor="$(get_main_monitor)"

    if [[ -z "$main_monitor" ]]; then
        notify-send \
            "VDCreate" \
            "Could not determine the main display."

        return 1
    fi


    local main_name
    local main_width
    local main_height
    local main_scale
    local main_transform

    main_name="$(jq -r '.name' <<< "$main_monitor")"
    main_width="$(jq -r '.width' <<< "$main_monitor")"
    main_height="$(jq -r '.height' <<< "$main_monitor")"
    main_scale="$(jq -r '.scale' <<< "$main_monitor")"
    main_transform="$(jq -r '.transform' <<< "$main_monitor")"


    # ─────────────────────────────────────────
    # Calculate logical width
    # ─────────────────────────────────────────

    local main_logical_width

    main_logical_width="$(
        get_logical_width \
            "$main_width" \
            "$main_height" \
            "$main_scale" \
            "$main_transform"
    )"


    local virtual_width
    virtual_width="${resolution%x*}"


    # ─────────────────────────────────────────
    # Calculate virtual position
    # ─────────────────────────────────────────

    local virtual_x

    if [[ "$side" == "right" ]]; then
        virtual_x="$main_logical_width"
    else
        virtual_x="-$virtual_width"
    fi


    # ─────────────────────────────────────────
    # Notify
    # ─────────────────────────────────────────

    if [[ "$vnc_mode" == "network" ]]; then
        notify-send \
            "VDCreate" \
            "Starting ${resolution} on ${side} with Network access."
    else
        notify-send \
            "VDCreate" \
            "Starting ${resolution} on ${side} (Local + SSH)."
    fi


    # ─────────────────────────────────────────
    # Clean previous instance
    # ─────────────────────────────────────────

    killall wayvnc 2>/dev/null || true

    hyprctl output remove \
        "$MONITOR_NAME" \
        2>/dev/null || true

    sleep 0.2


    # ─────────────────────────────────────────
    # Keep main display fixed at 0x0
    # ─────────────────────────────────────────

    if ! hyprctl eval \
        "hl.monitor({
            output = '$main_name',
            position = '0x0',
            scale = $main_scale,
            transform = $main_transform
        })"; then

        notify-send \
            "VDCreate" \
            "Failed to configure main display."

        return 1
    fi


    # ─────────────────────────────────────────
    # Create headless monitor
    # ─────────────────────────────────────────

    if ! hyprctl output create headless \
        "$MONITOR_NAME"; then

        notify-send \
            "VDCreate" \
            "Failed to create virtual display."

        return 1
    fi

    sleep 0.5


    # ─────────────────────────────────────────
    # Configure virtual display
    # ─────────────────────────────────────────

    if ! hyprctl eval \
        "hl.monitor({
            output = '$MONITOR_NAME',
            mode = '${resolution}@60',
            position = '${virtual_x}x0',
            scale = 1
        })"; then

        notify-send \
            "VDCreate" \
            "Failed to configure virtual display."

        hyprctl output remove \
            "$MONITOR_NAME" \
            2>/dev/null || true

        return 1
    fi


    # ─────────────────────────────────────────
    # Start WayVNC
    # ─────────────────────────────────────────

    local wayvnc_log="/tmp/vdcreate-wayvnc.log"
    local wayvnc_pid

    if [[ "$vnc_mode" == "network" ]]; then

        wayvnc \
            --config "$VNC_CONFIG" \
            -o "$MONITOR_NAME" \
            >"$wayvnc_log" 2>&1 &

    else

        wayvnc \
            -o "$MONITOR_NAME" \
            "$VNC_LOCAL_ADDRESS" \
            >"$wayvnc_log" 2>&1 &

    fi

    wayvnc_pid=$!

    sleep 0.7

    if ! kill -0 "$wayvnc_pid" 2>/dev/null; then

        notify-send \
            "VDCreate" \
            "WayVNC failed to start. See $wayvnc_log"

        cat "$wayvnc_log" >&2

        hyprctl output remove \
            "$MONITOR_NAME" \
            2>/dev/null || true

        rm -f "$ACTIVE_STATE_FILE"

        return 1
    fi


    # ─────────────────────────────────────────
    # Save state only after WayVNC starts.
    # ─────────────────────────────────────────

    set_preferred_side "$side"
    set_preferred_vnc_mode "$vnc_mode"

    printf '%s|%s|%s\n' \
        "$resolution" \
        "$side" \
        "$vnc_mode" \
        > "$ACTIVE_STATE_FILE"

    return 0
}


# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────

case "${1:-toggle}" in

    start)

        resolution="${2:-$DEFAULT_RESOLUTION}"
        side="${3:-$(get_preferred_side)}"
        vnc_mode="${4:-$(get_preferred_vnc_mode)}"

        start_display \
            "$resolution" \
            "$side" \
            "$vnc_mode"

        ;;


    stop)

        stop_display

        ;;


    toggle)

        if is_virtual_display_active; then
            stop_display
        else
            start_display \
                "${2:-$DEFAULT_RESOLUTION}" \
                "${3:-$(get_preferred_side)}" \
                "${4:-$(get_preferred_vnc_mode)}"
        fi

        ;;


    set-side)

        set_preferred_side "${2:-$DEFAULT_SIDE}"

        ;;


    set-vnc-mode)

        mode="${2:-$DEFAULT_VNC_MODE}"

        [[ "$mode" == "lan" ]] &&
            mode="network"

        if [[ "$mode" != "local" &&
              "$mode" != "network" ]]; then

            echo "Invalid VNC mode: $mode" >&2
            exit 1
        fi

        set_preferred_vnc_mode "$mode"

        if is_virtual_display_active &&
           read_active_state; then

            start_display \
                "$ACTIVE_RESOLUTION" \
                "$ACTIVE_SIDE" \
                "$mode"

        fi

        ;;


    regenerate-password)

        if ! regenerate_vnc_password; then
            exit 1
        fi

        if is_virtual_display_active &&
           read_active_state; then

            if [[ "$ACTIVE_VNC_MODE" == "network" ]]; then
                start_display \
                    "$ACTIVE_RESOLUTION" \
                    "$ACTIVE_SIDE" \
                    "network"
            fi

        fi

        ;;


    status)

        resolution="off"
        side="$(get_preferred_side)"
        mode="$(get_preferred_vnc_mode)"

        if is_virtual_display_active &&
           [[ -f "$ACTIVE_STATE_FILE" ]]; then

            IFS='|' read -r \
                resolution \
                side \
                mode \
                < "$ACTIVE_STATE_FILE"

            [[ "$mode" == "lan" ]] &&
                mode="network"
        fi


        bind_address=""
        connect_host=""
        username=""
        password=""
        ssh_command=""
        network_addresses=""


        if [[ "$mode" == "network" ]]; then

            bind_address="${VNC_NETWORK_ADDRESS}:${VNC_PORT}"

            connect_host="$(
                get_primary_network_address
            )"

            username="$VNC_USERNAME"

            if [[ -f "$VNC_PASSWORD_FILE" ]]; then
                password="$(
                    cat "$VNC_PASSWORD_FILE"
                )"
            fi

            network_addresses="$(
                get_network_addresses_csv
            )"

        else

            bind_address="${VNC_LOCAL_ADDRESS}:${VNC_PORT}"

            connect_host="127.0.0.1"

            local_ip="$(
                get_primary_network_address
            )"

            if [[ -n "$local_ip" ]]; then
                ssh_command="ssh -L 5900:127.0.0.1:5900 ${USER}@${local_ip}"
            else
                ssh_command="ssh -L 5900:127.0.0.1:5900 ${USER}@<omarchy-ip>"
            fi

        fi


        # Status format:
        #
        # 1 resolution
        # 2 side
        # 3 mode
        # 4 bind_address
        # 5 primary_connect_host
        # 6 username
        # 7 password
        # 8 ssh_command
        # 9 all_network_addresses_csv

        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "$resolution" \
            "$side" \
            "$mode" \
            "$bind_address" \
            "$connect_host" \
            "$username" \
            "$password" \
            "$ssh_command" \
            "$network_addresses"

        ;;


    *)

        echo "Usage:"
        echo
        echo "  $0 start [resolution] [left|right] [local|network]"
        echo "  $0 stop"
        echo "  $0 toggle [resolution] [left|right] [local|network]"
        echo "  $0 set-side [left|right]"
        echo "  $0 set-vnc-mode [local|network]"
        echo "  $0 regenerate-password"
        echo "  $0 status"

        exit 1

        ;;

esac
