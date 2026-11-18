#!/bin/sh
# Vision AI DevKit RTSP add-on: starts the RTSP server (rtspd.py) with the stream sign-in settings.
. /opt/vaidk/common.sh
load_settings
export STREAM_AUTH STREAM_REALM STREAM_KEY_FILE ADMIN_FILE
exec /usr/bin/python3 "$VAIDK_DIR/rtsp/rtspd.py"
