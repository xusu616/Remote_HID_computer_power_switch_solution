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

LOG_FILE="$DATA_DIR/watchdog.log"
log_wd() {
    local ts
    ts="$($BB date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null || true
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

COOLDOWN_SEC=25
LAST_KEEP_ADB=""
FAIL_STREAK=0
COOLDOWN_UNTIL=0

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

    NOW="$($BB date +%s 2>/dev/null)"
    [ -n "$NOW" ] || NOW=0
    CUR_STATE="$($BB cat "/sys/class/udc/$UDC/state" 2>/dev/null)"
    CUR_UDC="$($BB cat "/config/usb_gadget/g1/UDC" 2>/dev/null)"
    CUR_KEEP_ADB="$(normalize_keep_adb "${KEEP_ADB:-0}")"

    if [ -n "$LAST_KEEP_ADB" ] && [ "$CUR_KEEP_ADB" != "$LAST_KEEP_ADB" ]; then
        COOLDOWN_UNTIL=0
        FAIL_STREAK=0
    fi

    # Respect post-repair cooldown unless KEEP_ADB config just changed
    if [ "$NOW" -lt "$COOLDOWN_UNTIL" ]; then
        LAST_KEEP_ADB="$CUR_KEEP_ADB"
        sleep_interruptible 2
        continue
    fi

    # Never touch configfs or UDC while the host is suspended, disconnected, or mid-enumeration,
    # unless Android init completely cleared UDC.
    if [ "$CUR_STATE" != "configured" ] && [ -n "$CUR_UDC" ]; then
        FAIL_STREAK=0
        LAST_KEEP_ADB="$CUR_KEEP_ADB"
        sleep_interruptible 2
        continue
    fi

    CUR_BM="$($BB cat "$CFG/bmAttributes" 2>/dev/null)"
    NEED_REPAIR=0
    REPAIR_REASON=""

    if [ ! -c /dev/hidg0 ]; then
        NEED_REPAIR=1
        REPAIR_REASON="/dev/hidg0 missing"
    elif [ "$CUR_BM" != "0xa0" ]; then
        NEED_REPAIR=1
        REPAIR_REASON="bmAttributes=$CUR_BM"
    elif [ "$CUR_UDC" != "$UDC" ]; then
        NEED_REPAIR=1
        REPAIR_REASON="UDC=$CUR_UDC"
    elif ! has_hid_link "$CFG"; then
        NEED_REPAIR=1
        REPAIR_REASON="hid.usb0 symlink missing"
    elif [ -n "$LAST_KEEP_ADB" ] && [ "$CUR_KEEP_ADB" != "$LAST_KEEP_ADB" ]; then
        NEED_REPAIR=1
        FAIL_STREAK=2
        REPAIR_REASON="KEEP_ADB changed ($LAST_KEEP_ADB -> $CUR_KEEP_ADB)"
    fi

    if [ "$NEED_REPAIR" = "1" ]; then
        FAIL_STREAK=$((FAIL_STREAK + 1))
        if [ "$FAIL_STREAK" -lt 2 ]; then
            # Debounce: wait ~2s and require a 2nd consecutive confirmation before repairing
            sleep_interruptible 2
            continue
        fi
        CUR_STATE="$($BB cat "/sys/class/udc/$UDC/state" 2>/dev/null)"
        CUR_UDC="$($BB cat "/config/usb_gadget/g1/UDC" 2>/dev/null)"
        if [ "$CUR_STATE" = "configured" ] || [ -z "$CUR_UDC" ]; then
            log_wd "INFO: Repairing HID gadget ($REPAIR_REASON)"
            "$MOD_WAKE_DIR/setup-hid.sh" >/dev/null 2>&1 || true
            NOW="$($BB date +%s 2>/dev/null)"
            [ -n "$NOW" ] || NOW=0
            COOLDOWN_UNTIL=$((NOW + COOLDOWN_SEC))
        fi
        FAIL_STREAK=0
    else
        FAIL_STREAK=0
    fi

    LAST_KEEP_ADB="$CUR_KEEP_ADB"
    sleep_interruptible 2
done
