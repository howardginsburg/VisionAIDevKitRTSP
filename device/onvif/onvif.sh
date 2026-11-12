#!/bin/sh
# Vision AI DevKit RTSP add-on: starts the ONVIF service (onvifd.py), which gives Frigate, Home Assistant
# and NVRs digital pan, tilt and zoom. With ONVIF=0 it shows the whole picture again and exits.
. /opt/vaidk/common.sh
load_settings
mkdir -p "$RUN_DIR"
if [ "$ONVIF" != 1 ]; then
    rm -f "$RUN_DIR/ptz.conf"
    systemctl kill -s USR2 --kill-who=main vaidk-camera.service 2>/dev/null
    exit 0
fi
export ONVIF_PORT
exec /usr/bin/python3 "$VAIDK_DIR/onvif/onvifd.py"
