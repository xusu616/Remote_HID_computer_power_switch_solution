#!/system/bin/sh
MOD_WAKE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$MOD_WAKE_DIR/common.sh"

SLEEP_PID=""
cleanup() {
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
    exit 0
}
trap cleanup TERM INT

sleep_interruptible() {
    $BB sleep "$1" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""
}

read_cfg_sig() {
    local cfg="$1"
    $BB stat -c '%Y' "$cfg" "$cfg/strings/0x409/configuration" 2>/dev/null | $BB tr '\n' ':'
}

LAST_STATE=""
LAST_SIG=""

while true; do
    load_config
    if [ "${HID_WATCHDOG:-1}" != "1" ] || [ "${AUTO_HID_ON_BOOT:-1}" != "1" ]; then
        exit 0
    fi

    UDC="$(detect_udc)"
    CFG="$(detect_usb_cfg)"
    if [ -z "$UDC" ] || [ -z "$CFG" ]; then
        sleep_interruptible 3
        continue
    fi

    # Fast-repair if configfs links or bmAttributes were cleared/overwritten by init
    "$MOD_WAKE_DIR/setup-hid.sh" >/dev/null 2>&1 || true

    CUR_STATE="$($BB cat "/sys/class/udc/$UDC/state" 2>/dev/null)"
    CUR_SIG="$(read_cfg_sig "$CFG")"

    if [ "$CUR_STATE" = "configured" ] && { [ "$LAST_STATE" != "configured" ] || [ "$CUR_SIG" != "$LAST_SIG" ]; }; then
        # Wait briefly for host enumeration and init triggers to settle, then probe HID endpoint
        sleep_interruptible 1
        "$MOD_WAKE_DIR/setup-hid.sh" >/dev/null 2>&1 || true
        CUR_STATE="$($BB cat "/sys/class/udc/$UDC/state" 2>/dev/null)"
        if [ "$CUR_STATE" = "configured" ] && [ -c /dev/hidg0 ]; then
            if ! write_hid_b64 "AAAAAAAAAAA=" 1; then
                CUR_STATE="$($BB cat "/sys/class/udc/$UDC/state" 2>/dev/null)"
                if [ "$CUR_STATE" = "configured" ]; then
                    "$MOD_WAKE_DIR/setup-hid.sh" --force >/dev/null 2>&1 || true
                    sleep_interruptible 1
                    CUR_STATE="$($BB cat "/sys/class/udc/$UDC/state" 2>/dev/null)"
                fi
            fi
        fi
        CUR_SIG="$(read_cfg_sig "$CFG")"
    fi

    LAST_STATE="$CUR_STATE"
    LAST_SIG="$CUR_SIG"
    sleep_interruptible 3
done
