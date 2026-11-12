#!/bin/sh
# Vision AI DevKit RTSP add-on: starts the camera program (vaidk-camd) with the saved settings.
# vaidk-camd sends the streams to the RTSP server (rtspd.py) and exits when the camera pipeline
# fails; vaidk-camera.service then starts it again with a fresh camera session.
#   camd.sh          start vaidk-camd (vaidk-camera.service runs this)
#   camd.sh reload   apply the settings that change while streaming: picture and speaker
#   camd.sh chime    play a test chime on the speaker
#   camd.sh tz       put TIME_ZONE into qmmf-server's environment (restarts it if it changed)
. /opt/vaidk/common.sh
load_settings

LIVE_FILE=$RUN_DIR/camd.conf
TZ_DROPIN=/lib/systemd/system/qmmf-server.service.d/vaidk.conf

write_live() { # the settings vaidk-camd re-reads on SIGHUP
    mkdir -p "$RUN_DIR"
    printf 'ANTIFLICKER=%s\nEXPOSURE_EV=%s\nWHITE_BALANCE=%s\nSATURATION=%s\nSHARPNESS=%s\nSPEAKER_VOLUME=%s\nTALKBACK_MUTE_MIC=%s\n' \
        "$ANTIFLICKER" "$EXPOSURE_EV" "$WHITE_BALANCE" "$SATURATION" "$SHARPNESS" "$SPEAKER_VOLUME" "$TALKBACK_MUTE_MIC" \
        > "$LIVE_FILE.tmp" && mv "$LIVE_FILE.tmp" "$LIVE_FILE"
}
signal_camd() { systemctl kill -s "$1" --kill-who=main vaidk-camera.service 2>/dev/null; return 0; }

# qmmf-server draws the date and time on the video in its own time zone. The camera has no time zone
# database, so TIME_ZONE is a POSIX TZ string that a drop-in puts in qmmf-server's environment.
write_tz() {
    mkdir -p "${TZ_DROPIN%/*}" && printf '%s\n' \
        "# Vision AI DevKit RTSP add-on: time zone for the date and time on the video (TIME_ZONE setting)." \
        "[Service]" "Environment=TZ=$TIME_ZONE" > "$TZ_DROPIN" && chmod 644 "$TZ_DROPIN"
}

case "$1" in
    reload) write_live; signal_camd HUP; exit 0 ;;
    chime) signal_camd USR1; exit 0 ;;
    tz)
        if grep -qxF "Environment=TZ=$TIME_ZONE" "$TZ_DROPIN" 2>/dev/null; then exit 0; fi
        with_rw_root write_tz || exit 1
        systemctl daemon-reload
        systemctl try-restart qmmf-server.service
        exit 0 ;;
esac

# A reload, chime or zoom update that arrives before vaidk-camd runs must not stop the service. They are
# ignored rather than trapped: an ignored signal stays ignored across exec until vaidk-camd handles it.
trap '' HUP USR1 USR2

# The vendor preview server would compete for the camera.
if [ "$STOP_IPC_WEBSERVER" = 1 ] && systemctl -q is-active ipc-webserver.service; then
    systemctl stop ipc-webserver.service
fi

# Shortly after it starts, the vendor media server runs an audio calibration step that holds the
# microphone for a moment. At boot, wait for it so the microphone track can be created.
webserver_age() { # seconds since qmmf-webserver started; empty when it isn't running
    systemctl -q is-active qmmf-webserver.service || return 0
    since=$(systemctl show -p ActiveEnterTimestampMonotonic qmmf-webserver.service | cut -d= -f2)
    case "$since" in ''|*[!0-9]*) return 0 ;; esac
    echo $(( $(uptime_s) - since / 1000000 ))
}
waited=0
while [ "$waited" -lt 40 ]; do
    age=$(webserver_age)
    if ! pidof http_interface_gtest >/dev/null && { [ -z "$age" ] || [ "$age" -ge 20 ]; }; then break; fi
    sleep 1
    waited=$((waited + 1))
done

write_live
export MAIN_WIDTH MAIN_HEIGHT MAIN_FPS MAIN_BITRATE MAIN_CODEC
export SUB_ENABLED SUB_WIDTH SUB_HEIGHT SUB_FPS SUB_BITRATE
export AUDIO_ENABLED AUDIO_BITRATE KEYFRAME_SECONDS
export NAME OVERLAY OVERLAY_POSITION OVERLAY_STREAMS
export CAMD_SOCKET="$RUN_DIR/media.sock"
export CAMD_LIVE="$LIVE_FILE"
# Digital pan, tilt and zoom, written by the ONVIF service (vaidk-onvif); vaidk-camd re-reads it on SIGUSR2.
export CAMD_PTZ="$RUN_DIR/ptz.conf"
if [ "$TALKBACK" = 1 ]; then export CAMD_TALK="$RUN_DIR/talk.sock"; fi
export CAMD_ON_START="/bin/sh $VAIDK_DIR/camera/mic.sh"
exec "$VAIDK_DIR/camera/vaidk-camd"
