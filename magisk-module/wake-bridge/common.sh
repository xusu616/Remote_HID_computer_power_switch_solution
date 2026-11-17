#!/system/bin/sh
export PATH="/system/bin:/system/xbin:/vendor/bin:/sbin:/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:$PATH"

DATA_DIR="/data/adb/wake-bridge"

find_busybox() {
    for p in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /system/xbin/busybox /system/bin/busybox; do
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    command -v busybox 2>/dev/null || return 1
}

BB="$(find_busybox)"

load_config() {
    if [ -f "$DATA_DIR/config.env" ]; then
        . "$DATA_DIR/config.env"
    fi
}

detect_udc() {
    if [ -n "$UDC_NAME" ] && [ -d "/sys/class/udc/$UDC_NAME" ]; then
        echo "$UDC_NAME"
        return 0
    fi
    for d in /sys/class/udc/*; do
        [ -e "$d" ] || continue
        echo "${d##*/}"
        return 0
    done
    return 1
}

detect_usb_cfg() {
    local g1="/config/usb_gadget/g1"
    if [ -n "$USB_CONFIG" ] && [ -d "$g1/configs/$USB_CONFIG" ]; then
        echo "$g1/configs/$USB_CONFIG"
        return 0
    fi
    if [ -d "$g1/configs/b.1" ]; then
        echo "$g1/configs/b.1"
        return 0
    fi
    for d in "$g1"/configs/*; do
        [ -d "$d" ] || continue
        echo "$d"
        return 0
    done
    return 1
}

is_usb_adb_enabled() {
    local adb_setting cfg
    adb_setting="$(settings get global adb_enabled 2>/dev/null)"
    [ -n "$BB" ] && adb_setting="$(printf '%s' "$adb_setting" | $BB tr -d ' \t\r\n')"
    case "$adb_setting" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    for cfg in "$(getprop sys.usb.config 2>/dev/null)" "$(getprop persist.sys.usb.config 2>/dev/null)"; do
        case ",$cfg," in
            *,adb,*) return 0 ;;
        esac
    done
    return 1
}

normalize_keep_adb() {
    case "${1:-${KEEP_ADB:-0}}" in
        1|auto|usb|on|true) echo "1" ;;
        2|wireless|wifi) echo "2" ;;
        *) echo "0" ;;
    esac
}

keep_adb_label() {
    case "$(normalize_keep_adb "${1:-${KEEP_ADB:-0}}")" in
        1) echo "1 (composite wired + wireless ADB)" ;;
        2) echo "2 (wireless-only ADB + pure USB HID)" ;;
        *) echo "0 (HID-only, ADB disabled)" ;;
    esac
}

want_adb_in_gadget() {
    local g1="/config/usb_gadget/g1"
    case "$(normalize_keep_adb "${KEEP_ADB:-0}")" in
        1)
            [ -d "$g1/functions/ffs.adb" ] && is_usb_adb_enabled && return 0
            ;;
    esac
    return 1
}

write_hid_b64() {
    local b64="$1"
    local timeout_secs="${2:-1}"
    local oct=""
    [ -c /dev/hidg0 ] || return 1
    case "$b64" in
        AgAAAAAAAAA=) oct='\002\000\000\000\000\000\000\000' ;;
        AAAAAAAAAAA=) oct='\000\000\000\000\000\000\000\000' ;;
    esac
    if [ -n "$oct" ]; then
        # Use shell builtin printf directly without a pipeline so timeout SIGTERM
        # kills the writer process itself and never leaves orphaned base64 processes.
        $BB timeout "$timeout_secs" $BB sh -c "printf '$oct' > /dev/hidg0" 2>/dev/null
    else
        $BB timeout "$timeout_secs" $BB sh -c "echo '$b64' | exec $BB base64 -d > /dev/hidg0" 2>/dev/null
    fi
}
