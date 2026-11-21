#!/system/bin/sh
MANUAL=0
case "$#" in
    0) ;;
    1)
        if [ "$1" != "--manual" ]; then
            echo "Usage: start-tailscale.sh [--manual]" >&2
            exit 2
        fi
        MANUAL=1
        ;;
    *)
        echo "Usage: start-tailscale.sh [--manual]" >&2
        exit 2
        ;;
esac
MOD_WAKE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$MOD_WAKE_DIR/common.sh"
load_config

[ -n "$BB" ] || { echo "wake_bridge: BusyBox not found for Tailscale startup" >&2; exit 1; }
mkdir -p "$DATA_DIR" || exit 1
LOG_FILE="$DATA_DIR/tailscale-start.log"
TAILSCALE_PACKAGE="com.tailscale.ipn"

record_result() {
    RESULT="$1"
    MESSAGE="$2"
    TIMESTAMP="$($BB date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] %s: %s\n' "$TIMESTAMP" "$RESULT" "$MESSAGE" >> "$LOG_FILE" || return 1
    printf '%s\n' "$RESULT" > "$DATA_DIR/tailscale-start-status" || return 1
    echo "tailscale_start_result=$RESULT"
}

has_foreground_vpn_service() {
    if ! SERVICE_DUMP="$(dumpsys activity services "$TAILSCALE_PACKAGE" 2>/dev/null)"; then
        return 2
    fi
    printf '%s\n' "$SERVICE_DUMP" | $BB awk '
        /^[[:space:]]*\* ServiceRecord\{/ {
            in_service = ($0 ~ /ServiceRecord\{[^}]* u0 com[.]tailscale[.]ipn\/[.]IPNService\}/)
        }
        in_service && /isForeground=true([[:space:]]|$)/ { found = 1 }
        END { if (!found) exit 1 }
    '
}

if [ "$MANUAL" = "0" ]; then
case "${AUTO_TAILSCALE_ON_BOOT:-1}" in
    0)
        record_result disabled "Automatic Tailscale startup is disabled"
        exit $?
        ;;
    1) ;;
    *)
        record_result invalid_config "AUTO_TAILSCALE_ON_BOOT must be 0 or 1"
        exit 1
        ;;
esac
fi

if ! PACKAGE_PATH="$(pm path --user 0 "$TAILSCALE_PACKAGE" 2>/dev/null)"; then
    record_result app_missing "Tailscale is not installed for user 0"
    exit 1
fi
case "$PACKAGE_PATH" in
    package:*) ;;
    *)
        record_result app_missing "Tailscale package path was not found for user 0"
        exit 1
        ;;
esac

has_foreground_vpn_service
SERVICE_RESULT=$?
case "$SERVICE_RESULT" in
    0)
        record_result already_running "IPNService is already foreground; no connect request was sent"
        exit $?
        ;;
    1) ;;
    *)
        record_result service_check_failed "Cannot inspect Tailscale services"
        exit 1
        ;;
esac

# Android's activity service cannot append to root-only /data/adb files.
# Keep Binder command output on a pipe; this root shell owns the log write.
CONNECT_OUTPUT="$(am broadcast --user 0 --include-stopped-packages -a com.tailscale.ipn.CONNECT_VPN -n com.tailscale.ipn/.IPNReceiver 2>&1)"
CONNECT_RESULT=$?
printf '%s\n' "$CONNECT_OUTPUT" >> "$LOG_FILE" || exit 1
if [ "$CONNECT_RESULT" -ne 0 ]; then
    record_result connect_request_failed "CONNECT_VPN broadcast failed"
    exit 1
fi

# One bounded wait for asynchronous app initialization; no retry or monitoring loop.
if ! $BB sleep 10; then
    record_result initialization_wait_failed "The startup wait was interrupted"
    exit 1
fi
has_foreground_vpn_service
SERVICE_RESULT=$?
case "$SERVICE_RESULT" in
    0)
        record_result service_started "IPNService became foreground; Tailnet reachability still requires a remote test"
        exit $?
        ;;
    1)
        record_result service_unconfirmed "No foreground IPNService after 10 seconds; unlock the phone and check login and VPN consent manually"
        exit 1
        ;;
    *)
        record_result service_check_failed "Cannot inspect Tailscale services after the connect request"
        exit 1
        ;;
esac
