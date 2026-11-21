#!/system/bin/sh
MOD_WAKE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$MOD_WAKE_DIR/common.sh"

for pid_file in "$DATA_DIR/httpd.pid" "$DATA_DIR/watchdog.pid"; do
    if [ -f "$pid_file" ]; then
        PID="$($BB cat "$pid_file" 2>/dev/null)"
        [ -n "$PID" ] && kill "$PID" 2>/dev/null
        rm -f "$pid_file"
    fi
done

# Fallback: kill only real httpd/hid-watchdog processes, never an enclosing sh -c caller
for pid in $($BB ps -o pid,args 2>/dev/null | $BB awk '
    (($2 ~ /(^|\/)httpd$/ || ($2 ~ /busybox$/ && $3 == "httpd")) && $0 ~ /wake-bridge\/www/) { print $1; next }
    ($2 == "{hid-watchdog.sh}" || (($2 ~ /(^|\/)(sh|ash)$/ || ($2 ~ /busybox$/ && $3 ~ /^(sh|ash)$/)) && ($3 ~ /wake-bridge\/hid-watchdog\.sh$/ || $4 ~ /wake-bridge\/hid-watchdog\.sh$/))) { print $1 }
'); do
    [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ] && kill "$pid" 2>/dev/null
done

rm -f "$DATA_DIR/daemon-wake-lock-mode"
if [ -e /sys/power/wake_lock ]; then
    if ! ACTIVE_WAKE_LOCKS="$($BB cat /sys/power/wake_lock)"; then
        echo "wake_bridge: cannot read active wake locks while stopping daemon" >&2
        exit 1
    fi
    DAEMON_LOCK_ACTIVE=0
    for LOCK_NAME in $ACTIVE_WAKE_LOCKS; do
        [ "$LOCK_NAME" = "wake_bridge_daemon" ] && DAEMON_LOCK_ACTIVE=1
    done
    if [ "$DAEMON_LOCK_ACTIVE" = "1" ]; then
        if ! echo "wake_bridge_daemon" > /sys/power/wake_unlock; then
            echo "wake_bridge: cannot release daemon wake lock" >&2
            exit 1
        fi
    fi
fi
exit 0
