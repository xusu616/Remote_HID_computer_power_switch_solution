#!/system/bin/sh
MOD_WAKE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$MOD_WAKE_DIR/common.sh"
load_config

mkdir -p "$DATA_DIR"
"$MOD_WAKE_DIR/stop-daemon.sh" >/dev/null 2>&1

echo "wake_bridge_daemon" > /sys/power/wake_lock 2>/dev/null
$BB nohup $BB httpd -f -p "0.0.0.0:${PORT:-9876}" -h "$MOD_WAKE_DIR/www" >/dev/null 2>&1 &
echo $! > "$DATA_DIR/httpd.pid"

if [ "${HID_WATCHDOG:-1}" = "1" ] && [ "${AUTO_HID_ON_BOOT:-1}" = "1" ]; then
    $BB nohup $BB sh "$MOD_WAKE_DIR/hid-watchdog.sh" >/dev/null 2>&1 &
    echo $! > "$DATA_DIR/watchdog.pid"
fi
