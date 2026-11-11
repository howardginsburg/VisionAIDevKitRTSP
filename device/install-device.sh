#!/bin/sh
# Installs or removes the Vision AI DevKit RTSP add-on. Runs on the camera as root; install.ps1 /
# install.sh on your PC push this folder over ADB and run it.
#   install-device.sh install                  install; the camera then starts in setup mode
#   install-device.sh install --keep-settings  reinstall, keeping Wi-Fi, admin account and settings
#   install-device.sh uninstall                remove the add-on and its settings
# FORCE=1 installs on firmware other than v0.5370_Perf (untested).
set -e
SRC=$(cd "$(dirname "$0")" && pwd)
VAIDK_DIR=/opt/vaidk
DATA_DIR=/data/misc/vaidk
UNIT_DIR=/lib/systemd/system
VENDOR_BOOT=/vendor/etc/camera/InitCamx
# Each component's systemd unit, relative to /opt/vaidk.
UNITS="camera/vaidk-camera.service rtsp/vaidk-rtsp.service wifi/vaidk-wifi.service web/vaidk-web.service"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*"; exit 1; }

root_rw() { mount -o remount,rw /; trap 'mount -o remount,ro / 2>/dev/null' EXIT; }
root_ro() { sync; mount -o remount,ro / 2>/dev/null || log "note: / stays writable until the next restart"; trap - EXIT; }

stop_services() {
    for unit in $UNITS; do systemctl stop "${unit##*/}" 2>/dev/null || true; done
}

check_device() {
    [ "$(id -u)" = 0 ] || die "run this as root (adb shell)"
    [ -f "$VENDOR_BOOT" ] || die "this doesn't look like a Vision AI DevKit"
    if ! python3 "$SRC/boot/make-initcamx.py" --check "$VENDOR_BOOT" >/dev/null && [ "${FORCE:-0}" != 1 ]; then
        die "unexpected firmware ($(cat /etc/version 2>/dev/null)). This add-on was built for v0.5370_Perf. Set FORCE=1 to install anyway."
    fi
}

install_addon() {
    check_device
    keep=0
    if [ "$1" = --keep-settings ]; then keep=1; fi
    force=""
    if [ "${FORCE:-0}" = 1 ]; then force=--force; fi
    stop_services

    root_rw
    new="$VAIDK_DIR.new"
    rm -rf "$new"
    mkdir -p "$new"
    cp -R "$SRC/." "$new/"
    # The boot script is built from this camera's own vendor script; see boot/README.md.
    python3 "$new/boot/make-initcamx.py" $force "$VENDOR_BOOT" "$new/boot/InitCamx.vaidk" || die "couldn't build the boot script"
    chown -R root:root "$new"
    find "$new" -type d -exec chmod 755 {} \;
    find "$new" -type f -exec chmod 644 {} \;
    chmod 755 "$new"/*.sh "$new"/*/*.sh "$new/boot/InitCamx.vaidk" "$new/lights/docker" "$new/camera/vaidk-camd" \
        "$new"/web/www/cgi-bin/*.cgi
    bash -n "$new/boot/InitCamx.vaidk"
    for script in "$new"/*.sh "$new"/*/*.sh "$new"/web/www/cgi-bin/*.cgi "$new/lights/docker"; do sh -n "$script"; done
    python3 -c "compile(open('$new/rtsp/rtspd.py').read(), 'rtspd.py', 'exec')"
    [ "$(dd if="$new/camera/vaidk-camd" bs=1 skip=1 count=3 2>/dev/null)" = ELF ] \
        || die "camera/vaidk-camd is damaged (was it copied as text?)"
    rm -rf "$VAIDK_DIR"
    mv "$new" "$VAIDK_DIR"
    for unit in $UNITS; do
        name=${unit##*/}
        cp "$VAIDK_DIR/$unit" "$UNIT_DIR/$name"
        chmod 644 "$UNIT_DIR/$name"
        ln -sf "../$name" "$UNIT_DIR/multi-user.target.wants/$name"
    done
    mkdir -p "$UNIT_DIR/InitCamx.service.d"
    cp "$VAIDK_DIR/boot/InitCamx-vaidk.conf" "$UNIT_DIR/InitCamx.service.d/vaidk.conf"
    chmod 644 "$UNIT_DIR/InitCamx.service.d/vaidk.conf"
    root_ro

    if [ $keep = 0 ]; then sh "$VAIDK_DIR/web/ui.sh" forget; fi
    systemctl daemon-reload
    # The overlay clock's time zone lives in a qmmf-server drop-in (see camera/camd.sh).
    sh "$VAIDK_DIR/camera/camd.sh" tz || log "note: couldn't set qmmf-server's time zone"
    systemctl disable ipc-webserver.service >/dev/null 2>&1 || true
    killall websettings 2>/dev/null || true
    log "Installed the Vision AI DevKit RTSP add-on."
    if [ $keep = 1 ] && [ -s "$DATA_DIR/wpa_supplicant.conf" ]; then
        log "Kept the saved Wi-Fi network and settings."
    else
        log "After the restart, the camera opens its setup Wi-Fi network."
    fi
    log "VAIDK-OK"
}

uninstall_addon() {
    [ "$(id -u)" = 0 ] || die "run this as root (adb shell)"
    stop_services
    if [ -f "$VAIDK_DIR/web/ui.sh" ]; then sh "$VAIDK_DIR/web/ui.sh" forget || true; fi
    rm -rf "$DATA_DIR"
    root_rw
    for unit in $UNITS; do
        name=${unit##*/}
        rm -f "$UNIT_DIR/$name" "$UNIT_DIR/multi-user.target.wants/$name"
    done
    rm -f "$UNIT_DIR/InitCamx.service.d/vaidk.conf" "$UNIT_DIR/qmmf-server.service.d/vaidk.conf"
    rmdir "$UNIT_DIR/InitCamx.service.d" "$UNIT_DIR/qmmf-server.service.d" 2>/dev/null || true
    rm -rf "$VAIDK_DIR"
    root_ro
    systemctl daemon-reload
    systemctl enable ipc-webserver.service >/dev/null 2>&1 || true
    log "Removed the add-on. After the restart, the camera runs its original setup."
    log "VAIDK-OK"
}

case "$1" in
    install) install_addon "$2" ;;
    uninstall) uninstall_addon ;;
    *) sed -n '2,7p' "$0"; exit 2 ;;
esac
