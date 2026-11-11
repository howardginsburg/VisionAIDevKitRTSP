#!/bin/sh
# Vision AI DevKit RTSP add-on: applies the microphone gain. vaidk-camd runs this once the
# camera is streaming. AUDIO_GAIN_DB (0-40) is digital gain on the audio codec's decimators that
# carry the two built-in microphones; 84 is their 0 dB setting.
. /opt/vaidk/common.sh
load_settings
[ "$AUDIO_ENABLED" = 1 ] || exit 0
gain=${AUDIO_GAIN_DB:-24}
case "$gain" in ''|*[!0-9]*) gain=24 ;; esac
if [ "$gain" -gt 40 ]; then gain=40; fi
for control in "DEC7 Volume" "DEC8 Volume"; do
    tinymix set "$control" $((84 + gain)) >/dev/null 2>&1
done
exit 0
