#!/bin/sh
# Setup page for the Vision AI DevKit RTSP add-on (busybox httpd CGI) and its command-line helpers.
#   ui.sh ap | lan | entry     CGI: setup access point (no login) | your network (admin login) | "/"
#   ui.sh write-httpd-conf     write the web server's login rule for the admin account
#   ui.sh set-admin USER       create or update the admin account (reads the password from stdin)
#   ui.sh adopt-admin USER     make an existing sudo account (e.g. from the original setup) the admin
#   ui.sh forget               forget Wi-Fi, settings, presets and the admin account
#   ui.sh reset                forget everything, then restart into setup mode
#   ui.sh info                 state, address and setup network name (used by the installers)
. /opt/vaidk/common.sh
load_settings

BB=/bin/busybox
SSHD_CONFIG=/etc/ssh/sshd_config
AP_URL=http://192.168.143.1/
MODE=$1
SELF=${SCRIPT_NAME:-/cgi-bin/index.cgi}

h() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"; }
has_ctrl() { [ "$(printf '%s' "$1" | tr -d '\001-\037\177' | wc -c)" != "$(printf '%s' "$1" | wc -c)" ]; }

# ----- admin account (also the SSH login) -----

valid_user() { printf '%s\n' "$1" | grep -qxE '[a-z_][a-z0-9_-]{0,30}' && [ "$1" != root ]; }
valid_password() { [ ${#1} -ge 8 ] && [ ${#1} -le 64 ] && ! has_ctrl "$1"; }

in_allow_users() {
    awk -v u="$1" '/^[[:space:]]*AllowUsers/ { for (i = 2; i <= NF; i++) if ($i == u) f = 1 } END { exit !f }' "$SSHD_CONFIG"
}
allow_ssh() { # allow_ssh USER: USER may sign in over SSH, and SSH is on
    # sshd only admits listed users once an AllowUsers line exists
    if grep -qE '^[[:space:]]*AllowUsers' "$SSHD_CONFIG" && ! in_allow_users "$1"; then
        sed -i "s/^\([[:space:]]*AllowUsers.*\)\$/\1 $1/" "$SSHD_CONFIG"
    fi
    # What the vendor setup's "SSH enabled" box did (that setup may have left SSH off): on now and at
    # every boot.
    case $(systemctl is-enabled sshd.socket 2>/dev/null) in
        enabled) ;;
        masked*) systemctl unmask sshd.socket; systemctl enable sshd.socket ;;
        *) systemctl enable sshd.socket ;;
    esac >/dev/null 2>&1
    systemctl start sshd.socket >/dev/null 2>&1
    systemctl -q is-active sshd.socket || echo "SSH couldn't be turned on: sshd.socket isn't running" >&2
    return 0
}
disallow_ssh() {
    mkdir -p "$RUN_DIR"
    awk -v u="$1" '/^[[:space:]]*AllowUsers/ { line = "AllowUsers"; for (i = 2; i <= NF; i++) if ($i != u) line = line " " $i; if (line != "AllowUsers") print line; next } { print }' \
        "$SSHD_CONFIG" > "$RUN_DIR/sshd_config.new" && cat "$RUN_DIR/sshd_config.new" > "$SSHD_CONFIG"
    rm -f "$RUN_DIR/sshd_config.new"
}

write_httpd_conf() {
    mkdir -p "$RUN_DIR"
    user=$(admin_user)
    if [ -n "$user" ]; then
        printf '/cgi-bin/admin.cgi:%s:*\n' "$user"
    else
        printf '/cgi-bin/admin.cgi:setup-required:%s\n' "$(head -c 16 /dev/urandom | hexdump -v -e '/1 "%02x"')"
    fi > "$RUN_DIR/httpd.conf"
}
reload_web() { write_httpd_conf; systemctl reload vaidk-web.service 2>/dev/null; return 0; }

remove_admin() { # remove_admin USER KIND: delete accounts this add-on created
    if [ "$2" = created ]; then
        with_rw_root userdel -r "$1" 2>/dev/null
        disallow_ssh "$1"
    fi
}

set_admin() { # set_admin USER PASSWORD -> 0 ok, 1 failed, 2 USER is a system account
    old=$(admin_user)
    old_kind=$(cut -d' ' -f2 "$ADMIN_FILE" 2>/dev/null)
    if id "$1" >/dev/null 2>&1; then
        if [ "$1" = "$old" ]; then kind=$old_kind
        elif id -nG "$1" | tr ' ' '\n' | grep -qx sudo; then kind=adopted
        else return 2; fi
    else
        with_rw_root useradd -m -s /bin/sh -G sudo,inet,sdcard "$1" || return 1
        kind=created
    fi
    printf '%s:%s\n' "$1" "$2" | chpasswd || return 1
    allow_ssh "$1"
    if [ -n "$old" ] && [ "$old" != "$1" ]; then remove_admin "$old" "$old_kind"; fi
    mkdir -p "$DATA_DIR" && chmod 700 "$DATA_DIR"
    echo "$1 $kind" > "$ADMIN_FILE"
    reload_web
}

forget() {
    user=$(admin_user)
    if [ -n "$user" ]; then remove_admin "$user" "$(cut -d' ' -f2 "$ADMIN_FILE")"; fi
    rm -rf "$DATA_DIR"
    rm -f "$RUN_DIR/scan" "$RUN_DIR/wifi-try" "$RUN_DIR/wifi-try-ssid"
    # The ONVIF service keeps its presets in memory too; a restart drops them and shows the whole picture.
    systemctl try-restart vaidk-onvif.service 2>/dev/null
    write_httpd_conf
}

# ----- Wi-Fi and status details -----

make_wifi_conf() { # make_wifi_conf OUT SSID PASSWORD (empty password = open network)
    hex=$(printf '%s' "$2" | hexdump -v -e '/1 "%02x"')
    if [ -n "$3" ]; then
        psk=$(printf '%s\n' "$3" | wpa_passphrase "$2" 2>/dev/null | sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p')
        [ -n "$psk" ] || return 1
        auth=$(printf 'key_mgmt=WPA-PSK\n\tpsk=%s' "$psk")
    else
        auth="key_mgmt=NONE"
    fi
    (umask 077 && printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=0\nap_scan=1\ncountry=%s\nnetwork={\n\tssid=%s\n\tscan_ssid=1\n\t%s\n}\n' \
        "$WIFI_COUNTRY" "$hex" "$auth" > "$1")
}

saved_ssid() {
    line=$(sed -n 's/^[[:space:]]*ssid=//p' "$WIFI_CONF" 2>/dev/null | head -n 1)
    case "$line" in
        \"*) line=${line#\"}; printf '%s' "${line%\"}" ;;
        *) printf '%s\n' "$line" | awk 'function v(c) { return index("0123456789abcdef", tolower(c)) - 1 }
            { s = ""; for (i = 1; i < length($0); i += 2) s = s sprintf("%c", v(substr($0, i, 1)) * 16 + v(substr($0, i + 1, 1))); printf "%s", s }' ;;
    esac
}
wifi_ssid() { wpa_cli -p /var/run/wpa_supplicant -i wlan0 status 2>/dev/null | sed -n 's/^ssid=//p'; }
wifi_connected() { [ "$(wpa_cli -p /var/run/wpa_supplicant -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')" = COMPLETED ] && [ -n "$(wlan_ip)" ]; }
wifi_signal() { iw dev wlan0 link 2>/dev/null | sed -n 's/^[[:space:]]*signal: \(-*[0-9]*\) dBm.*/\1/p'; }
camera_temp() {
    for z in /sys/class/thermal/thermal_zone*; do
        if [ "$(cat "$z/type" 2>/dev/null)" = camera-usr ]; then echo $(( $(cat "$z/temp") / 1000 )); return; fi
    done
}
battery() { printf '%s%% (%s)' "$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)" "$(cat /sys/class/power_supply/battery/status 2>/dev/null)"; }
uptime_text() {
    s=$(uptime_s); d=$((s / 86400)); hr=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
    if [ $d -gt 0 ]; then printf '%dd %dh %dm' $d $hr $m; else printf '%dh %dm' $hr $m; fi
}
ap_ssid() {
    s=$(sed -n 's/^ssid=//p' /data/misc/wifi/hostapd_virtual.conf 2>/dev/null)
    case "$s" in MSIoT*) printf '%s' "$s" ;; *) printf 'MSIoT_...' ;; esac
}
networks() { # networks fresh|cached|auto -> "signal<TAB>ssid" lines
    cache=$RUN_DIR/scan
    if [ "$1" = fresh ] || { [ "$1" = auto ] && { [ ! -s "$cache" ] || [ $(( $(date +%s) - $(stat -c %Y "$cache") )) -gt 60 ]; }; }; then
        mkdir -p "$RUN_DIR"
        sh "$VAIDK_DIR/wifi/wifi.sh" scan > "$cache.new" 2>/dev/null
        if [ -s "$cache.new" ]; then mv "$cache.new" "$cache"; else rm -f "$cache.new"; fi
    fi
    cat "$cache" 2>/dev/null
}

# ----- CGI plumbing -----

page_start() { # page_start TITLE [REFRESH_SECONDS]
    printf 'Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
    printf '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="same-origin">'
    if [ -n "$2" ]; then printf '<meta http-equiv="refresh" content="%s">' "$2"; fi
    printf '<title>%s</title><link rel="stylesheet" href="/style.css"></head><body><main>\n' "$(h "$1")"
}
page_end() { printf '</main></body></html>\n'; }
# Status lines are written in full: this busybox httpd turns "Status: 303 ..." into
# "HTTP/1.0  303 ..." (two spaces), which strict HTTP clients reject.
redirect() { printf 'HTTP/1.0 303 See Other\r\nLocation: %s\r\n\r\n' "$1"; exit 0; }
fail() { redirect "$SELF?msg=$1"; }

read_form() {
    len=${CONTENT_LENGTH:-0}
    case "$len" in ''|*[!0-9]*) len=0 ;; esac
    [ "$len" -gt 16384 ] && len=16384
    FORM=$(head -c "$len")
}
field() { $BB httpd -d "$(printf '%s\n' "$FORM" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1)"; }
qparam() { $BB httpd -d "$(printf '%s\n' "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n 1)"; }

token() {
    if [ ! -s "$RUN_DIR/csrf" ]; then
        mkdir -p "$RUN_DIR"
        head -c 16 /dev/urandom | hexdump -v -e '/1 "%02x"' > "$RUN_DIR/csrf"
    fi
    cat "$RUN_DIR/csrf"
}
form_start() { # form_start ACTION [CLASS]
    printf '<form method="post" action="%s"%s><input type="hidden" name="t" value="%s"><input type="hidden" name="action" value="%s">' \
        "$SELF" "${2:+ class=\"$2\"}" "$(token)" "$1"
}
option() { # option VALUE LABEL CURRENT
    if [ "$1" = "$3" ]; then printf '<option value="%s" selected>%s</option>' "$1" "$2"
    else printf '<option value="%s">%s</option>' "$1" "$2"; fi
}
options() { # options CURRENT VALUE LABEL...: a select's options; a current value missing from the list stays
    cur=$1; shift; found=0
    while [ $# -ge 2 ]; do
        option "$1" "$2" "$cur"
        if [ "$1" = "$cur" ]; then found=1; fi
        shift 2
    done
    if [ $found = 0 ] && [ -n "$cur" ]; then option "$(h "$cur")" "$(h "$cur")" "$(h "$cur")"; fi
}
allowed() { # allowed VALUE CURRENT "LIST": VALUE is one of the words in LIST, or unchanged
    [ -n "$1" ] || return 1
    [ "$1" = "$2" ] && return 0
    for choice in $3; do
        if [ "$1" = "$choice" ]; then return 0; fi
    done
    return 1
}
item() { printf '<dt>%s</dt><dd>%s</dd>' "$1" "$(h "$2")"; }
item_code() { printf '<dt>%s</dt><dd><code>%s</code></dd>' "$1" "$(h "$2")"; }
later() { setsid sh -c "$1" </dev/null >/dev/null 2>&1 & }

show_message() {
    case "$(qparam msg)" in
        camera) text="Saved. The streams restart with the new settings in about 15 seconds." ;;
        picture) text="Saved. The picture changes in a moment." ;;
        talk) text="Saved." ;;
        chime) text="The camera's speaker plays a chime now." ;;
        onvif) text="Saved." ;;
        ptz-full) text="Showing the whole picture." ;;
        ptz-goto) text="Moved to the preset." ;;
        ptz-save) text="Saved the view as a preset. Frigate lists new presets after it restarts." ;;
        ptz-delete) text="Deleted the preset." ;;
        device) text="Saved." ;;
        restart) text="Restarting the streams." ;;
        err-token) err="The page expired. Please try again." ;;
        err-ssid) err="Choose or type a Wi-Fi network name." ;;
        err-wifi-pass) err="Wi-Fi passwords have 8 to 63 characters. Leave it empty only for an open network." ;;
        err-user) err="Usernames use lowercase letters, digits, - and _, and start with a letter." ;;
        err-user-taken) err="That username belongs to a system account. Choose another one." ;;
        err-pass) err="The admin password needs at least 8 characters." ;;
        err-pass-match) err="The admin passwords don't match." ;;
        err-account) err="The admin account couldn't be saved." ;;
        err-name) err="Camera names use letters, digits and dashes (up to 32)." ;;
        err-camera) err="That camera setting isn't supported." ;;
        err-tz) err="Type the time zone in POSIX form, such as EST5EDT,M3.2.0,M11.1.0, or choose one from the list." ;;
        err-ptz) err="Pan, tilt and zoom isn't answering. Check that it's on, or restart the camera." ;;
        err-ptz-name) err="Preset names use letters, digits, spaces, dots, dashes and underscores (up to 32), starting with a letter or digit." ;;
        err-ptz-full) err="The camera keeps up to 16 presets. Delete one first." ;;
        err-reset) err="Tick the box to confirm the reset." ;;
        *) return 0 ;;
    esac
    if [ -n "$text" ]; then printf '<p class="note">%s</p>' "$text"; else printf '<p class="error">%s</p>' "$err"; fi
}

# ----- actions -----

restart_streams() { later "systemctl restart vaidk-camera.service"; }

check_wifi() { # check_wifi SSID PASSWORD
    if [ -z "$1" ] || [ ${#1} -gt 32 ] || has_ctrl "$1"; then fail err-ssid; fi
    if [ -n "$2" ] && { [ ${#2} -lt 8 ] || [ ${#2} -gt 63 ] || has_ctrl "$2"; }; then fail err-wifi-pass; fi
}
check_name() { printf '%s\n' "$1" | grep -qxE '[A-Za-z0-9][A-Za-z0-9-]{0,31}' || fail err-name; }
save_account() { # save_account USER PASSWORD CONFIRM
    valid_user "$1" || fail err-user
    valid_password "$2" || fail err-pass
    [ "$2" = "$3" ] || fail err-pass-match
    set_admin "$1" "$2"
    case $? in 0) ;; 2) fail err-user-taken ;; *) fail err-account ;; esac
}
join_wifi() { # join_wifi SSID PASSWORD RESTART_AFTER(yes|no)
    mkdir -p "$RUN_DIR"
    if [ -d "$RUN_DIR/wifi.lock" ]; then redirect "$SELF?view=wifi"; fi
    make_wifi_conf "$RUN_DIR/candidate.conf" "$1" "$2" || fail err-wifi-pass
    printf '%s' "$1" > "$RUN_DIR/wifi-try-ssid"
    echo connecting > "$RUN_DIR/wifi-try"
    setsid sh "$VAIDK_DIR/wifi/wifi.sh" try "$RUN_DIR/candidate.conf" "$3" </dev/null >>"$RUN_DIR/wifi-try.log" 2>&1 &
    redirect "$SELF?view=wifi"
}
apply_profile() {
    case "$1" in
        4k) set_setting MAIN_WIDTH 3840; set_setting MAIN_HEIGHT 2160; set_setting MAIN_BITRATE 8000000
            set_setting SUB_WIDTH 1280; set_setting SUB_HEIGHT 720; set_setting SUB_BITRATE 1000000 ;;
        *) set_setting MAIN_WIDTH 1920; set_setting MAIN_HEIGHT 1080; set_setting MAIN_BITRATE 4000000
            set_setting SUB_WIDTH 640; set_setting SUB_HEIGHT 360; set_setting SUB_BITRATE 500000 ;;
    esac
    set_setting MAIN_FPS 30; set_setting MAIN_CODEC 1
    set_setting SUB_ENABLED 1; set_setting SUB_FPS 5
}

post_setup() {
    ssid=$(field other_ssid); [ -n "$ssid" ] || ssid=$(field ssid)
    wifi_pass=$(field wifi_pass)
    name=$(field name)
    profile=$(field profile)
    user=$(field admin_user); pass=$(field admin_pass)
    check_wifi "$ssid" "$wifi_pass"
    check_name "$name"
    case "$profile" in hd|4k) ;; *) fail err-camera ;; esac
    if [ -z "$(admin_user)" ] || [ -n "$pass" ] || [ "$user" != "$(admin_user)" ]; then
        save_account "$user" "$pass" "$(field admin_pass2)"
    fi
    set_setting NAME "$name"
    apply_profile "$profile"
    if [ "$(field audio)" = 1 ]; then set_setting AUDIO_ENABLED 1; else set_setting AUDIO_ENABLED 0; fi
    join_wifi "$ssid" "$wifi_pass" yes
}

post_wifi() {
    ssid=$(field other_ssid); [ -n "$ssid" ] || ssid=$(field ssid)
    wifi_pass=$(field wifi_pass)
    check_wifi "$ssid" "$wifi_pass"
    if [ "$MODE" = ap ]; then join_wifi "$ssid" "$wifi_pass" yes; else join_wifi "$ssid" "$wifi_pass" no; fi
}

post_camera() {
    res=$(field main_res); fps=$(field main_fps); kbps=$(field main_kbps); codec=$(field codec)
    sub=$(field sub); sres=$(field sub_res); sfps=$(field sub_fps); skbps=$(field sub_kbps)
    audio=$(field audio); gain=$(field gain)
    case "$res" in 3840x2160|1920x1080|1280x720) ;; *) fail err-camera ;; esac
    case "$fps" in 30|25|20|15) ;; *) fail err-camera ;; esac
    case "$kbps" in 2000|4000|6000|8000) ;; *) fail err-camera ;; esac
    case "$codec" in 0|1) ;; *) fail err-camera ;; esac
    case "$sub" in 0|1) ;; *) fail err-camera ;; esac
    case "$sres" in 1280x720|640x360) ;; *) fail err-camera ;; esac
    case "$sfps" in 5|10|15) ;; *) fail err-camera ;; esac
    case "$skbps" in 300|500|1000|2000) ;; *) fail err-camera ;; esac
    case "$audio" in 0|1) ;; *) fail err-camera ;; esac
    case "$gain" in 0|6|12|18|24|30|36|40) ;; *) fail err-camera ;; esac
    set_setting MAIN_WIDTH "${res%x*}"; set_setting MAIN_HEIGHT "${res#*x}"
    set_setting MAIN_FPS "$fps"; set_setting MAIN_BITRATE "$((kbps * 1000))"; set_setting MAIN_CODEC "$codec"
    set_setting SUB_ENABLED "$sub"; set_setting SUB_WIDTH "${sres%x*}"; set_setting SUB_HEIGHT "${sres#*x}"
    set_setting SUB_FPS "$sfps"; set_setting SUB_BITRATE "$((skbps * 1000))"
    set_setting AUDIO_ENABLED "$audio"; set_setting AUDIO_GAIN_DB "$gain"
    restart_streams
    redirect "$SELF?msg=camera"
}

post_device() {
    name=$(field name)
    check_name "$name"
    user=$(field admin_user); pass=$(field admin_pass)
    if [ -n "$pass" ] || [ "$user" != "$(admin_user)" ]; then
        save_account "$user" "$pass" "$(field admin_pass2)"
    fi
    set_setting NAME "$name"
    redirect "$SELF?msg=device"
}

post_picture() { # applied while streaming
    af=$(field antiflicker); ev=$(field exposure); wb=$(field white_balance)
    sat=$(field saturation); sharp=$(field sharpness)
    allowed "$af" "$ANTIFLICKER" "auto 60 50 off" || fail err-camera
    allowed "$ev" "$EXPOSURE_EV" "-2 -1.5 -1 -0.5 0 0.5 1 1.5 2" || fail err-camera
    allowed "$wb" "$WHITE_BALANCE" "auto daylight cloudy shade twilight incandescent fluorescent warm-fluorescent" || fail err-camera
    allowed "$sat" "$SATURATION" "0 1 2 3 4 5 6 7 8 9 10" || fail err-camera
    allowed "$sharp" "$SHARPNESS" "0 1 2 3 4 5 6" || fail err-camera
    set_setting ANTIFLICKER "$af"; set_setting EXPOSURE_EV "$ev"; set_setting WHITE_BALANCE "$wb"
    set_setting SATURATION "$sat"; set_setting SHARPNESS "$sharp"
    sh "$VAIDK_DIR/camera/camd.sh" reload
    redirect "$SELF?msg=picture"
}

post_overlay() {
    overlay=$(field overlay); pos=$(field overlay_position); streams=$(field overlay_streams)
    tz=$(field tz_custom); [ -n "$tz" ] || tz=$(field tz)
    allowed "$overlay" "$OVERLAY" "off time name time-name" || fail err-camera
    allowed "$pos" "$OVERLAY_POSITION" "top-left top-right bottom-left bottom-right" || fail err-camera
    allowed "$streams" "$OVERLAY_STREAMS" "main both" || fail err-camera
    # Settings are read back by the shell, so only characters that need no quoting.
    printf '%s\n' "$tz" | grep -qxE '[A-Za-z][A-Za-z0-9+:,./-]{2,63}' || fail err-tz
    set_setting OVERLAY "$overlay"; set_setting OVERLAY_POSITION "$pos"; set_setting OVERLAY_STREAMS "$streams"
    set_setting TIME_ZONE "$tz"
    later "sh $VAIDK_DIR/camera/camd.sh tz; systemctl restart vaidk-camera.service"
    redirect "$SELF?msg=camera"
}

post_talk() {
    talkback=$(field talkback); volume=$(field volume)
    if [ "$(field mute_mic)" = 1 ]; then mute=1; else mute=0; fi
    allowed "$talkback" "$TALKBACK" "0 1" || fail err-camera
    allowed "$volume" "$SPEAKER_VOLUME" "10 20 30 40 50 60 70 80 90 100" || fail err-camera
    set_setting SPEAKER_VOLUME "$volume"; set_setting TALKBACK_MUTE_MIC "$mute"
    if [ "$talkback" != "$TALKBACK" ]; then # the RTSP server offers the backchannel only after a restart
        set_setting TALKBACK "$talkback"
        restart_streams
        redirect "$SELF?msg=camera"
    fi
    sh "$VAIDK_DIR/camera/camd.sh" reload
    redirect "$SELF?msg=talk"
}

# The ONVIF service (onvif/onvifd.py) keeps the view and presets; this page asks it over its local
# address, which only answers this camera. Prints "zoom=", "pan=", "tilt=" and "preset=TOKEN NAME" lines.
ptz_local() { # ptz_local [QUERY]
    $BB wget -q -T 3 -O - "http://127.0.0.1:$ONVIF_PORT/local/ptz${1:+?$1}" 2>/dev/null
}

post_onvif() {
    onvif=$(field onvif)
    allowed "$onvif" "$ONVIF" "0 1" || fail err-camera
    set_setting ONVIF "$onvif"
    later "systemctl restart vaidk-onvif.service"
    redirect "$SELF?msg=onvif"
}

post_ptz() {
    action=$(field do)
    case "$action" in
        full) ptz_local do=full >/dev/null || fail err-ptz ;;
        goto|delete)
            t=$(field token)
            printf '%s\n' "$t" | grep -qxE '[0-9]{1,3}' || fail err-ptz
            ptz_local "do=$action&token=$t" >/dev/null || fail err-ptz ;;
        save)
            name=$(field name)
            printf '%s\n' "$name" | grep -qxE '[A-Za-z0-9][A-Za-z0-9 ._-]{0,31}' || fail err-ptz-name
            if ! ptz_local "do=save&name=$(printf '%s' "$name" | tr ' ' '+')" >/dev/null; then
                if ptz_local >/dev/null; then fail err-ptz-full; else fail err-ptz; fi
            fi ;;
        *) fail err-ptz ;;
    esac
    redirect "$SELF?msg=ptz-$action"
}

handle_post() {
    read_form
    [ "$(field t)" = "$(token)" ] || fail err-token
    case "$(field action)" in
        setup) [ "$MODE" = ap ] && post_setup ;;
        wifi) post_wifi ;;
        camera) post_camera ;;
        picture) post_picture ;;
        overlay) post_overlay ;;
        talk) post_talk ;;
        chime) sh "$VAIDK_DIR/camera/camd.sh" chime; redirect "$SELF?msg=chime" ;;
        onvif) post_onvif ;;
        ptz) post_ptz ;;
        device) post_device ;;
        restart-streams) restart_streams; redirect "$SELF?msg=restart" ;;
        reboot)
            later "sleep 3; reboot"
            page_start "Restarting"
            printf '<h1>Restarting</h1><p>The camera restarts now and is back in about 2 minutes.</p>'
            if [ "$MODE" = ap ] && [ -n "$(wlan_ip)" ]; then
                printf '<p>Switch back to your usual Wi-Fi and open <a href="http://%s/">http://%s/</a>.</p>' "$(wlan_ip)" "$(wlan_ip)"
            fi
            page_end; exit 0 ;;
        reset)
            [ "$(field confirm)" = yes ] || fail err-reset
            later "sh $VAIDK_DIR/web/ui.sh reset"
            page_start "Camera reset"
            printf '<h1>Camera reset</h1><p>The camera forgets its Wi-Fi network, settings and admin account, then restarts in setup mode (about 2 minutes).</p>'
            printf '<p>To set it up again, join its Wi-Fi network <b>%s</b> (password on the sticker under the camera) and open <a href="%s">%s</a>.</p>' "$(h "$(ap_ssid)")" "$AP_URL" "$AP_URL"
            page_end; exit 0 ;;
    esac
    redirect "$SELF"
}

# ----- pages -----

network_fields() { # network_fields MODE(auto|cached|fresh)
    list=$(networks "$1")
    printf '<label>Network <select name="ssid"><option value="">Choose a network</option>'
    printf '%s\n' "$list" | while IFS='	' read -r signal ssid; do
        [ -n "$ssid" ] || continue
        if [ "$signal" -ge -60 ] 2>/dev/null; then bars="strong"; elif [ "$signal" -ge -72 ] 2>/dev/null; then bars="good"; else bars="weak"; fi
        printf '<option value="%s">%s (%s)</option>' "$(h "$ssid")" "$(h "$ssid")" "$bars"
    done
    printf '</select></label>'
    if [ "$MODE" = lan ]; then printf '<p class="hint"><a href="%s?scan=1#wifi">Scan for networks</a></p>' "$SELF"; fi
    printf '<label>Or type its name <input name="other_ssid" maxlength="32" autocomplete="off"></label>'
    printf '<label>Wi-Fi password <input name="wifi_pass" type="password" maxlength="63" autocomplete="off"></label>'
}

account_fields() {
    current=$(admin_user)
    printf '<label>Username <input name="admin_user" value="%s" maxlength="31" autocapitalize="none" autocomplete="username" required></label>' "$(h "${current:-admin}")"
    printf '<label>%s <input name="admin_pass" type="password" maxlength="64" autocomplete="new-password"></label>' "$([ -n "$current" ] && echo 'New password (blank keeps the current one)' || echo 'Password (8+ characters)')"
    printf '<label>Confirm password <input name="admin_pass2" type="password" maxlength="64" autocomplete="new-password"></label>'
}

setup_page() {
    page_start "Set up your camera"
    printf '<header><h1>Set up your camera</h1><p>Vision AI DevKit RTSP camera</p></header>'
    show_message
    form_start setup
    printf '<section><h2>1. Your Wi-Fi</h2>'
    network_fields auto
    printf '</section><section><h2>2. Admin account</h2><p class="hint">Signs in to this page from your network, and over SSH.</p>'
    account_fields
    printf '</section><section><h2>3. Camera</h2>'
    printf '<label>Camera name <input name="name" value="%s" maxlength="32" required></label>' "$(h "$NAME")"
    printf '<label>Streams <select name="profile">'
    option hd "1080p main + 640x360 sub (recommended)" hd
    option 4k "4K main + 720p sub" ""
    printf '</select></label><p class="hint">You can fine-tune resolution, frame rate and bitrate later.</p>'
    printf '<label class="check"><input type="checkbox" name="audio" value="1"%s> Include microphone audio on the main stream</label>' "$([ "$AUDIO_ENABLED" = 1 ] && echo ' checked')"
    printf '<p class="hint">Recording sound can be regulated where you live; let people know the camera records audio.</p></section>'
    printf '<button>Save and connect</button></form>'
    page_end
}

status_section() {
    ip=""
    if wifi_connected; then ip=$(wlan_ip); fi
    printf '<section><h2>Status</h2><dl>'
    if [ -n "$ip" ]; then
        sig=$(wifi_signal)
        item "Wi-Fi" "$(wifi_ssid)${sig:+ ($sig dBm)}"
        item "Address" "$ip"
    else
        s=$(saved_ssid)
        item "Wi-Fi" "Not connected${s:+ (saved network: $s)}"
    fi
    if [ -e "$RUN_DIR/streaming" ]; then item "Streams" "Streaming"; else item "Streams" "Starting or recovering"; fi
    item_code "Main stream" "rtsp://${ip:-camera-ip}:8900/live"
    if [ "$SUB_ENABLED" = 1 ]; then item_code "Sub stream" "rtsp://${ip:-camera-ip}:8901/live"; fi
    if [ "$AUDIO_ENABLED" = 1 ]; then item "Microphone" "On, +${AUDIO_GAIN_DB} dB gain (main stream)"; else item "Microphone" "Off"; fi
    if [ "$TALKBACK" = 1 ]; then item "Talk-back" "On, speaker volume ${SPEAKER_VOLUME}%"; else item "Talk-back" "Off"; fi
    if [ "$ONVIF" = 1 ]; then item "Pan, tilt and zoom" "On, ONVIF port $ONVIF_PORT"; else item "Pan, tilt and zoom" "Off"; fi
    t=$(camera_temp)
    if [ -n "$t" ]; then printf '<dt>Camera temperature</dt><dd>%s &deg;C</dd>' "$t"; fi
    item "Battery" "$(battery)"
    item "Running for" "$(uptime_text)"
    printf '</dl></section>'
}

streams_section() {
    printf '<section id="streams"><h2>Camera streams</h2>'
    form_start camera
    printf '<fieldset><legend>Main stream (port 8900)</legend><label>Resolution <select name="main_res">'
    cur="${MAIN_WIDTH}x$MAIN_HEIGHT"
    option 3840x2160 "4K (3840x2160)" "$cur"; option 1920x1080 "1080p (1920x1080)" "$cur"; option 1280x720 "720p (1280x720)" "$cur"
    printf '</select></label><label>Frame rate <select name="main_fps">'
    for f in 30 25 20 15; do option $f "$f fps" "$MAIN_FPS"; done
    printf '</select></label><label>Bitrate <select name="main_kbps">'
    for b in 2000 4000 6000 8000; do option $b "$((b / 1000)) Mbps" "$((MAIN_BITRATE / 1000))"; done
    printf '</select></label><label>Codec <select name="codec">'
    option 1 "H.264 (most compatible)" "$MAIN_CODEC"; option 0 "H.265 (smaller files)" "$MAIN_CODEC"
    printf '</select></label></fieldset><fieldset><legend>Sub stream (port 8901)</legend><label>Sub stream <select name="sub">'
    option 1 On "$SUB_ENABLED"; option 0 Off "$SUB_ENABLED"
    printf '</select></label><label>Resolution <select name="sub_res">'
    cur="${SUB_WIDTH}x$SUB_HEIGHT"
    option 1280x720 "720p (1280x720)" "$cur"; option 640x360 "640x360" "$cur"
    printf '</select></label><label>Frame rate <select name="sub_fps">'
    for f in 5 10 15; do option $f "$f fps" "$SUB_FPS"; done
    printf '</select></label><label>Bitrate <select name="sub_kbps">'
    for b in 300 500 1000 2000; do option $b "$b kbps" "$((SUB_BITRATE / 1000))"; done
    printf '</select></label></fieldset><fieldset><legend>Microphone (main stream)</legend><label>Audio <select name="audio">'
    option 1 On "$AUDIO_ENABLED"; option 0 Off "$AUDIO_ENABLED"
    printf '</select></label><label>Gain <select name="gain">'
    for g in 0 6 12 18 24 30 36 40; do option $g "+$g dB" "$AUDIO_GAIN_DB"; done
    printf '</select></label></fieldset><p class="hint">The sub stream is always H.264 (best for Frigate detection). Tested: 1080p at 15 or 30 fps up to 8 Mbps, 4K at 8 Mbps, sub stream 640x360 or 720p at 5 or 10 fps. Audio is AAC, 48 kHz mono; raise the gain if Frigate'"'"'s audio level stays low. Recording sound can be regulated where you live.</p>'
    printf '<button>Save and restart streams</button></form></section>'
}

picture_section() {
    printf '<section id="picture"><h2>Picture</h2>'
    form_start picture
    printf '<label>Light flicker <select name="antiflicker">'
    options "$ANTIFLICKER" auto "Automatic" 60 "60 Hz mains (most of the Americas)" 50 "50 Hz mains (most other places)" off "Off"
    printf '</select></label><label>Exposure <select name="exposure">'
    options "$EXPOSURE_EV" -2 "-2 (darker)" -1.5 "-1.5" -1 "-1" -0.5 "-0.5" 0 "0 (automatic)" 0.5 "+0.5" 1 "+1" 1.5 "+1.5" 2 "+2 (brighter)"
    printf '</select></label><label>White balance <select name="white_balance">'
    options "$WHITE_BALANCE" auto "Automatic" daylight "Daylight" cloudy "Cloudy" shade "Shade" twilight "Twilight" \
        incandescent "Incandescent (warm bulbs)" fluorescent "Fluorescent" warm-fluorescent "Warm fluorescent"
    printf '</select></label><label>Colour <select name="saturation">'
    options "$SATURATION" 0 "0 (black and white)" 1 1 2 2 3 3 4 4 5 "5 (normal)" 6 6 7 7 8 8 9 9 10 "10 (vivid)"
    printf '</select></label><label>Sharpness <select name="sharpness">'
    options "$SHARPNESS" 0 "0 (soft)" 1 1 2 "2 (normal)" 3 3 4 4 5 5 6 "6 (sharpest)"
    printf '</select></label><p class="hint">Changes show on the streams within a second; they don'"'"'t restart. Set the light flicker to your mains frequency if lights band or flicker.</p>'
    printf '<button>Save</button></form></section>'
}

TIME_ZONES='UTC0|UTC
EST5EDT,M3.2.0,M11.1.0|US and Canada Eastern
CST6CDT,M3.2.0,M11.1.0|US and Canada Central
MST7MDT,M3.2.0,M11.1.0|US and Canada Mountain
MST7|Arizona
PST8PDT,M3.2.0,M11.1.0|US and Canada Pacific
AKST9AKDT,M3.2.0,M11.1.0|Alaska
HST10|Hawaii
AST4ADT,M3.2.0,M11.1.0|Atlantic Canada
NST3:30NDT,M3.2.0,M11.1.0|Newfoundland
CST6|Mexico City
BRT3|Brazil (Sao Paulo)
ART3|Argentina
GMT0BST,M3.5.0/1,M10.5.0|UK, Ireland, Portugal
CET-1CEST,M3.5.0,M10.5.0/3|Central Europe
EET-2EEST,M3.5.0/3,M10.5.0/4|Eastern Europe
MSK-3|Moscow
GST-4|Gulf (Dubai)
PKT-5|Pakistan
IST-5:30|India
ICT-7|Thailand, Vietnam
CST-8|China, Singapore, Philippines
JST-9|Japan
KST-9|Korea
AWST-8|Western Australia
ACST-9:30ACDT,M10.1.0,M4.1.0/3|South Australia
AEST-10|Queensland
AEST-10AEDT,M10.1.0,M4.1.0/3|New South Wales, Victoria, Tasmania
NZST-12NZDT,M9.5.0,M4.1.0/3|New Zealand'

tz_options() { # the list, plus the saved value if it isn't one of them
    found=0
    while IFS='|' read -r value label; do
        option "$value" "$label" "$TIME_ZONE"
        if [ "$value" = "$TIME_ZONE" ]; then found=1; fi
    done <<EOF
$TIME_ZONES
EOF
    if [ $found = 0 ]; then option "$(h "$TIME_ZONE")" "$(h "$TIME_ZONE")" "$(h "$TIME_ZONE")"; fi
}

overlay_section() {
    printf '<section id="overlay"><h2>On-screen text</h2>'
    form_start overlay
    printf '<label>Show <select name="overlay">'
    options "$OVERLAY" off "Nothing" time "Date and time" name "Camera name" time-name "Date, time and camera name"
    printf '</select></label><label>Date and time <select name="overlay_position">'
    options "$OVERLAY_POSITION" top-left "Top left" top-right "Top right" bottom-left "Bottom left" bottom-right "Bottom right"
    printf '</select></label><label>Streams <select name="overlay_streams">'
    options "$OVERLAY_STREAMS" main "Main stream only (recommended)" both "Main and sub streams"
    printf '</select></label><label>Time zone <select name="tz">'
    tz_options
    printf '</select></label><label>Or another time zone (POSIX form) <input name="tz_custom" maxlength="64" placeholder="EST5EDT,M3.2.0,M11.1.0" autocapitalize="none" autocomplete="off"></label>'
    printf '<p class="hint">The camera name goes on the other edge of the same side. Frigate detects on the sub stream, where a ticking clock can count as motion. The camera sets its clock from the internet, so the time is right once it has been online.</p>'
    printf '<button>Save and restart streams</button></form></section>'
}

talk_section() {
    printf '<section id="talk"><h2>Talk-back</h2>'
    form_start talk
    printf '<label>Talk-back <select name="talkback">'
    options "$TALKBACK" 1 "On" 0 "Off"
    printf '</select></label><label>Speaker volume <select name="volume">'
    options "$SPEAKER_VOLUME" 100 "100%" 90 "90%" 80 "80%" 70 "70%" 60 "60%" 50 "50%" 40 "40%" 30 "30%" 20 "20%" 10 "10%"
    printf '</select></label>'
    printf '<label class="check"><input type="checkbox" name="mute_mic" value="1"%s> Mute the microphones while the speaker plays (so the other end doesn'"'"'t hear itself)</label>' \
        "$([ "$TALKBACK_MUTE_MIC" = 1 ] && echo ' checked')"
    printf '<p class="hint">The main stream offers a two-way audio channel (ONVIF backchannel, G.711) that Frigate'"'"'s go2rtc uses for its talk button. It has no password: anyone who can reach the camera can use the speaker. Volume and muting change right away; turning talk-back on or off restarts the streams.</p>'
    printf '<button>Save</button></form>'
    form_start chime
    printf '<button class="secondary">Test speaker</button></form></section>'
}

ptz_section() {
    printf '<section id="ptz"><h2>Pan, tilt and zoom</h2>'
    form_start onvif
    printf '<label>Pan, tilt and zoom <select name="onvif">'
    options "$ONVIF" 1 "On" 0 "Off"
    printf '</select></label>'
    printf '<p class="hint">Digital: the camera shows part of its 4K picture, up to 4x, on both streams. Frigate and Home Assistant move it over ONVIF (port %s). It has no password: anyone who can reach the camera can move the view. Off shows the whole picture.</p>' "$ONVIF_PORT"
    printf '<button>Save</button></form>'
    if [ "$ONVIF" = 1 ]; then
        state=$(ptz_local)
        zoom=$(printf '%s\n' "$state" | sed -n 's/^zoom=//p')
        if [ -z "$zoom" ]; then
            printf '<p class="hint">The service isn'"'"'t answering yet.</p></section>'
            return
        fi
        if [ "$zoom" = 1.00 ]; then now="the whole picture"; else now="${zoom}x zoom"; fi
        printf '<h3>View</h3><div class="row"><span class="preset">Now: %s</span>' "$now"
        form_start ptz; printf '<input type="hidden" name="do" value="full"><button class="secondary">Show the whole picture</button></form></div>'
        printf '<h3>Presets</h3>'
        presets=$(printf '%s\n' "$state" | sed -n 's/^preset=//p')
        if [ -z "$presets" ]; then printf '<p class="hint">No presets yet.</p>'; fi
        printf '%s\n' "$presets" | while read -r t name; do
            [ -n "$t" ] || continue
            printf '<div class="row"><span class="preset">%s</span>' "$(h "$name")"
            form_start ptz; printf '<input type="hidden" name="do" value="goto"><input type="hidden" name="token" value="%s"><button class="secondary">Go</button></form>' "$(h "$t")"
            form_start ptz; printf '<input type="hidden" name="do" value="delete"><input type="hidden" name="token" value="%s"><button class="secondary">Delete</button></form></div>' "$(h "$t")"
        done
        form_start ptz
        printf '<input type="hidden" name="do" value="save"><label>Save the current view as <input name="name" maxlength="32" placeholder="Front door" required></label><button>Save preset</button></form>'
        printf '<p class="hint">Move the view from Frigate or Home Assistant, then save it here: Frigate goes to presets but can'"'"'t save them, and lists new ones after it restarts.</p>'
    fi
    printf '</section>'
}

wifi_section() {
    printf '<section id="wifi"><h2>Wi-Fi</h2>'
    if [ "$MODE" = lan ]; then
        printf '<p class="hint">The camera moves to the new network right away, so this page stops responding. If it can'"'"'t join within a minute, it returns to the current network.</p>'
        if [ -n "$(qparam scan)" ]; then mode=fresh; else mode=cached; fi
    else
        mode=auto
    fi
    form_start wifi
    network_fields "$mode"
    printf '<button>Join network</button></form></section>'
}

device_section() {
    printf '<section id="device"><h2>Camera name and admin account</h2>'
    form_start device
    printf '<label>Camera name <input name="name" value="%s" maxlength="32" required></label>' "$(h "$NAME")"
    account_fields
    printf '<p class="hint">The admin account signs in to this page from your network and over SSH (<code>ssh %s@%s</code>).</p>' "$(h "$(admin_user)")" "$(h "${ip:-camera-ip}")"
    printf '<button>Save</button></form></section>'
}

frigate_section() {
    printf '<section><h2>Frigate</h2><p class="hint">For your Frigate configuration. Frigate'"'"'s go2rtc keeps one connection to each stream for recording and detection%s.%s</p><pre>' \
        "$([ "$TALKBACK" = 1 ] && echo '; the live view uses a separate two-way stream, so talking never interrupts a recording. Talking needs WebRTC and a page on HTTPS: Frigate on HTTPS, or Home Assistant on HTTPS with the Advanced Camera Card (see the add-on'"'"'s README)')" \
        "$([ "$ONVIF" = 1 ] && echo ' The onvif part gives Frigate'"'"'s live view pan, tilt and zoom controls and the presets saved above.')"
    {
        url="rtsp://${ip:-camera-ip}"
        restream="rtsp://127.0.0.1:8554/$NAME"
        if [ "$AUDIO_ENABLED" = 1 ]; then audio_role=", audio"; else audio_role=""; fi
        printf 'go2rtc:\n  streams:\n'
        if [ "$TALKBACK" = 1 ]; then
            # Recording and detection don't take the backchannel (Frigate's two-way talk guidance).
            printf '    %s:\n      - %s:8900/live#backchannel=0\n' "$NAME" "$url"
        else
            printf '    %s:\n      - %s:8900/live\n' "$NAME" "$url"
        fi
        if [ "$SUB_ENABLED" = 1 ]; then printf '    %s_sub:\n      - %s:8901/live\n' "$NAME" "$url"; fi
        if [ "$TALKBACK" = 1 ]; then
            printf '    %s_twoway:\n      - %s:8900/live\n' "$NAME" "$url"
            # WebRTC can't carry AAC; an Opus copy brings the camera's sound to the talk view.
            if [ "$AUDIO_ENABLED" = 1 ]; then printf '      - ffmpeg:%s_twoway#audio=opus\n' "$NAME"; fi
        fi
        printf 'cameras:\n  %s:\n    ffmpeg:\n      inputs:\n' "$NAME"
        if [ "$SUB_ENABLED" = 1 ]; then
            printf '        - path: %s\n          input_args: preset-rtsp-restream\n          roles: [record%s]\n' "$restream" "$audio_role"
            printf '        - path: %s_sub\n          input_args: preset-rtsp-restream\n          roles: [detect]\n' "$restream"
        else
            printf '        - path: %s\n          input_args: preset-rtsp-restream\n          roles: [record, detect%s]\n' "$restream" "$audio_role"
        fi
        if [ "$AUDIO_ENABLED" = 1 ]; then
            printf '      output_args:\n        record: preset-record-generic-audio-copy\n'
            printf '    audio:\n      enabled: true\n'
        fi
        if [ "$TALKBACK" = 1 ]; then
            printf '    live:\n      streams:\n        Main: %s_twoway\n' "$NAME"
            if [ "$SUB_ENABLED" = 1 ]; then printf '        Sub: %s_sub\n' "$NAME"; fi
        fi
        if [ "$ONVIF" = 1 ]; then
            # Frigate's ONVIF library can't send a request without a user, even an empty one.
            printf '    onvif:\n      host: %s\n      port: %s\n      user: ""\n      password: ""\n' "${ip:-camera-ip}" "$ONVIF_PORT"
        fi
        # Frigate's dashboard only goes live on motion or objects, so keep motion on without detection.
        printf '    motion:\n      enabled: true\n'
        if [ "$SUB_ENABLED" = 1 ]; then
            printf '    detect:\n      width: %s\n      height: %s\n      fps: %s\n' "$SUB_WIDTH" "$SUB_HEIGHT" "$SUB_FPS"
        else
            printf '    detect:\n      width: %s\n      height: %s\n      fps: 5\n' "$MAIN_WIDTH" "$MAIN_HEIGHT"
        fi
    } | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
    printf '</pre></section>'
}

maintenance_section() {
    printf '<section><h2>Maintenance</h2><div class="row">'
    form_start restart-streams; printf '<button class="secondary">Restart streams</button></form>'
    form_start reboot
    if [ "$MODE" = ap ]; then printf '<button class="secondary">Leave setup mode</button></form>'
    else printf '<button class="secondary">Restart camera</button></form>'; fi
    printf '</div>'
    form_start reset danger
    printf '<label class="check"><input type="checkbox" name="confirm" value="yes"> Forget the Wi-Fi network, settings and admin account</label>'
    printf '<button class="danger">Reset camera</button></form></section>'
}

settings_page() {
    page_start "$NAME"
    printf '<header><h1>%s</h1>' "$(h "$NAME")"
    if [ "$MODE" = ap ]; then
        printf '<p>Setup mode: you are connected to the camera'"'"'s own Wi-Fi. Choose <b>Leave setup mode</b> when you are done.</p>'
    else
        printf '<p>Signed in as %s</p>' "$(h "$REMOTE_USER")"
    fi
    printf '</header>'
    show_message
    status_section
    streams_section
    picture_section
    overlay_section
    talk_section
    ptz_section
    wifi_section
    device_section
    frigate_section
    maintenance_section
    page_end
}

wifi_page() {
    st=$(cat "$RUN_DIR/wifi-try" 2>/dev/null)
    ssid=$(cat "$RUN_DIR/wifi-try-ssid" 2>/dev/null)
    case "$st" in
        connecting)
            page_start "Connecting" 3
            printf '<h1>Joining %s</h1><p>This takes up to a minute.</p>' "$(h "$ssid")" ;;
        ok\ *)
            ip=${st#ok }
            page_start "Connected"
            printf '<h1>Connected</h1><p>The camera joined <b>%s</b> at <b>%s</b>.</p>' "$(h "$ssid")" "$(h "$ip")"
            if [ "$MODE" = ap ]; then
                printf '<p>It restarts in about 20 seconds to finish setup. Then switch this phone or computer back to your usual Wi-Fi and open <a href="http://%s/">http://%s/</a> (sign in with the admin account).</p>' "$ip" "$ip"
            else
                printf '<p>Open <a href="http://%s/">http://%s/</a>.</p>' "$ip" "$ip"
            fi
            printf '<p>Streams: <code>rtsp://%s:8900/live</code> and <code>rtsp://%s:8901/live</code></p>' "$ip" "$ip" ;;
        failed\ wrong-password)
            page_start "Couldn't connect"
            printf '<h1>Couldn'"'"'t join %s</h1><p>The Wi-Fi password was rejected.</p><p><a href="%s">Try again</a></p>' "$(h "$ssid")" "$SELF" ;;
        failed\ no-address)
            page_start "Couldn't connect"
            printf '<h1>Couldn'"'"'t join %s</h1><p>The camera joined it but didn'"'"'t get an address from the router.</p><p><a href="%s">Try again</a></p>' "$(h "$ssid")" "$SELF" ;;
        failed*)
            page_start "Couldn't connect"
            printf '<h1>Couldn'"'"'t find %s</h1><p>Check the network name and that the camera is in range.</p><p><a href="%s">Try again</a></p>' "$(h "$ssid")" "$SELF" ;;
        *)
            redirect "$SELF" ;;
    esac
    page_end
}

entry_page() {
    page_start "Finish setup"
    printf '<h1>Finish setting up this camera</h1><p>It has no admin account yet. Hold its power button for 5 seconds until the lights blink, join its Wi-Fi network <b>%s</b> (password on the sticker under the camera), then open <a href="%s">%s</a>.</p>' "$(h "$(ap_ssid)")" "$AP_URL" "$AP_URL"
    page_end
}

cgi() {
    client=${REMOTE_ADDR#[}; client=${client%]}; client=${client#::ffff:}
    case "$MODE" in
        ap) case "$client" in "$AP_PREFIX"*) ;; *) redirect /cgi-bin/admin.cgi ;; esac ;;
        entry) if [ -n "$(admin_user)" ]; then redirect /cgi-bin/admin.cgi; fi; entry_page; exit 0 ;;
        lan) if [ -z "$REMOTE_USER" ] || [ "$REMOTE_USER" != "$(admin_user)" ]; then
                printf 'HTTP/1.0 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nForbidden\n'; exit 0
             fi ;;
    esac
    if [ "$REQUEST_METHOD" = POST ]; then handle_post; fi
    if [ "$(qparam view)" = wifi ]; then wifi_page
    elif [ "$MODE" = ap ] && [ ! -s "$WIFI_CONF" ]; then setup_page
    else settings_page; fi
}

case "$MODE" in
    ap|lan|entry) cgi ;;
    write-httpd-conf) write_httpd_conf ;;
    set-admin)
        if [ -t 0 ]; then
            printf 'New password for %s: ' "$2" >&2
            stty -echo; IFS= read -r pass; stty echo; printf '\n' >&2
        else
            IFS= read -r pass
        fi
        valid_user "$2" || { echo "invalid username" >&2; exit 1; }
        valid_password "$pass" || { echo "the password needs 8 to 64 characters" >&2; exit 1; }
        set_admin "$2" "$pass" || { echo "could not set the admin account" >&2; exit 1; }
        echo "admin account: $2" ;;
    adopt-admin)
        id -nG "$2" 2>/dev/null | tr ' ' '\n' | grep -qx sudo || { echo "$2 is not an existing sudo account" >&2; exit 1; }
        allow_ssh "$2"
        old=$(admin_user); old_kind=$(cut -d' ' -f2 "$ADMIN_FILE" 2>/dev/null)
        if [ -n "$old" ] && [ "$old" != "$2" ]; then remove_admin "$old" "$old_kind"; fi
        mkdir -p "$DATA_DIR" && chmod 700 "$DATA_DIR"
        echo "$2 adopted" > "$ADMIN_FILE"
        reload_web
        echo "admin account: $2" ;;
    forget) forget ;;
    reset) forget; sync; sleep 2; reboot ;;
    info)
        if [ ! -e "$RUN_DIR/boot-wifi-done" ]; then echo state=starting
        elif [ -s "$WIFI_CONF" ]; then echo state=configured
        else echo state=setup; fi
        echo "ip=$(if wifi_connected; then wlan_ip; fi)"
        echo "setup_ap=$(if pidof hostapd >/dev/null; then echo on; else echo off; fi)"
        echo "setup_ssid=$(sed -n 's/^ssid=//p' /data/misc/wifi/hostapd_virtual.conf 2>/dev/null)"
        echo "streaming=$(if [ -e "$RUN_DIR/streaming" ]; then echo yes; else echo no; fi)"
        echo "audio=$(if [ "$AUDIO_ENABLED" = 1 ]; then echo on; else echo off; fi)"
        echo "admin=$(admin_user)" ;;
    *) sed -n '2,9p' "$0" >&2; exit 2 ;;
esac
