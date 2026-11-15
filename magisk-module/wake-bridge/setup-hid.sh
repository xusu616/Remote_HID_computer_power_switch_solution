#!/system/bin/sh
MOD_WAKE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$MOD_WAKE_DIR/common.sh"
load_config

G1="/config/usb_gadget/g1"
HID_DIR="$G1/functions/hid.usb0"
# Standard 63-byte USB HID Boot Keyboard report descriptor
DESC_B64="BQEJBqEBBQcZ4CnnFQAlAXUBlQiBApUBdQiBAZUFdQEFCBkBKQWRApUBdQORAZUGdQgVACVlBQcZACllgQDA"

UDC="$(detect_udc)" || exit 1
CFG="$(detect_usb_cfg)" || exit 1

mkdir -p "$HID_DIR"

ensure_hidg_dev() {
    if [ ! -c /dev/hidg0 ] && [ -r "$HID_DIR/dev" ]; then
        DEV_MM="$($BB cat "$HID_DIR/dev" 2>/dev/null)"
        MAJ="${DEV_MM%%:*}"
        MIN="${DEV_MM##*:}"
        if [ -n "$MAJ" ] && [ -n "$MIN" ]; then
            rm -f /dev/hidg0
            mknod /dev/hidg0 c "$MAJ" "$MIN"
        fi
    fi
    [ -c /dev/hidg0 ] && chmod 660 /dev/hidg0
}

WANT_ADB=0
case "${KEEP_ADB:-1}" in
    1|auto)
        if [ -d "$G1/functions/ffs.adb" ] && is_usb_adb_enabled; then
            WANT_ADB=1
        fi
        ;;
esac

HID_LINKED=0
ADB_LINKED=0
OTHER_LINKED=0
for f in "$CFG"/f*; do
    [ -L "$f" ] || continue
    case "$($BB readlink "$f" 2>/dev/null)" in
        *hid.usb0) HID_LINKED=1 ;;
        *ffs.adb) ADB_LINKED=1 ;;
        *) OTHER_LINKED=1 ;;
    esac
done
CUR_BM="$($BB cat "$CFG/bmAttributes" 2>/dev/null)"
CUR_UDC="$($BB cat "$G1/UDC" 2>/dev/null)"

if [ "$HID_LINKED" = "1" ] && [ "$ADB_LINKED" = "$WANT_ADB" ] && [ "$OTHER_LINKED" = "0" ] && [ "$CUR_BM" = "0xa0" ] && [ "$CUR_UDC" = "$UDC" ]; then
    ensure_hidg_dev
    if [ -c /dev/hidg0 ]; then
        exit 0
    fi
fi

# Unlink hid.usb0 before updating descriptors
for f in "$CFG"/f*; do
    [ -L "$f" ] || continue
    case "$($BB readlink "$f" 2>/dev/null)" in
        *hid.usb0) rm -f "$f" ;;
    esac
done

echo "" > "$G1/UDC" 2>/dev/null || true
$BB usleep 100000

echo 1 > "$HID_DIR/protocol"
echo 1 > "$HID_DIR/subclass"
echo 8 > "$HID_DIR/report_length"
echo "$DESC_B64" | $BB base64 -d > "$HID_DIR/report_desc"

# Enable Remote Wakeup bit (0x80 | 0x20 = 0xa0)
echo 0xa0 > "$CFG/bmAttributes"

# If Android init rebound UDC while hid.usb0 was unlinked, unbind again before linking
PRE_LINK_UDC="$($BB cat "$G1/UDC" 2>/dev/null)"
if [ -n "$PRE_LINK_UDC" ]; then
    echo "" > "$G1/UDC" 2>/dev/null || true
    $BB usleep 50000
fi

if [ "$WANT_ADB" = "1" ]; then
    case "$($BB readlink "$CFG/f1" 2>/dev/null)" in
        *ffs.adb) ;;
        *)
            rm -f "$CFG/f1"
            ln -s "$G1/functions/ffs.adb" "$CFG/f1"
            ;;
    esac
    rm -f "$CFG/f2"
    ln -s "$HID_DIR" "$CFG/f2"
else
    for f in "$CFG"/f*; do
        [ -L "$f" ] && rm -f "$f"
    done
    ln -s "$HID_DIR" "$CFG/f1"
fi

# Rebind only if Android init has not already rebound UDC after links were created
CUR_UDC="$($BB cat "$G1/UDC" 2>/dev/null)"
if [ "$CUR_UDC" != "$UDC" ]; then
    echo "$UDC" > "$G1/UDC" 2>/dev/null || true
fi
$BB usleep 300000

ensure_hidg_dev

if [ "$WANT_ADB" = "1" ]; then
    if ! $BB pgrep -x adbd >/dev/null 2>&1; then
        setprop ctl.start adbd
    fi
fi
exit 0
