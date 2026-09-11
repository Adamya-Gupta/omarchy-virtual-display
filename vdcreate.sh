#!/bin/bash

set -u

MONITOR_NAME="virtual_display"

DEFAULT_RESOLUTION="1366x768"
DEFAULT_SIDE="right"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vdcreate"
ACTIVE_STATE_FILE="$STATE_DIR/active"
PREFERRED_SIDE_FILE="$STATE_DIR/side"

mkdir -p "$STATE_DIR"

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


# ─────────────────────────────────────────────
# Helpers
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

    echo "$side" > "$PREFERRED_SIDE_FILE"
}


is_virtual_display_active() {
    hyprctl monitors -j 2>/dev/null |
        jq -e --arg name "$MONITOR_NAME" \
        'any(.[]; .name == $name and .disabled == false)' \
        >/dev/null 2>&1
}


# ─────────────────────────────────────────────
# Find the main/system display
#
# Prefer the internal laptop panel.
# ─────────────────────────────────────────────

get_main_monitor() {
    local monitors
    local monitor

    monitors="$(hyprctl monitors -j 2>/dev/null)"

    if [[ -z "$monitors" ]]; then
        return 1
    fi

    # Prefer the internal laptop panel.
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

    # Fall back to focused monitor.
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
# Calculate logical width
#
# Hyprland positions monitors using the
# scaled + transformed resolution.
#
# Example:
#
#   1920 / 1.25 = 1536
#
# Rotated displays swap width/height.
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
# Stop
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
# Start
# ─────────────────────────────────────────────

start_display() {
    local resolution="$1"
    local side="$2"

    if ! check_dependencies; then
        return 1
    fi

    if [[ "$side" != "left" && "$side" != "right" ]]; then
        side="$DEFAULT_SIDE"
    fi

    local main_monitor

    main_monitor="$(get_main_monitor)"

    if [[ -z "$main_monitor" ]]; then
        notify-send \
            "VDCreate" \
            "Could not determine the main display."

        return 1
    fi


    # ─────────────────────────────────────────
    # Read current main-monitor configuration
    # ─────────────────────────────────────────

    local main_name
    local main_width
    local main_height
    local main_refresh
    local main_scale
    local main_transform

    main_name="$(
        jq -r '.name' <<< "$main_monitor"
    )"

    main_width="$(
        jq -r '.width' <<< "$main_monitor"
    )"

    main_height="$(
        jq -r '.height' <<< "$main_monitor"
    )"

    main_refresh="$(
        jq -r '.refreshRate' <<< "$main_monitor"
    )"

    main_scale="$(
        jq -r '.scale' <<< "$main_monitor"
    )"

    main_transform="$(
        jq -r '.transform' <<< "$main_monitor"
    )"


    # ─────────────────────────────────────────
    # Calculate logical dimensions
    # ─────────────────────────────────────────

    local main_logical_width
    local virtual_width
    local virtual_x

    main_logical_width="$(
        get_logical_width \
            "$main_width" \
            "$main_height" \
            "$main_scale" \
            "$main_transform"
    )"

    virtual_width="${resolution%x*}"


    # ─────────────────────────────────────────
    # IMPORTANT:
    #
    # The main display is ALWAYS anchored at
    # 0x0.
    #
    # We do NOT use its current x/y.
    # ─────────────────────────────────────────

    if [[ "$side" == "right" ]]; then
        virtual_x="$main_logical_width"
    else
        virtual_x="-$virtual_width"
    fi


    notify-send \
        "VDCreate" \
        "Starting ${resolution} on ${side} of ${main_name}..."


    # ─────────────────────────────────────────
    # Stop previous VNC / virtual monitor
    # ─────────────────────────────────────────

    killall wayvnc 2>/dev/null || true

    hyprctl output remove \
        "$MONITOR_NAME" \
        2>/dev/null || true

    sleep 0.2


    # ─────────────────────────────────────────
    # Re-anchor the main monitor at 0x0
    #
    # Everything else is copied from the
    # monitor's CURRENT configuration.
    # ─────────────────────────────────────────

    local main_mode

    main_mode="${main_width}x${main_height}@${main_refresh}"

    hyprctl eval \
        "hl.monitor({
            output = '$main_name',
            mode = '$main_mode',
            position = '0x0',
            scale = $main_scale,
            transform = $main_transform
        })"


    # ─────────────────────────────────────────
    # Create virtual monitor
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
    # Configure virtual monitor
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
    # Save state
    # ─────────────────────────────────────────

    set_preferred_side "$side"

    printf '%s|%s\n' \
        "$resolution" \
        "$side" \
        > "$ACTIVE_STATE_FILE"


    # ─────────────────────────────────────────
    # Start VNC
    # ─────────────────────────────────────────

    wayvnc \
        -o "$MONITOR_NAME" \
        0.0.0.0 \
        >/dev/null 2>&1 &

    return 0
}


# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────

case "${1:-toggle}" in

    start)

        resolution="${2:-$DEFAULT_RESOLUTION}"
        side="${3:-$(get_preferred_side)}"

        start_display \
            "$resolution" \
            "$side"

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
                "${3:-$(get_preferred_side)}"
        fi

        ;;

    set-side)

        side="${2:-$DEFAULT_SIDE}"

        set_preferred_side "$side"

        ;;

    status)

        if is_virtual_display_active; then

            if [[ -f "$ACTIVE_STATE_FILE" ]]; then
                cat "$ACTIVE_STATE_FILE"
            else
                echo "on|$(get_preferred_side)"
            fi

        else

            echo "off|$(get_preferred_side)"

        fi

        ;;

    *)

        echo "Usage:"
        echo
        echo "  $0 start [resolution] [left|right]"
        echo "  $0 stop"
        echo "  $0 toggle [resolution] [left|right]"
        echo "  $0 set-side [left|right]"
        echo "  $0 status"

        exit 1

        ;;

esac