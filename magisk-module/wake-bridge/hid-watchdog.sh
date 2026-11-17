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

get_adbd_ffs_tid() {
    local p f
    p="$($BB pidof adbd 2>/dev/null | $BB awk '{print $1}')"
    [ -n "$p" ] || return 0
    for f in /proc/"$p"/task/*/comm; do
        [ -r "$f" ] || continue
        if [ "$($BB cat "$f" 2>/dev/null)" = "UsbFfs-monitor" ]; then
            echo "$f"
            return 0
        fi
    done
}

OSC_WINDOW=10
OSC_THRESHOLD=5
COOLDOWN_SEC=25
DEGRADE_DURATION=60

OSC_TIMES=""
LAST_STATE=""
LAST_FFS_TID=""
LAST_KEEP_ADB=""
FAIL_STREAK=0
COOLDOWN_UNTIL=0
DEGRADED_HID_ONLY=0
DEGRADED_UNTIL=0
DEGRADE_STRIKES=0

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
        DEGRADED_HID_ONLY=0
        DEGRADE_STRIKES=0
        OSC_TIMES=""
        COOLDOWN_UNTIL=0
        FAIL_STREAK=0
    fi

    # 1. Oscillation circuit-breaker when composite USB ADB + HID (KEEP_ADB=1) is active
    if [ "$CUR_KEEP_ADB" = "1" ] && [ "$DEGRADED_HID_ONLY" = "0" ]; then
        CUR_FFS_TID="$(get_adbd_ffs_tid)"
        EVENT_HIT=0
        if [ -n "$LAST_STATE" ] && [ "$CUR_STATE" != "$LAST_STATE" ]; then
            if [ "$CUR_STATE" = "configured" ] || [ "$LAST_STATE" = "configured" ]; then
                EVENT_HIT=1
            fi
        fi
        if [ -n "$LAST_FFS_TID" ] && [ -n "$CUR_FFS_TID" ] && [ "$CUR_FFS_TID" != "$LAST_FFS_TID" ]; then
            EVENT_HIT=1
        fi
        LAST_STATE="$CUR_STATE"
        [ -n "$CUR_FFS_TID" ] && LAST_FFS_TID="$CUR_FFS_TID"

        NEW_TIMES=""
        OSC_COUNT=0
        for t in $OSC_TIMES; do
            if [ $((NOW - t)) -le "$OSC_WINDOW" ]; then
                NEW_TIMES="$NEW_TIMES $t"
                OSC_COUNT=$((OSC_COUNT + 1))
            fi
        done
        if [ "$EVENT_HIT" = "1" ]; then
            NEW_TIMES="$NEW_TIMES $NOW"
            OSC_COUNT=$((OSC_COUNT + 1))
        fi
        OSC_TIMES="$NEW_TIMES"

        if [ "$OSC_COUNT" -ge "$OSC_THRESHOLD" ]; then
            DEGRADE_STRIKES=$((DEGRADE_STRIKES + 1))
            DEGRADED_HID_ONLY=1
            DEGRADED_UNTIL=$((NOW + DEGRADE_DURATION))
            OSC_TIMES=""
            FAIL_STREAK=0
            log_wd "WARN: USB oscillation detected ($OSC_COUNT resets in ${OSC_WINDOW}s, strike $DEGRADE_STRIKES); circuit-breaker degrading to pure HID"
            "$MOD_WAKE_DIR/setup-hid.sh" --force --hid-only >/dev/null 2>&1 || true
            COOLDOWN_UNTIL=$((NOW + COOLDOWN_SEC))
            LAST_KEEP_ADB="$CUR_KEEP_ADB"
            sleep_interruptible 1
            continue
        fi
    elif [ "$DEGRADED_HID_ONLY" = "1" ]; then
        if [ "$CUR_KEEP_ADB" != "1" ]; then
            DEGRADED_HID_ONLY=0
        elif [ "$DEGRADE_STRIKES" -lt 2 ] && [ "$NOW" -ge "$DEGRADED_UNTIL" ] && [ "$CUR_STATE" = "configured" ]; then
            log_wd "INFO: Restoring composite ADB+HID after ${DEGRADE_DURATION}s pure-HID stabilization"
            "$MOD_WAKE_DIR/setup-hid.sh" --force >/dev/null 2>&1 || true
            DEGRADED_HID_ONLY=0
            OSC_TIMES=""
            LAST_STATE="$($BB cat "/sys/class/udc/$UDC/state" 2>/dev/null)"
            LAST_FFS_TID="$(get_adbd_ffs_tid)"
            COOLDOWN_UNTIL=$((NOW + COOLDOWN_SEC))
            LAST_KEEP_ADB="$CUR_KEEP_ADB"
            sleep_interruptible 1
            continue
        fi
    fi

    # Respect post-repair cooldown unless KEEP_ADB config just changed
    if [ "$NOW" -lt "$COOLDOWN_UNTIL" ]; then
        LAST_KEEP_ADB="$CUR_KEEP_ADB"
        sleep_interruptible 1
        continue
    fi

    # Never touch configfs or UDC while the host is suspended, disconnected, or mid-enumeration,
    # unless Android init completely cleared UDC.
    if [ "$CUR_STATE" != "configured" ] && [ -n "$CUR_UDC" ]; then
        FAIL_STREAK=0
        LAST_KEEP_ADB="$CUR_KEEP_ADB"
        sleep_interruptible 1
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
            if [ "$DEGRADED_HID_ONLY" = "1" ]; then
                "$MOD_WAKE_DIR/setup-hid.sh" --hid-only >/dev/null 2>&1 || true
            else
                "$MOD_WAKE_DIR/setup-hid.sh" >/dev/null 2>&1 || true
            fi
            NOW="$($BB date +%s 2>/dev/null)"
            [ -n "$NOW" ] || NOW=0
            COOLDOWN_UNTIL=$((NOW + COOLDOWN_SEC))
            LAST_STATE="$($BB cat "/sys/class/udc/$UDC/state" 2>/dev/null)"
            LAST_FFS_TID="$(get_adbd_ffs_tid)"
        fi
        FAIL_STREAK=0
    else
        FAIL_STREAK=0
    fi

    LAST_KEEP_ADB="$CUR_KEEP_ADB"
    sleep_interruptible 1
done
