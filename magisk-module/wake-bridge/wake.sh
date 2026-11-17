#!/system/bin/sh
MOD_WAKE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$MOD_WAKE_DIR/common.sh"
load_config

mkdir -p "$DATA_DIR"
UDC="$(detect_udc)"
LOG="$DATA_DIR/wake.log"
STATE_FILE="/sys/class/udc/$UDC/state"
SOFT_CONN="/sys/class/udc/$UDC/soft_connect"

WAKE_LOCK_DIR="$DATA_DIR/wake.lock"
acquire_wake_lock() {
    local tries=0 lock_pid=""
    while ! mkdir "$WAKE_LOCK_DIR" 2>/dev/null; do
        lock_pid="$($BB cat "$WAKE_LOCK_DIR/pid" 2>/dev/null)"
        if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -rf "$WAKE_LOCK_DIR"
            continue
        fi
        tries=$((tries + 1))
        [ "$tries" -ge 50 ] && return 1
        $BB usleep 100000
    done
    echo "$$" > "$WAKE_LOCK_DIR/pid" 2>/dev/null || true
    trap 'rm -rf "$WAKE_LOCK_DIR"; echo "wake_bridge_trigger" > /sys/power/wake_unlock 2>/dev/null' EXIT INT TERM
}

acquire_wake_lock || exit 0
echo "wake_bridge_trigger" > /sys/power/wake_lock 2>/dev/null

# Always fast-verify gadget configfs state before waking
"$MOD_WAKE_DIR/setup-hid.sh" >/dev/null 2>&1 || true

STATE_BEFORE="$($BB cat "$STATE_FILE" 2>/dev/null || echo unknown)"
HID_STATUS="skipped"
SOFT_STATUS="not_needed"

send_lshift() {
    write_hid_b64 "AgAAAAAAAAA=" 2 && $BB usleep 150000 && write_hid_b64 "AAAAAAAAAAA=" 2
}

# Send Left Shift press & release (safe even if host is already awake)
if [ -c /dev/hidg0 ]; then
    if send_lshift; then
        HID_STATUS="ok"
    else
        HID_STATUS="write_failed_or_suspended"
    fi
else
    HID_STATUS="no_hidg0"
fi

# If USB was already configured before waking yet HID write failed, retry once after 1s before forcing rebind
if [ "$STATE_BEFORE" = "configured" ] && [ "$HID_STATUS" != "ok" ]; then
    $BB sleep 1
    if send_lshift; then
        HID_STATUS="ok"
    else
        "$MOD_WAKE_DIR/setup-hid.sh" --force >/dev/null 2>&1 || true
        $BB sleep 1
        SOFT_STATUS="rebound_hid"
        if send_lshift; then
            HID_STATUS="ok"
        fi
    fi
fi

$BB sleep 2
STATE_MID="$($BB cat "$STATE_FILE" 2>/dev/null || echo unknown)"

# If host just resumed into configured state from sleep, send one more keystroke to wake display
if [ "$STATE_BEFORE" != "configured" ] && [ "$STATE_MID" = "configured" ] && [ "$HID_STATUS" != "ok" ]; then
    if send_lshift; then
        HID_STATUS="ok"
    fi
fi

# Fallback: if host stayed suspended or not attached, trigger USB soft_connect re-enumeration
if [ "$STATE_MID" = "suspended" ] || [ "$STATE_MID" = "not attached" ]; then
    if [ -e "$SOFT_CONN" ]; then
        echo disconnect > "$SOFT_CONN" 2>/dev/null
        $BB sleep 1
        echo connect > "$SOFT_CONN" 2>/dev/null
        $BB sleep 2
        SOFT_STATUS="reconnected"
        if send_lshift; then
            HID_STATUS="ok"
        fi
    else
        SOFT_STATUS="soft_connect_unavailable"
    fi
fi

STATE_AFTER="$($BB cat "$STATE_FILE" 2>/dev/null || echo unknown)"
TS="$($BB date "+%Y-%m-%d %H:%M:%S")"
echo "$TS before=$STATE_BEFORE hid=$HID_STATUS soft=$SOFT_STATUS after=$STATE_AFTER" >> "$LOG"
$BB tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"

echo "wake_bridge_trigger" > /sys/power/wake_unlock 2>/dev/null

echo "time=$TS"
echo "state_before=$STATE_BEFORE"
echo "hid=$HID_STATUS"
echo "soft_reconnect=$SOFT_STATUS"
echo "state_after=$STATE_AFTER"
