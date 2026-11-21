#!/system/bin/sh
MOD_WAKE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$MOD_WAKE_DIR/common.sh"
load_config

# Explicit device compatibility setting, not a project-owned USB product ID.
if [ -n "${USB_PRODUCT_ID:-}" ]; then
    if ! printf '%s\n' "$USB_PRODUCT_ID" | $BB grep -Eq '^0x[0-9a-fA-F]{4}$'; then
        echo "wake_bridge: USB_PRODUCT_ID must be empty or 0x followed by four hexadecimal digits" >&2
        exit 1
    fi
    USB_PRODUCT_ID="$(printf '%s' "$USB_PRODUCT_ID" | $BB tr 'A-F' 'a-f')"
fi

FORCE=0
FORCE_HID_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        --hid-only) FORCE_HID_ONLY=1 ;;
    esac
done

G1="/config/usb_gadget/g1"
HID_DIR="$G1/functions/hid.usb0"
# Standard 45-byte input-only USB HID Boot Keyboard report descriptor (no LED OUT report)
DESC_B64="BQEJBqEBBQcZ4CnnFQAlAXUBlQiBApUBdQiBAZUGdQgVACVlBQcZACllgQDA"

UDC="$(detect_udc)" || exit 1
CFG="$(detect_usb_cfg)" || exit 1

mkdir -p "$DATA_DIR"

LOCK_DIR="$DATA_DIR/setup.lock"
acquire_lock() {
    local tries=0 lock_pid=""
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        lock_pid="$($BB cat "$LOCK_DIR/pid" 2>/dev/null)"
        if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
            rm -rf "$LOCK_DIR"
            continue
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 200 ]; then
            rm -rf "$LOCK_DIR"
            mkdir "$LOCK_DIR" 2>/dev/null || return 1
            break
        fi
        $BB usleep 50000
    done
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    trap 'rm -rf "$LOCK_DIR"' EXIT
    trap 'rm -rf "$LOCK_DIR"; exit 130' INT TERM HUP
}

acquire_lock || exit 1

check_usb_state_before_rebuild() {
    local usb_state
    if ! usb_state="$($BB cat "/sys/class/udc/$UDC/state")"; then
        echo "wake_bridge: 无法读取 USB 控制器状态，请检查 UDC 配置、状态节点和 root 权限" >&2
        return 1
    fi
    if [ "$usb_state" = "suspended" ]; then
        echo "wake_bridge: 电脑的 USB 已挂起，请先唤醒电脑再修复 ADB/HID" >&2
        return 2
    fi
}
check_usb_state_before_rebuild || exit $?
mkdir -p "$HID_DIR" || exit 1

ensure_hidg_dev() {
    [ -r "$HID_DIR/dev" ] || return 1
    local dev_mm maj min cur_mm
    dev_mm="$($BB cat "$HID_DIR/dev" 2>/dev/null)"
    maj="${dev_mm%%:*}"
    min="${dev_mm##*:}"
    [ -n "$maj" ] && [ -n "$min" ] || return 1
    cur_mm=""
    if [ -c /dev/hidg0 ]; then
        cur_mm="$($BB ls -ln /dev/hidg0 2>/dev/null | $BB awk '{gsub(/,/,"",$5); print $5":"$6}')"
    fi
    if [ ! -c /dev/hidg0 ] || [ "$cur_mm" != "$maj:$min" ]; then
        rm -f /dev/hidg0
        mknod /dev/hidg0 c "$maj" "$min" 2>/dev/null || return 1
    fi
    chmod 660 /dev/hidg0 2>/dev/null || true
    [ -c /dev/hidg0 ]
}

ADB_MODE="$(normalize_keep_adb "${KEEP_ADB:-0}")"
if [ "$FORCE_HID_ONLY" = "1" ]; then
    ADB_MODE="2"
fi

WANT_ADB=0
if [ "$ADB_MODE" = "1" ] && want_adb_in_gadget; then
    WANT_ADB=1
fi

ensure_ffs_adb_mounted() {
    [ -e /dev/usb-ffs/adb/ep0 ] && return 0
    mkdir -p /dev/usb-ffs/adb 2>/dev/null || true
    mount -t functionfs adb /dev/usb-ffs/adb -o rmode=0770,fmode=0660,uid=2000,gid=2000,no_disconnect=1 2>/dev/null \
        || mount -t functionfs adb /dev/usb-ffs/adb -o uid=2000,gid=2000 2>/dev/null \
        || true
    [ -e /dev/usb-ffs/adb/ep0 ]
}

wait_for_adbd_ffs_ready() {
    local tries=0
    if [ "$(getprop sys.usb.config 2>/dev/null)" != "adb" ]; then
        setprop sys.usb.config adb 2>/dev/null || true
    fi
    if [ "$(getprop init.svc.adbd 2>/dev/null)" != "running" ] && ! $BB pgrep -x adbd >/dev/null 2>&1; then
        setprop ctl.start adbd 2>/dev/null || true
    fi
    while [ "$tries" -lt 15 ]; do
        if [ "$(getprop sys.usb.ffs.ready 2>/dev/null)" = "1" ] && [ "$(getprop sys.usb.state 2>/dev/null)" = "adb" ]; then
            # Android init has finished its stock ADB binding and identity writes.
            return 0
        fi
        $BB usleep 100000
        tries=$((tries + 1))
    done
    return 1
}

is_gadget_ready() {
    local hid_linked=0 adb_linked=0 other_linked=0 cur_bm cur_udc f target
    for f in "$CFG"/f*; do
        [ -L "$f" ] || continue
        target="$($BB readlink "$f" 2>/dev/null)"
        case "$target" in
            *hid.usb0) hid_linked=1 ;;
            *ffs.adb) adb_linked=1 ;;
            *) other_linked=1 ;;
        esac
    done
    cur_bm="$($BB cat "$CFG/bmAttributes" 2>/dev/null)"
    cur_udc="$($BB cat "$G1/UDC" 2>/dev/null)"

    [ "$hid_linked" = "1" ] || return 1
    [ "$adb_linked" = "$WANT_ADB" ] || return 1
    case "$($BB readlink "$CFG/f1" 2>/dev/null)" in *hid.usb0) ;; *) return 1 ;; esac
    if [ "$WANT_ADB" = "1" ]; then
        case "$($BB readlink "$CFG/f2" 2>/dev/null)" in *ffs.adb) ;; *) return 1 ;; esac
    fi
    if [ -n "${USB_PRODUCT_ID:-}" ]; then
        [ "$($BB cat "$G1/idProduct" 2>/dev/null)" = "$USB_PRODUCT_ID" ] || return 1
    fi
    [ "$other_linked" = "0" ] || return 1
    [ "$cur_bm" = "0xa0" ] || return 1
    [ "$cur_udc" = "$UDC" ] || return 1
    return 0
}

if [ "$FORCE" = "0" ] && is_gadget_ready && ensure_hidg_dev; then
    exit 0
fi

apply_gadget_links() {
    # Creation order determines USB interface numbers: HID=0, ADB=1.
    # The Windows ADB driver must own its interface, not the composite parent.
    local f
    for f in "$CFG"/f*; do
        [ -L "$f" ] && rm -f "$f"
    done
    ln -s "$HID_DIR" "$CFG/f1" || return 1
    if [ "$WANT_ADB" = "1" ]; then
        ln -s "$G1/functions/ffs.adb" "$CFG/f2" || return 1
    fi
    [ -z "$($BB cat "$G1/UDC" 2>/dev/null)" ]
}

ATTEMPT=1
SUCCESS=0
while [ "$ATTEMPT" -le 3 ]; do
    if [ "$WANT_ADB" = "1" ]; then
        if ! ensure_ffs_adb_mounted || ! wait_for_adbd_ffs_ready; then
            echo "wake_bridge: Android ADB initialization did not complete; USB gadget was not rebuilt" >&2
            exit 1
        fi
    else
        # Set sys.usb.config=hid (instead of none) so init.usb.configfs.rc neither
        # re-links ffs.adb nor runs the sys.usb.config=none rule that deletes b.1/f1.
        setprop sys.usb.config hid 2>/dev/null || true
        setprop sys.usb.state hid 2>/dev/null || true
    fi

    # The host can suspend while Android ADB initialization is being awaited.
    check_usb_state_before_rebuild || exit $?
    # ConfigFS function links and descriptors may only change after unbinding.
    if ! echo "" > "$G1/UDC"; then
        echo "wake_bridge: cannot unbind USB before rebuilding HID" >&2
        exit 1
    fi
    for f in "$CFG"/f*; do
        [ -L "$f" ] && rm -f "$f"
    done
    $BB usleep 100000

    if [ "$WANT_ADB" = "0" ] && [ "$ADB_MODE" = "2" ]; then
        # Wait briefly after unbinding UDC and unlinking ffs.adb so adbd closes ep0
        # before unmounting functionfs (avoids -EBUSY if switching back to KEEP_ADB=1).
        $BB usleep 150000
        umount -l /dev/usb-ffs/adb 2>/dev/null || true
    fi

    if [ -f "$HID_DIR/no_out_endpoint" ]; then
        echo 0 > "$HID_DIR/no_out_endpoint" 2>/dev/null || true
    fi
    echo 1 > "$HID_DIR/protocol"
    echo 1 > "$HID_DIR/subclass"
    echo 8 > "$HID_DIR/report_length"
    echo "$DESC_B64" | $BB base64 -d > "$HID_DIR/report_desc"

    # Enable Remote Wakeup bit (0x80 | 0x20 = 0xa0)
    echo 0xa0 > "$CFG/bmAttributes"

    # Unbind immediately before linking so init's UDC writes don't stick without hid.usb0
    if [ -n "$($BB cat "$G1/UDC" 2>/dev/null)" ]; then
        echo "" > "$G1/UDC" 2>/dev/null || true
    fi

    if ! apply_gadget_links; then
        echo "" > "$G1/UDC" 2>/dev/null || true
        $BB usleep 50000
        if ! apply_gadget_links; then
            echo "" > "$G1/UDC" 2>/dev/null || true
        fi
    fi

    # Do not re-run the Android ADB init trigger after arranging our interfaces.
    if [ -n "${USB_PRODUCT_ID:-}" ]; then
        if ! echo "$USB_PRODUCT_ID" > "$G1/idProduct"; then
            echo "wake_bridge: cannot apply the configured USB product ID" >&2
            exit 1
        fi
    fi

    echo 0xa0 > "$CFG/bmAttributes" 2>/dev/null || true

    if [ "$($BB cat "$G1/UDC" 2>/dev/null)" != "$UDC" ]; then
        echo "$UDC" > "$G1/UDC" 2>/dev/null || true
    fi
    $BB usleep 300000

    if is_gadget_ready && ensure_hidg_dev; then
        SUCCESS=1
        break
    fi

    ATTEMPT=$((ATTEMPT + 1))
    $BB usleep 200000
done

if [ "$WANT_ADB" = "1" ] || [ "$ADB_MODE" = "2" ]; then
    if [ "$(getprop init.svc.adbd 2>/dev/null)" != "running" ] && ! $BB pgrep -x adbd >/dev/null 2>&1; then
        setprop ctl.start adbd 2>/dev/null || true
    fi
elif [ "$ADB_MODE" = "0" ]; then
    if [ "$(getprop init.svc.adbd 2>/dev/null)" = "running" ] || $BB pgrep -x adbd >/dev/null 2>&1; then
        setprop ctl.stop adbd 2>/dev/null || true
    fi
fi

[ "$SUCCESS" = "1" ] && exit 0
ensure_hidg_dev >/dev/null 2>&1 || true
exit 1
