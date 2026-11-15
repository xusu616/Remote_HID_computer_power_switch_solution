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

if [ ! -c /dev/hidg0 ]; then
    "$MOD_WAKE_DIR/setup-hid.sh" >/dev/null 2>&1
fi

STATE_BEFORE="$($BB cat "$STATE_FILE" 2>/dev/null || echo unknown)"
HID_STATUS="skipped"
SOFT_STATUS="not_needed"

send_lshift_cmd="echo AgAAAAAAAAA= | $BB base64 -d > /dev/hidg0 && $BB usleep 150000 && echo AAAAAAAAAAA= | $BB base64 -d > /dev/hidg0"

# Send Left Shift press & release (safe even if host is already awake)
if [ -c /dev/hidg0 ]; then
    if $BB timeout 2 $BB sh -c "$send_lshift_cmd" 2>/dev/null; then
        HID_STATUS="ok"
    else
        HID_STATUS="write_failed_or_suspended"
    fi
else
    HID_STATUS="no_hidg0"
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
        if [ -c /dev/hidg0 ]; then
            $BB timeout 2 $BB sh -c "$send_lshift_cmd" 2>/dev/null || true
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
