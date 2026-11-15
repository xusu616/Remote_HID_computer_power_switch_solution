#!/system/bin/sh
MODDIR=${0%/*}
[ -f "$MODDIR/wake-bridge/stop-daemon.sh" ] && "$MODDIR/wake-bridge/stop-daemon.sh" >/dev/null 2>&1
rm -rf /data/adb/wake-bridge
