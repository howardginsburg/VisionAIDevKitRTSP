# Shared paths and helpers for the Vision AI DevKit RTSP add-on (sourced by its scripts).
VAIDK_DIR=/opt/vaidk
DATA_DIR=/data/misc/vaidk
RUN_DIR=/run/vaidk
SETTINGS_FILE=$DATA_DIR/vaidk.conf
WIFI_CONF=$DATA_DIR/wpa_supplicant.conf
ADMIN_FILE=$DATA_DIR/admin
AP_PREFIX=192.168.143.

load_settings() {
    . "$VAIDK_DIR/defaults.conf"
    if [ -f "$SETTINGS_FILE" ]; then . "$SETTINGS_FILE"; fi
}

set_setting() { # set_setting KEY VALUE (VALUE must already be validated)
    mkdir -p "$DATA_DIR" && chmod 700 "$DATA_DIR"
    {
        if [ -f "$SETTINGS_FILE" ]; then grep -v "^$1=" "$SETTINGS_FILE"; fi
        printf '%s=%s\n' "$1" "$2"
    } > "$SETTINGS_FILE.tmp" && chmod 600 "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
}

uptime_s() { cut -d. -f1 /proc/uptime; }
wlan_ip() { ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n 1; }
admin_user() { if [ -f "$ADMIN_FILE" ]; then cut -d' ' -f1 "$ADMIN_FILE"; fi; }

with_rw_root() { # with_rw_root COMMAND...: runs it with the read-only root file system writable
    was_ro=0
    if grep -q '^[^ ]* / [^ ]* ro[, ]' /proc/mounts; then was_ro=1; mount -o remount,rw /; fi
    "$@"; rc=$?
    if [ $was_ro = 1 ]; then sync; mount -o remount,ro / 2>/dev/null; fi
    return $rc
}
