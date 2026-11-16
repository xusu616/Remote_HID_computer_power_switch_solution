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

echo "wake_bridge_daemon" > /sys/power/wake_unlock 2>/dev/null
