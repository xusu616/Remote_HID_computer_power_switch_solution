#!/system/bin/sh
# Magisk / KernelSU / APatch customize.sh
. "$MODPATH/wake-bridge/common.sh"

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

if [ ! -f "$DATA_DIR/config.env" ]; then
    RAND_TOKEN="$($BB dd if=/dev/urandom bs=12 count=1 2>/dev/null | $BB od -An -tx1 | $BB tr -d ' \n\r')"
    [ -z "$RAND_TOKEN" ] && RAND_TOKEN="changeme1234567890abcdef"
    cat > "$DATA_DIR/config.env" <<EOF
PORT=9876
TOKEN=$RAND_TOKEN
TAILSCALE_ONLY=0
KEEP_ADB=1
AUTO_HID_ON_BOOT=1
UDC_NAME=
USB_CONFIG=
EOF
    ui_print "- Generated new config at $DATA_DIR/config.env"
else
    ui_print "- Keeping existing config at $DATA_DIR/config.env"
fi
chmod 600 "$DATA_DIR/config.env"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/system/bin/wake-bridge" 0 0 0755
set_perm "$MODPATH/wake-bridge/common.sh" 0 0 0644
set_perm "$MODPATH/wake-bridge/cgi-auth.sh" 0 0 0644
set_perm "$MODPATH/wake-bridge/setup-hid.sh" 0 0 0755
set_perm "$MODPATH/wake-bridge/wake.sh" 0 0 0755
set_perm "$MODPATH/wake-bridge/start-daemon.sh" 0 0 0755
set_perm "$MODPATH/wake-bridge/stop-daemon.sh" 0 0 0755
set_perm "$MODPATH/wake-bridge/www/cgi-bin/wake" 0 0 0755
set_perm "$MODPATH/wake-bridge/www/cgi-bin/status" 0 0 0755

. "$DATA_DIR/config.env"
ui_print "- Port: ${PORT:-9876}"
ui_print "- Token: $TOKEN"
ui_print "- Reboot to activate module, then run: su -c wake-bridge url"
