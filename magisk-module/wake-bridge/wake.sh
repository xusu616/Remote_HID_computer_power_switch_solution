#!/system/bin/sh
MOD_WAKE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$MOD_WAKE_DIR/common.sh"
load_config

mkdir -p "$DATA_DIR"
UDC="$(detect_udc)"
LOG="$DATA_DIR/wake.log"
STATE_FILE="/sys/class/udc/$UDC/state"
SOFT_CONN="/sys/class/udc/$UDC/soft_connect"

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

# If USB is configured while host is awake yet HID write failed, UDC was likely bound without hid.usb0
if [ "$STATE_BEFORE" = "configured" ] && [ "$HID_STATUS" != "ok" ]; then
    "$MOD_WAKE_DIR/setup-hid.sh" --force >/dev/null 2>&1 || true
    $BB sleep 1
    SOFT_STATUS="rebound_hid"
    if send_lshift; then
        HID_STATUS="ok"
    fi
fi

$BB sleep 2
STATE_MID="$($BB cat "$STATE_FILE" 2>/dev/null || echo unknown)"

# Fallback: if host stayed suspended, trigger USB soft_connect re-enumeration
if [ "$STATE_MID" = "suspended" ]; then
    if [ -e "$SOFT_CONN" ]; then
        echo disconnect > "$SOFT_CONN" 2>/dev/null
        $BB sleep 1
        echo connect > "$SOFT_CONN" 2>/dev/null
        $BB sleep 2
        SOFT_STATUS="reconnected"
        send_lshift || true
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
