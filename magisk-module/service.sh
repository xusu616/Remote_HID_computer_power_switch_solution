#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/wake-bridge/common.sh"

(
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        $BB sleep 2
    done
    $BB sleep 10
    load_config
    mkdir -p "$DATA_DIR" || exit 1
    if [ "${AUTO_HID_ON_BOOT:-1}" = "1" ]; then
        "$MODDIR/wake-bridge/setup-hid.sh" >> "$DATA_DIR/boot.log" 2>&1
    fi
    "$MODDIR/wake-bridge/start-daemon.sh" >> "$DATA_DIR/boot.log" 2>&1
    "$MODDIR/wake-bridge/start-tailscale.sh" >> "$DATA_DIR/boot.log" 2>&1
) &
