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

LAST_STATE=""
LAST_SIG=""
LAST_USB_CFG=""
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
    # Never poke USB configfs / gadget / settings while the host has suspended the USB bus
    if [ "$CUR_STATE" = "suspended" ]; then
        LAST_STATE="$CUR_STATE"
        sleep_interruptible 3
        continue
    fi

    CUR_SIG="$(read_cfg_sig "$CFG")"
    CUR_USB_CFG="$(getprop sys.usb.config 2>/dev/null),$(getprop persist.sys.usb.config 2>/dev/null)"
    CUR_KEEP_ADB="${KEEP_ADB:-0}"
    CUR_BM="$($BB cat "$CFG/bmAttributes" 2>/dev/null)"
    CUR_UDC="$($BB cat "/config/usb_gadget/g1/UDC" 2>/dev/null)"

    NEED_CHECK=0
    if [ "$CUR_STATE" != "$LAST_STATE" ] || [ "$CUR_SIG" != "$LAST_SIG" ] || [ "$CUR_USB_CFG" != "$LAST_USB_CFG" ] || [ "$CUR_KEEP_ADB" != "$LAST_KEEP_ADB" ]; then
        NEED_CHECK=1
    elif [ ! -c /dev/hidg0 ] || [ "$CUR_BM" != "0xa0" ] || [ "$CUR_UDC" != "$UDC" ] || ! has_hid_link "$CFG"; then
        NEED_CHECK=1
    fi

    if [ "$NEED_CHECK" = "1" ]; then
        "$MOD_WAKE_DIR/setup-hid.sh" >/dev/null 2>&1 || true
        CUR_STATE="$($BB cat "/sys/class/udc/$UDC/state" 2>/dev/null)"

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
        fi

        CUR_SIG="$(read_cfg_sig "$CFG")"
        CUR_USB_CFG="$(getprop sys.usb.config 2>/dev/null),$(getprop persist.sys.usb.config 2>/dev/null)"
    fi

    LAST_STATE="$CUR_STATE"
    LAST_SIG="$CUR_SIG"
    LAST_USB_CFG="$CUR_USB_CFG"
    LAST_KEEP_ADB="$CUR_KEEP_ADB"
    sleep_interruptible 3
done
