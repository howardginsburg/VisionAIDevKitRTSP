#!/usr/bin/env bash
# Installs the Vision AI DevKit RTSP add-on on a camera connected over USB (macOS and Linux).
#   bash install.sh                  install; the camera then opens its setup Wi-Fi network
#   bash install.sh --keep-settings  reinstall, keeping the Wi-Fi network, admin account and settings
#   bash install.sh --uninstall      remove the add-on and go back to the original software
# With several ADB devices connected, choose the camera with ANDROID_SERIAL=<serial> bash install.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
action=install
case "${1:-}" in
    "") ;;
    --keep-settings) action="install --keep-settings" ;;
    --uninstall) action=uninstall ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
esac

command -v adb >/dev/null || {
    echo "adb was not found. Install Android SDK Platform-Tools: https://developer.android.com/tools/releases/platform-tools" >&2
    exit 1
}
adb start-server >/dev/null 2>&1 || true
if [ -z "${ANDROID_SERIAL:-}" ]; then
    count=$(adb devices | awk 'NR > 1 && $2 == "device"' | wc -l | tr -d ' ')
    if [ "$count" -eq 0 ]; then
        echo "No camera found. Connect it with a USB-C cable, make sure it is on, then check that 'adb devices' lists it." >&2
        exit 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "More than one ADB device is connected. Choose the camera with ANDROID_SERIAL=<serial> (see: adb devices)." >&2
        exit 1
    fi
fi

check=$(adb shell 'cat /etc/version; test -f /vendor/etc/camera/InitCamx && echo vision-ai-devkit' | tr -d '\r')
grep -q vision-ai-devkit <<<"$check" || { echo "The connected device does not look like a Vision AI DevKit." >&2; exit 1; }
echo "Camera firmware: $(head -n 1 <<<"$check")"

# Copy the add-on with Unix line endings (in case the files were checked out with CRLF).
tmp_parent=${TMPDIR:-/tmp}
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) # Git Bash on Windows: keep camera paths as-is, give adb.exe a Windows path
        export MSYS_NO_PATHCONV=1
        tmp_parent=$(cygpath -m "${TEMP:-/tmp}") ;;
esac
staging=$(mktemp -d "${tmp_parent%/}/vaidk.XXXXXX")
trap 'rm -rf "$staging"' EXIT
cp -R "$here/device/." "$staging/"
# Unix line endings for the text files (camera/vaidk-camd is binary and copied as is).
find "$staging" -type f -exec grep -Iq . {} \; -exec env LC_ALL=C sed -i.crlf $'s/\r$//' {} \;
find "$staging" -name '*.crlf' -delete
adb shell rm -rf /tmp/vaidk-install
echo "Copying the add-on to the camera..."
if ! out=$(adb push "$staging" /tmp/vaidk-install 2>&1); then echo "$out" >&2; exit 1; fi

result=$(adb shell "sh /tmp/vaidk-install/install-device.sh $action 2>&1; rm -rf /tmp/vaidk-install" | tr -d '\r')
grep -v '^VAIDK-OK$' <<<"$result" | sed 's/^/  /'
grep -qx 'VAIDK-OK' <<<"$result" || { echo "The camera reported an error (see above). Nothing was restarted." >&2; exit 1; }

echo "Restarting the camera (about 2 minutes)..."
adb reboot
sleep 10
adb wait-for-device

if [ "$action" = uninstall ]; then
    echo "Done. The camera runs its original software again and opens its original setup network."
    exit 0
fi

info() { adb shell sh /opt/vaidk/web/ui.sh info 2>/dev/null | tr -d '\r'; }
value() { sed -n "s/^$1=//p" <<<"$2"; }
wait_for() { # wait_for SECONDS TEST_FUNCTION -> prints the last info
    local deadline=$((SECONDS + $1)) state
    while :; do
        state=$(info)
        if "$2" "$state" || [ "$SECONDS" -ge "$deadline" ]; then printf '%s' "$state"; return; fi
        sleep 3
    done
}
started() { local s; s=$(value state "$1"); [ -n "$s" ] && [ "$s" != starting ]; }
ap_ready() { [ "$(value setup_ap "$1")" = on ] && [[ "$(value setup_ssid "$1")" == MSIoT* ]]; }
streaming() { [ -n "$(value ip "$1")" ] && [ "$(value streaming "$1")" = yes ]; }

state=$(wait_for 240 started)
if ! started "$state"; then
    echo "The camera is taking longer than expected to start. Watch its lights, then run: adb shell sh /opt/vaidk/web/ui.sh info" >&2
    exit 0
fi

if [ "$(value state "$state")" = setup ]; then
    state=$(wait_for 60 ap_ready)
    ssid=$(value setup_ssid "$state"); [[ "$ssid" == MSIoT* ]] || ssid="MSIoT_..."
    echo
    echo "Done. Finish setup from a phone or computer:"
    echo "  1. Join the Wi-Fi network '$ssid'. Its password is on the sticker under the camera"
    echo "     (or run: adb shell cat /persist/data/wifi.bin)."
    echo "  2. A sign-in page should open. If it does not, browse to http://192.168.143.1/"
    echo "  3. Choose your Wi-Fi network, create the admin account (it's also your SSH login), and select Save and connect."
    exit 0
fi

state=$(wait_for 120 streaming)
ip=$(value ip "$state"); ip=${ip:-<camera-ip>}
echo
echo "Done. The camera kept its settings."
echo "  Setup page:  http://$ip/"
echo "  Main stream: rtsp://$ip:8900/live$([ "$(value audio "$state")" = on ] && echo ' (with microphone audio; turn it off on the setup page)')"
echo "  Sub stream:  rtsp://$ip:8901/live"
if [ -z "$(value admin "$state")" ]; then
    echo "  No admin account is set yet: hold the power button for 5 seconds and finish setup on the camera's Wi-Fi,"
    echo "  or run: adb shell sh /opt/vaidk/web/ui.sh set-admin admin   (then type the password and press Enter)"
fi
