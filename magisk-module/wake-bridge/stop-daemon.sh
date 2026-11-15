#!/system/bin/sh
MOD_WAKE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$MOD_WAKE_DIR/common.sh"

if [ -f "$DATA_DIR/httpd.pid" ]; then
    PID="$($BB cat "$DATA_DIR/httpd.pid" 2>/dev/null)"
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    rm -f "$DATA_DIR/httpd.pid"
fi
$BB pkill -f "wake-bridge/www" 2>/dev/null
echo "wake_bridge_daemon" > /sys/power/wake_unlock 2>/dev/null
