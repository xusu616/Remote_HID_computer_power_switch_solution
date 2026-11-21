#!/system/bin/sh
MOD_WAKE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$MOD_WAKE_DIR/common.sh"
load_config

[ -n "$BB" ] || { echo "wake_bridge: BusyBox not found" >&2; exit 1; }
DAEMON_WAKE_LOCK="${DAEMON_WAKE_LOCK:-1}"
case "$DAEMON_WAKE_LOCK" in
    0|1) ;;
    *) echo "wake_bridge: DAEMON_WAKE_LOCK must be 0 or 1" >&2; exit 1 ;;
esac

mkdir -p "$DATA_DIR" || exit 1
"$MOD_WAKE_DIR/stop-daemon.sh" >/dev/null || exit 1

DAEMON_LOCK_HELD=0
HTTPD_PID=""
WATCHDOG_PID=""
cleanup_failed_start() {
    [ -n "$HTTPD_PID" ] && kill "$HTTPD_PID" 2>/dev/null
    [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null
    rm -f "$DATA_DIR/httpd.pid" "$DATA_DIR/watchdog.pid" "$DATA_DIR/daemon-wake-lock-mode"
    if [ "$DAEMON_LOCK_HELD" = "1" ]; then
        if ! echo "wake_bridge_daemon" > /sys/power/wake_unlock; then
            echo "wake_bridge: failed to release daemon wake lock after startup failure" >&2
        fi
    fi
}
trap cleanup_failed_start EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$DAEMON_WAKE_LOCK" = "1" ]; then
    if ! echo "wake_bridge_daemon" > /sys/power/wake_lock; then
        echo "wake_bridge: cannot acquire daemon wake lock; service was not started" >&2
        exit 1
    fi
    DAEMON_LOCK_HELD=1
fi

$BB nohup $BB httpd -f -p "0.0.0.0:${PORT:-9876}" -h "$MOD_WAKE_DIR/www" > "$DATA_DIR/httpd.log" 2>&1 &
HTTPD_PID=$!
echo "$HTTPD_PID" > "$DATA_DIR/httpd.pid" || exit 1
if [ "${HID_WATCHDOG:-1}" = "1" ] && [ "${AUTO_HID_ON_BOOT:-1}" = "1" ]; then
    $BB nohup $BB sh "$MOD_WAKE_DIR/hid-watchdog.sh" > "$DATA_DIR/watchdog-start.log" 2>&1 &
    WATCHDOG_PID=$!
    echo "$WATCHDOG_PID" > "$DATA_DIR/watchdog.pid" || exit 1
fi
# A one-time startup check catches missing httpd and failed socket binding.
$BB sleep 1
if ! kill -0 "$HTTPD_PID" 2>/dev/null; then
    echo "wake_bridge: HTTP daemon failed to start; see $DATA_DIR/httpd.log" >&2
    exit 1
fi
if [ -n "$WATCHDOG_PID" ] && ! kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    echo "wake_bridge: HID watchdog failed to start; see $DATA_DIR/watchdog-start.log" >&2
    exit 1
fi
echo "$DAEMON_WAKE_LOCK" > "$DATA_DIR/daemon-wake-lock-mode" || exit 1
trap - EXIT HUP INT TERM
echo "started daemon_wake_lock=$DAEMON_WAKE_LOCK"
