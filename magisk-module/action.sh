#!/system/bin/sh
MODDIR=${0%/*}
MOD_WAKE_DIR="$MODDIR/wake-bridge"
. "$MOD_WAKE_DIR/common.sh"
load_config

[ -n "$BB" ] || { echo "wake_bridge: BusyBox not found for module Action" >&2; exit 1; }
mkdir -p "$DATA_DIR" || exit 1
ACTION_LOG="$DATA_DIR/action.log"
if ! : >> "$ACTION_LOG"; then
    echo "wake_bridge: cannot open Action log: $ACTION_LOG" >&2
    exit 1
fi

LOG_RESULT=0
log_action() {
    printf '%s\n' "$1"
    if ! printf '%s\n' "$1" >> "$ACTION_LOG"; then
        echo "wake_bridge: cannot append to Action log: $ACTION_LOG" >&2
        LOG_RESULT=1
    fi
}

log_action "[$($BB date '+%Y-%m-%d %H:%M:%S')] Action: start Tailscale, then repair the configured USB gadget"
TAILSCALE_OUTPUT="$($BB sh "$MOD_WAKE_DIR/start-tailscale.sh" --manual 2>&1)"
TAILSCALE_RESULT=$?
[ -z "$TAILSCALE_OUTPUT" ] || log_action "$TAILSCALE_OUTPUT"
log_action "tailscale_result=$TAILSCALE_RESULT"
if [ "$TAILSCALE_RESULT" -ne 0 ]; then
    log_action "Tailscale startup failed; continuing with the independent ADB/HID repair"
fi

HID_RESULT=0
UDC="$(detect_udc)"
UDC_RESULT=$?
if [ "$UDC_RESULT" -ne 0 ] || [ -z "$UDC" ]; then
    HID_RESULT=1
    log_action "USB repair skipped: no USB device controller was found"
else
    USB_STATE="$($BB cat "/sys/class/udc/$UDC/state" 2>&1)"
    USB_STATE_RESULT=$?
    if [ "$USB_STATE_RESULT" -ne 0 ] || [ -z "$USB_STATE" ]; then
        HID_RESULT=1
        log_action "USB repair skipped: cannot read the controller state; check the USB connection before retrying Action"
    elif [ "$USB_STATE" = "suspended" ]; then
        HID_RESULT=2
        log_action "USB repair skipped: the host USB link is suspended; the gadget will remain connected"
        log_action "Resume the host manually, or physically unplug and reconnect the USB cable, then retry Action"
    else
        log_action "Repairing ADB/HID with KEEP_ADB=$(keep_adb_label "${KEEP_ADB:-0}")"
        HID_OUTPUT="$($BB sh "$MOD_WAKE_DIR/setup-hid.sh" --force 2>&1)"
        HID_RESULT=$?
        [ -z "$HID_OUTPUT" ] || log_action "$HID_OUTPUT"
        if [ "$HID_RESULT" -ne 0 ]; then
            log_action "ADB/HID repair failed with exit status $HID_RESULT"
        fi
    fi
fi
log_action "hid_result=$HID_RESULT"

STATUS_OUTPUT="$($BB sh "$MODDIR/system/bin/wake-bridge" status 2>&1)"
STATUS_RESULT=$?
[ -z "$STATUS_OUTPUT" ] || log_action "$STATUS_OUTPUT"
log_action "status_result=$STATUS_RESULT"
if [ "$STATUS_RESULT" -ne 0 ]; then
    log_action "Status inspection failed with exit status $STATUS_RESULT"
fi

# A later successful stage must not hide the first failed operation.
ACTION_RESULT=$TAILSCALE_RESULT
if [ "$ACTION_RESULT" -eq 0 ]; then ACTION_RESULT=$HID_RESULT; fi
if [ "$ACTION_RESULT" -eq 0 ]; then ACTION_RESULT=$STATUS_RESULT; fi
if [ "$ACTION_RESULT" -eq 0 ]; then ACTION_RESULT=$LOG_RESULT; fi
log_action "action_result=$ACTION_RESULT"
if [ "$ACTION_RESULT" -eq 0 ]; then ACTION_RESULT=$LOG_RESULT; fi
exit "$ACTION_RESULT"
