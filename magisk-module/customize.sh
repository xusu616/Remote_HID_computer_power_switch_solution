#!/system/bin/sh
# Magisk / KernelSU / APatch customize.sh
. "$MODPATH/wake-bridge/common.sh"

[ -n "$BB" ] || abort "! BusyBox not found; cannot install wake_bridge"

ui_print "- Checking kernel USB HID Gadget support..."
if [ -r /proc/config.gz ] && [ -n "$BB" ]; then
    HID_CFG="$($BB zcat /proc/config.gz 2>/dev/null | $BB grep -E '^CONFIG_USB(_CONFIGFS)?_F_HID=' || true)"
    if [ -n "$HID_CFG" ]; then
        ui_print "  Kernel HID gadget enabled:"
        echo "$HID_CFG" | while IFS= read -r line; do
            ui_print "    $line"
        done
    else
        ui_print "! Warning: CONFIG_USB_F_HID not found in /proc/config.gz"
        ui_print "! USB keyboard wake may require a kernel with CONFIG_USB_CONFIGFS_F_HID=y"
    fi
else
    ui_print "  /proc/config.gz unavailable; skipping kernel config check"
fi

# Clean up legacy manual service.d hook if upgrading from manual install
if [ -f /data/adb/service.d/99-wake-bridge.sh ]; then
    ui_print "- Removing legacy /data/adb/service.d/99-wake-bridge.sh"
    rm -f /data/adb/service.d/99-wake-bridge.sh
fi

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"

choose_vol_key() {
    local default_val="$1"
    local up_val="${2:-1}"
    local down_val="${3:-0}"
    local fifo_base="${TMPDIR:-/dev}"
    local fifo="$fifo_base/.wake_bridge_key_$$"
    local res="" ge_pid timer_pid line

    if ! command -v getevent >/dev/null 2>&1 || [ -z "$BB" ]; then
        echo "$default_val"
        return 0
    fi

    rm -f "$fifo"
    if ! mkfifo "$fifo" 2>/dev/null; then
        fifo="/dev/.wake_bridge_key_$$"
        rm -f "$fifo"
        mkfifo "$fifo" 2>/dev/null || {
            echo "$default_val"
            return 0
        }
    fi

    getevent -lq > "$fifo" 2>/dev/null &
    ge_pid=$!
    (
        $BB sleep 8
        kill -9 "$ge_pid" 2>/dev/null
    ) &
    timer_pid=$!

    exec 3< "$fifo"
    while IFS= read -r line <&3; do
        case "$line" in
            *KEY_VOLUMEUP*DOWN*|*KEY_VOLUMEUP*00000001*)
                res="$up_val"
                break
                ;;
            *KEY_VOLUMEDOWN*DOWN*|*KEY_VOLUMEDOWN*00000001*)
                res="$down_val"
                break
                ;;
        esac
    done
    exec 3<&-
    kill -9 "$ge_pid" "$timer_pid" 2>/dev/null
    wait "$ge_pid" "$timer_pid" 2>/dev/null
    rm -f "$fifo"

    if [ -n "$res" ]; then
        echo "$res"
    else
        echo "$default_val"
    fi
}

IS_UPGRADE=0
DEFAULT_KEEP_ADB="0"
if [ -f "$DATA_DIR/config.env" ]; then
    IS_UPGRADE=1
    load_config
    DEFAULT_KEEP_ADB="$(normalize_keep_adb "${KEEP_ADB:-0}")"
fi

STEP1_DEFAULT="0"
[ "$DEFAULT_KEEP_ADB" != "0" ] && STEP1_DEFAULT="1"

ui_print " "
ui_print "- Step 1/2: Keep ADB debugging? (8s timeout):"
ui_print "  [Vol+] Keep ADB (select Wired+Wireless or Wireless-only next)"
ui_print "  [Vol-] Disable all ADB, pure USB HID only (KEEP_ADB=0)"
if [ "$IS_UPGRADE" = "1" ]; then
    ui_print "  (Timeout keeps existing setting: $(keep_adb_label "$DEFAULT_KEEP_ADB"))"
else
    ui_print "  (Timeout defaults to HID-only: KEEP_ADB=0)"
fi

KEEP_ADB_ENABLED="$(choose_vol_key "$STEP1_DEFAULT" "1" "0")"
if [ "$KEEP_ADB_ENABLED" = "1" ]; then
    STEP2_DEFAULT="1"
    [ "$DEFAULT_KEEP_ADB" = "2" ] && STEP2_DEFAULT="2"
    ui_print " "
    ui_print "- Step 2/2: Select ADB mode (8s timeout):"
    ui_print "  [Vol+] Composite Wired USB + Wireless ADB + HID (KEEP_ADB=1)"
    ui_print "  [Vol-] Wireless-only ADB + Pure Wired USB HID (KEEP_ADB=2)"
    ui_print "  (Timeout defaults to: $(keep_adb_label "$STEP2_DEFAULT"))"
    SELECTED_KEEP_ADB="$(choose_vol_key "$STEP2_DEFAULT" "1" "2")"
else
    SELECTED_KEEP_ADB="0"
fi
ui_print "  -> Selected: KEEP_ADB=$(keep_adb_label "$SELECTED_KEEP_ADB")"

if [ "$IS_UPGRADE" = "0" ]; then
    RAND_TOKEN="$($BB dd if=/dev/urandom bs=12 count=1 2>/dev/null | $BB od -An -tx1 | $BB tr -d ' \n\r')"
    case "$RAND_TOKEN" in
        *[!0-9a-f]*|'') abort "! Failed to generate a random authentication token" ;;
    esac
    [ "${#RAND_TOKEN}" -eq 24 ] || abort "! Random authentication token must contain 24 hexadecimal characters"
    cat > "$DATA_DIR/config.env" <<EOF
PORT=9876
TOKEN=$RAND_TOKEN
TAILSCALE_ONLY=0
KEEP_ADB=$SELECTED_KEEP_ADB
AUTO_HID_ON_BOOT=1
AUTO_TAILSCALE_ON_BOOT=1
HID_WATCHDOG=1
DAEMON_WAKE_LOCK=1
UDC_NAME=
USB_CONFIG=
EOF
    ui_print "- Generated new config at $DATA_DIR/config.env"
else
    if $BB grep -q '^KEEP_ADB=' "$DATA_DIR/config.env" 2>/dev/null; then
        $BB sed -i "s/^KEEP_ADB=.*/KEEP_ADB=$SELECTED_KEEP_ADB/" "$DATA_DIR/config.env"
    else
        echo "KEEP_ADB=$SELECTED_KEEP_ADB" >> "$DATA_DIR/config.env"
    fi
    ui_print "- Updated KEEP_ADB=$SELECTED_KEEP_ADB in existing $DATA_DIR/config.env"
fi
if ! $BB grep -q '^DAEMON_WAKE_LOCK=' "$DATA_DIR/config.env"; then
    echo "DAEMON_WAKE_LOCK=1" >> "$DATA_DIR/config.env"
fi
if ! $BB grep -q '^AUTO_TAILSCALE_ON_BOOT=' "$DATA_DIR/config.env"; then
    echo "AUTO_TAILSCALE_ON_BOOT=1" >> "$DATA_DIR/config.env"
fi
if ! $BB grep -q '^USB_PRODUCT_ID=' "$DATA_DIR/config.env"; then
    echo "USB_PRODUCT_ID=" >> "$DATA_DIR/config.env"
fi
chmod 600 "$DATA_DIR/config.env"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/system/bin/wake-bridge" 0 0 0755
set_perm "$MODPATH/wake-bridge/common.sh" 0 0 0644
set_perm "$MODPATH/wake-bridge/cgi-auth.sh" 0 0 0644
set_perm "$MODPATH/wake-bridge/setup-hid.sh" 0 0 0755
set_perm "$MODPATH/wake-bridge/wake.sh" 0 0 0755
set_perm "$MODPATH/wake-bridge/hid-watchdog.sh" 0 0 0755
set_perm "$MODPATH/wake-bridge/start-daemon.sh" 0 0 0755
set_perm "$MODPATH/wake-bridge/start-tailscale.sh" 0 0 0755
set_perm "$MODPATH/wake-bridge/stop-daemon.sh" 0 0 0755
set_perm "$MODPATH/wake-bridge/www/cgi-bin/wake" 0 0 0755
set_perm "$MODPATH/wake-bridge/www/cgi-bin/status" 0 0 0755

. "$DATA_DIR/config.env"
ui_print "- Port: ${PORT:-9876}"
ui_print "- Authentication token retained in protected config; use wake-bridge url explicitly when needed"
ui_print "- DAEMON_WAKE_LOCK: ${DAEMON_WAKE_LOCK:-1}; HID_WATCHDOG: ${HID_WATCHDOG:-1}"
ui_print "- AUTO_TAILSCALE_ON_BOOT: ${AUTO_TAILSCALE_ON_BOOT:-1}"
ui_print "- USB_PRODUCT_ID: ${USB_PRODUCT_ID:-ROM default}"
ui_print "- Reboot to activate module, then run: su -c wake-bridge url"
