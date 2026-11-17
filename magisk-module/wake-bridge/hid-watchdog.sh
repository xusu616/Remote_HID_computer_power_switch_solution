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

has_hid_link() {
    local cfg="$1" f
    for f in "$cfg"/f*; do
        [ -L "$f" ] || continue
        case "$($BB readlink "$f" 2>/dev/null)" in
            *hid.usb0) return 0 ;;
        esac
    done
    return 1
}

LAST_KEEP_ADB=""

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

    CUR_STATE="$($BB cat "/sys/class/udc/$UDC/state" 2>/dev/null)"
    CUR_UDC="$($BB cat "/config/usb_gadget/g1/UDC" 2>/dev/null)"
    CUR_KEEP_ADB="${KEEP_ADB:-0}"

    # Never touch configfs or UDC while the host is suspended, disconnected, or mid-enumeration,
    # unless Android init completely cleared UDC.
    if [ "$CUR_STATE" != "configured" ] && [ -n "$CUR_UDC" ]; then
        LAST_KEEP_ADB="$CUR_KEEP_ADB"
        sleep_interruptible 3
        continue
    fi

    CUR_BM="$($BB cat "$CFG/bmAttributes" 2>/dev/null)"
    NEED_REPAIR=0

    if [ ! -c /dev/hidg0 ] || [ "$CUR_BM" != "0xa0" ] || [ "$CUR_UDC" != "$UDC" ] || ! has_hid_link "$CFG"; then
        NEED_REPAIR=1
    elif [ -n "$LAST_KEEP_ADB" ] && [ "$CUR_KEEP_ADB" != "$LAST_KEEP_ADB" ]; then
        NEED_REPAIR=1
    fi

    if [ "$NEED_REPAIR" = "1" ]; then
        # Wait briefly for any in-flight Android init USB triggers to settle before repairing
        sleep_interruptible 2
        CUR_STATE="$($BB cat "/sys/class/udc/$UDC/state" 2>/dev/null)"
        CUR_UDC="$($BB cat "/config/usb_gadget/g1/UDC" 2>/dev/null)"
        if [ "$CUR_STATE" = "configured" ] || [ -z "$CUR_UDC" ]; then
            "$MOD_WAKE_DIR/setup-hid.sh" >/dev/null 2>&1 || true
            sleep_interruptible 3
        fi
    fi

    LAST_KEEP_ADB="$CUR_KEEP_ADB"
    sleep_interruptible 3
done
