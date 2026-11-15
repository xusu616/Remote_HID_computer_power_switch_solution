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
