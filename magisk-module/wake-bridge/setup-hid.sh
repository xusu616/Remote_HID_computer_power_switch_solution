#!/system/bin/sh
MOD_WAKE_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$MOD_WAKE_DIR/common.sh"
load_config

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

mkdir -p "$DATA_DIR" "$HID_DIR"

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
        if [ "$tries" -ge 60 ]; then
            rm -rf "$LOCK_DIR"
            mkdir "$LOCK_DIR" 2>/dev/null || return 1
            break
        fi
        $BB usleep 50000
    done
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
}

acquire_lock || exit 1

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
    mount -t functionfs adb /dev/usb-ffs/adb -o uid=2000,gid=2000 2>/dev/null || true
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
        if [ "$(getprop sys.usb.ffs.ready 2>/dev/null)" = "1" ]; then
            # Allow init.usb.configfs.rc property trigger (if any) to settle
            $BB usleep 50000
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
    [ "$other_linked" = "0" ] || return 1
    [ "$cur_bm" = "0xa0" ] || return 1
    [ "$cur_udc" = "$UDC" ] || return 1
    return 0
}

if [ "$FORCE" = "0" ] && is_gadget_ready && ensure_hidg_dev; then
    exit 0
fi

apply_gadget_links() {
    local f before_hid_udc
    if [ "$WANT_ADB" = "1" ]; then
        for f in "$CFG"/f*; do
            [ -L "$f" ] || continue
            case "${f##*/}" in
                f1)
                    case "$($BB readlink "$f" 2>/dev/null)" in
                        *ffs.adb) ;;
                        *) rm -f "$f" ;;
                    esac
                    ;;
                *) rm -f "$f" ;;
            esac
        done
        [ -L "$CFG/f1" ] || ln -s "$G1/functions/ffs.adb" "$CFG/f1"
        before_hid_udc="$($BB cat "$G1/UDC" 2>/dev/null)"
        ln -s "$HID_DIR" "$CFG/f2"
    else
        for f in "$CFG"/f*; do
            [ -L "$f" ] && rm -f "$f"
        done
        before_hid_udc="$($BB cat "$G1/UDC" 2>/dev/null)"
        ln -s "$HID_DIR" "$CFG/f1"
    fi
    # If Android init bound UDC before hid.usb0 was linked, force a clean rebind below
    [ -z "$before_hid_udc" ]
}

ATTEMPT=1
SUCCESS=0
while [ "$ATTEMPT" -le 3 ]; do
    if [ "$WANT_ADB" = "1" ]; then
        ensure_ffs_adb_mounted
    elif [ "$ADB_MODE" = "2" ]; then
        # Prevent init.usb.configfs.rc from stopping adbd or re-binding ffs.adb
        setprop sys.usb.config hid 2>/dev/null || true
        setprop sys.usb.state hid 2>/dev/null || true
        if [ "$FORCE_HID_ONLY" = "0" ]; then
            umount -l /dev/usb-ffs/adb 2>/dev/null || true
        fi
    else
        setprop sys.usb.config none 2>/dev/null || true
        setprop sys.usb.state none 2>/dev/null || true
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

    if [ "$WANT_ADB" = "1" ]; then
        # Start adbd and wait up to 1.5s for sys.usb.ffs.ready=1 BEFORE binding UDC
        # so HID does not enumerate ahead of adbd and get reset mid-handshake.
        wait_for_adbd_ffs_ready || true
        [ -L "$CFG/f1" ] || ln -s "$G1/functions/ffs.adb" "$CFG/f1" 2>/dev/null || true
        [ -L "$CFG/f2" ] || ln -s "$HID_DIR" "$CFG/f2" 2>/dev/null || true
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
