#!/bin/sh
# Setup page for the Vision AI DevKit RTSP add-on (busybox httpd CGI) and its command-line helpers.
#   ui.sh ap | lan | entry     CGI: setup access point (no login) | your network (admin login) | "/"
#   ui.sh write-httpd-conf     write the web server's login rule for the admin account
#   ui.sh set-admin USER       create or update the admin account (reads the password from stdin)
#   ui.sh adopt-admin USER     make an existing sudo account (e.g. from the original setup) the admin
#   ui.sh stream-key           unlock the streams: check the admin password (stdin) and write their key
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
# (BusyBox tr reads an octal range such as '\001-\037' as three characters, a dash among them: use a class.)
has_ctrl() { [ "$(printf '%s' "$1" | tr -d '[:cntrl:]' | wc -c)" != "$(printf '%s' "$1" | wc -c)" ]; }
# matches VALUE ERE: all of VALUE matches (grep -x alone passes a value with a newline if one line does)
matches() { ! has_ctrl "$1" && printf '%s\n' "$1" | grep -qxE "$2"; }

# ----- admin account (also the SSH login) -----

valid_user() { matches "$1" '[a-z_][a-z0-9_-]{0,30}' && [ "$1" != root ]; }
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
    account_lock
    printf '%s:%s\n' "$1" "$2" | chpasswd; rc=$?
    # The streams' sign-in follows the password; without a key they stay locked.
    if [ $rc = 0 ]; then stream_key "$1" "$2" || echo "couldn't write the streams' key: they stay locked" >&2; fi
    account_unlock
    [ $rc = 0 ] || return 1
    allow_ssh "$1"
    if [ -n "$old" ] && [ "$old" != "$1" ]; then remove_admin "$old" "$old_kind"; fi
    mkdir -p "$DATA_DIR" && chmod 700 "$DATA_DIR"
    echo "$1 $kind" > "$ADMIN_FILE"
    reload_web
}

# ----- stream sign-in: the RTSP server checks the admin account by Digest (see rtsp/README.md) -----

# One password change or key at a time, so a key never pairs one password with another's hash.
account_lock() { mkdir -p "$RUN_DIR"; exec 9>"$RUN_DIR/account.lock"; flock 9; }
account_unlock() { exec 9>&-; }
shadow_hash() { awk -F: -v u="$1" '$1 == u { print $2 }' /etc/shadow; } # shadow_hash USER
stream_key() { # stream_key USER PASSWORD -> 0 written, 1 failed, 2 not USER's password
    # The key is "USER HA1 FINGERPRINT": HA1 = MD5(USER:realm:PASSWORD), the hash Digest needs, and the
    # SHA-256 of USER's password hash, so the RTSP server locks the streams if the password changes some
    # other way. printf is a shell builtin, so these steps never put the password on a command line.
    hashed=$(shadow_hash "$1")
    case "$hashed" in '$1$'*) method=md5 ;; '$5$'*) method=sha256 ;; '$6$'*) method=sha512 ;; *) return 1 ;; esac
    salt=${hashed#\$?\$}; salt=${salt%\$*}
    [ "$(printf '%s\n' "$2" | cryptpw -m "$method" -S "$salt")" = "$hashed" ] || return 2
    ha1=$(printf '%s:%s:%s' "$1" "$STREAM_REALM" "$2" | md5sum | cut -d' ' -f1)
    print=$(printf '%s' "$hashed" | sha256sum | cut -d' ' -f1)
    mkdir -p "$DATA_DIR" && chmod 700 "$DATA_DIR" || return 1
    (umask 077 && printf '%s %s %s\n' "$1" "$ha1" "$print" > "$STREAM_KEY_FILE.tmp") \
        && mv "$STREAM_KEY_FILE.tmp" "$STREAM_KEY_FILE"
}
stream_auth() { sed -n 's/^auth=//p' "$RUN_DIR/rtsp.status" 2>/dev/null; } # on, off, locked; empty: no server
stream_auth_reason() { sed -n 's/^auth_reason=//p' "$RUN_DIR/rtsp.status" 2>/dev/null; }
read_password() { # read_password PROMPT: from the terminal without echo, or a line of stdin
    if [ -t 0 ]; then
        printf '%s: ' "$1" >&2
        stty -echo; IFS= read -r pass; stty echo; printf '\n' >&2
    else
        IFS= read -r pass
    fi
}

forget() {
    user=$(admin_user)
    if [ -n "$user" ]; then remove_admin "$user" "$(cut -d' ' -f2 "$ADMIN_FILE")"; fi
    rm -rf "$DATA_DIR"
    rm -f "$RUN_DIR/scan" "$RUN_DIR/wifi-try" "$RUN_DIR/wifi-try-ssid"
    # The ONVIF service keeps its presets in memory too; a restart drops them and shows the whole picture.
    systemctl try-restart vaidk-onvif.service 2>/dev/null
    # With the settings gone, detection is off: the detector puts the vendor's files back and stops; so does
    # the MQTT service.
    systemctl try-restart vaidk-detect.service vaidk-mqtt.service 2>/dev/null
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

page_start() { # page_start TITLE [REFRESH_SECONDS]: up to <body>; the caller opens <main>
    printf 'Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
    printf '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="same-origin">'
    if [ -n "$2" ]; then printf '<meta http-equiv="refresh" content="%s">' "$2"; fi
    printf '<title>%s</title><link rel="stylesheet" href="/style.css"></head><body>\n' "$(h "$1")"
}
page_end() { printf '</main></body></html>\n'; }
notice_start() { page_start "$@"; printf '<main class="narrow"><section class="card">'; } # a page with one short message
notice_end() { printf '</section>'; page_end; }
# Status lines are written in full: this busybox httpd turns "Status: 303 ..." into
# "HTTP/1.0  303 ..." (two spaces), which strict HTTP clients reject.
redirect() { printf 'HTTP/1.0 303 See Other\r\nLocation: %s\r\n\r\n' "$1"; exit 0; }
back() { # back [MSG]: to the tab and card the form was posted from (BACK_P, BACK_S), showing MSG there
    _url="$SELF?"
    if [ -n "$BACK_P" ]; then _url="${_url}p=$BACK_P&"; fi
    if [ -n "$BACK_S" ]; then _url="${_url}s=$BACK_S&"; fi
    _url="${_url}msg=$1"
    if [ -n "$BACK_S" ]; then _url="$_url#$BACK_S"; fi
    redirect "$_url"
}
fail() { back "$1"; }

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
form_start() { # form_start ACTION [CLASS] [ID]: posting it returns to this tab and card (PAGE, SECTION)
    printf '<form method="post" action="%s"%s%s><input type="hidden" name="t" value="%s"><input type="hidden" name="action" value="%s">' \
        "$SELF" "${2:+ class=\"$2\"}" "${3:+ id=\"$3\"}" "${TOKEN:-$(token)}" "$1"
    if [ -n "$PAGE" ]; then
        printf '<input type="hidden" name="p" value="%s"><input type="hidden" name="s" value="%s">' "$PAGE" "$SECTION"
    fi
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
later() { setsid sh -c "$1" </dev/null >/dev/null 2>&1 & }
hint() { printf '<p class="hint">%s</p>' "$1"; }                                         # hint HTML
more() { printf '<details class="more"><summary>%s</summary><p>%s</p></details>' "$1" "$2"; } # more SUMMARY HTML
onoff() { if [ "$1" = 1 ]; then echo "on On"; else echo "off Off"; fi; } # a badge (class, text) for a 0/1 setting
save_row() { # save_row LABEL [NOTE]: the form's button, and a note beside it
    printf '<div class="actions"><button>%s</button>' "$1"
    if [ -n "$2" ]; then printf '<span class="hint">%s</span>' "$2"; fi
    printf '</div>'
}
# section_start ID TITLE [BADGE_CLASS BADGE_TEXT...]: a card. Its forms return to it when posted, and it
# shows their message.
section_start() {
    SECTION=$1
    printf '<section class="card" id="%s"><div class="card-head"><h2>%s</h2>' "$1" "$2"
    if [ $# -ge 4 ]; then _bc=$3; shift 3; printf '<span class="badge %s">%s</span>' "$_bc" "$*"; fi
    printf '</div>'
    if [ -n "$MSG_S" ] && [ "$MSG_S" = "$SECTION" ]; then show_message; fi
}
section_end() { printf '</section>'; }

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
        device-pass) text="Saved. The streams' password changed too: update it in Frigate and other players." ;;
        stream-key) text="The streams are unlocked: players sign in with the admin account." ;;
        restart) text="Restarting the streams." ;;
        detect) text="Saved. Detection uses the new settings within a few seconds." ;;
        detect-restart) text="Saved. The streams restart in about 15 seconds; object detection starts a few seconds later." ;;
        detect-sub) text="Saved. Object detection works from the sub stream at 640x360, so it is set to that now: update the detect size in Frigate (see the Frigate section). The streams restart in about 15 seconds." ;;
        mqtt) text="Saved. The MQTT service connects with the new settings in a few seconds." ;;
        mqtt-saved) text="Saved." ;;
        hdmi) text="Saved." ;;
        saved) text="Saved." ;;
        err-token) err="The page expired. Please try again." ;;
        err-ssid) err="Choose or type a Wi-Fi network name." ;;
        err-wifi-pass) err="Wi-Fi passwords have 8 to 63 characters. Leave it empty only for an open network." ;;
        err-user) err="Usernames use lowercase letters, digits, - and _, and start with a letter." ;;
        err-user-taken) err="That username belongs to a system account. Choose another one." ;;
        err-pass) err="The admin password needs at least 8 characters." ;;
        err-pass-match) err="The admin passwords don't match." ;;
        err-account) err="The admin account couldn't be saved." ;;
        err-stream-pass) err="That isn't the admin password." ;;
        err-stream-key) err="The streams couldn't be unlocked. Please try again." ;;
        err-name) err="Camera names use letters, digits and dashes (up to 32)." ;;
        err-camera) err="That camera setting isn't supported." ;;
        err-tz) err="Type the time zone in POSIX form, such as EST5EDT,M3.2.0,M11.1.0, or choose one from the list." ;;
        err-ptz) err="Pan, tilt and zoom isn't answering. Check that it's on, or restart the camera." ;;
        err-ptz-name) err="Preset names use letters, digits, spaces, dots, dashes and underscores (up to 32), starting with a letter or digit." ;;
        err-ptz-full) err="The camera keeps up to 16 presets. Delete one first." ;;
        err-reset) err="Tick the box to confirm the reset." ;;
        err-detect-objects) err="Choose at least one object to detect." ;;
        err-mqtt-host) err="Type the broker's name or address: letters, digits, dots and dashes." ;;
        err-mqtt-port) err="The broker's port is a number from 1 to 65535." ;;
        err-mqtt-user) err="MQTT user names use letters, digits and . _ @ + - (up to 64)." ;;
        err-mqtt-pass) err="The MQTT password can have up to 128 characters, without control characters." ;;
        err-mqtt-topic) err="Topics use letters, digits, dots, dashes and underscores, with / between levels (up to 64 characters, no + or #)." ;;
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
check_name() { matches "$1" '[A-Za-z0-9][A-Za-z0-9-]{0,31}' || fail err-name; }
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
    case "$res" in 3840x2160|1920x1080|1280x720) ;; *) fail err-camera ;; esac
    case "$fps" in 30|25|20|15) ;; *) fail err-camera ;; esac
    case "$kbps" in 2000|4000|6000|8000) ;; *) fail err-camera ;; esac
    case "$codec" in 0|1) ;; *) fail err-camera ;; esac
    case "$sub" in 0|1) ;; *) fail err-camera ;; esac
    case "$sres" in 1280x720|640x360) ;; *) fail err-camera ;; esac
    case "$sfps" in 5|10|15) ;; *) fail err-camera ;; esac
    case "$skbps" in 300|500|1000|2000) ;; *) fail err-camera ;; esac
    # Object detection works from the sub stream at 640x360; the page shows those as fixed while it's on.
    if [ "$DETECT" = 1 ]; then sub=1; sres=640x360; fi
    set_setting MAIN_WIDTH "${res%x*}"; set_setting MAIN_HEIGHT "${res#*x}"
    set_setting MAIN_FPS "$fps"; set_setting MAIN_BITRATE "$((kbps * 1000))"; set_setting MAIN_CODEC "$codec"
    set_setting SUB_ENABLED "$sub"; set_setting SUB_WIDTH "${sres%x*}"; set_setting SUB_HEIGHT "${sres#*x}"
    set_setting SUB_FPS "$sfps"; set_setting SUB_BITRATE "$((skbps * 1000))"
    restart_streams
    # A detector that stopped (for example, waiting for the sub stream) tries again with the streams.
    if [ "$DETECT" = 1 ] && ! systemctl -q is-active vaidk-detect.service; then
        later "systemctl reset-failed vaidk-detect.service; systemctl restart vaidk-detect.service"
    fi
    back camera
}

# The microphone: on or off, and its gain, which mic.sh sets as the streams start.
post_audio() {
    audio=$(field audio); gain=$(field gain)
    allowed "$audio" "$AUDIO_ENABLED" "0 1" || fail err-camera
    allowed "$gain" "$AUDIO_GAIN_DB" "0 6 12 18 24 30 36 40" || fail err-camera
    set_setting AUDIO_ENABLED "$audio"; set_setting AUDIO_GAIN_DB "$gain"
    if [ "$audio" != "$AUDIO_ENABLED" ] || [ "$gain" != "$AUDIO_GAIN_DB" ]; then
        restart_streams
        back camera
    fi
    back saved
}

post_device() {
    name=$(field name)
    check_name "$name"
    user=$(field admin_user); pass=$(field admin_pass)
    if [ -n "$pass" ] || [ "$user" != "$(admin_user)" ]; then
        save_account "$user" "$pass" "$(field admin_pass2)"
    fi
    set_setting NAME "$name"
    # The MQTT topic and Home Assistant's device are named after the camera.
    if [ "$name" != "$NAME" ]; then later "systemctl try-restart vaidk-mqtt.service"; fi
    if [ -n "$pass" ] && [ "$STREAM_AUTH" != 0 ]; then back device-pass; fi
    back device
}

post_stream_key() {
    user=$(admin_user); pass=$(field stream_pass)
    [ -n "$user" ] && [ -n "$pass" ] || fail err-stream-pass
    account_lock; stream_key "$user" "$pass"; rc=$?; account_unlock
    case $rc in 0) ;; 2) fail err-stream-pass ;; *) fail err-stream-key ;; esac
    # The RTSP server looks at the key every 2 seconds; show the page once it has.
    i=0; while [ $i -lt 10 ] && [ "$(stream_auth)" = locked ]; do sleep 0.5; i=$((i + 1)); done
    back stream-key
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
    back picture
}

post_overlay() {
    overlay=$(field overlay); pos=$(field overlay_position); streams=$(field overlay_streams)
    tz=$(field tz_custom); [ -n "$tz" ] || tz=$(field tz)
    allowed "$overlay" "$OVERLAY" "off time name time-name" || fail err-camera
    allowed "$pos" "$OVERLAY_POSITION" "top-left top-right bottom-left bottom-right" || fail err-camera
    allowed "$streams" "$OVERLAY_STREAMS" "main both" || fail err-camera
    # Settings are read back by the shell, so only characters that need no quoting.
    matches "$tz" '[A-Za-z][A-Za-z0-9+:,./-]{2,63}' || fail err-tz
    set_setting OVERLAY "$overlay"; set_setting OVERLAY_POSITION "$pos"; set_setting OVERLAY_STREAMS "$streams"
    set_setting TIME_ZONE "$tz"
    later "sh $VAIDK_DIR/camera/camd.sh tz; systemctl restart vaidk-camera.service"
    back camera
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
        back camera
    fi
    sh "$VAIDK_DIR/camera/camd.sh" reload
    back talk
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
    back onvif
}

post_ptz() {
    action=$(field do)
    case "$action" in
        full) ptz_local do=full >/dev/null || fail err-ptz ;;
        goto|delete)
            t=$(field token)
            matches "$t" '[0-9]{1,3}' || fail err-ptz
            ptz_local "do=$action&token=$t" >/dev/null || fail err-ptz ;;
        save)
            name=$(field name)
            matches "$name" '[A-Za-z0-9][A-Za-z0-9 ._-]{0,31}' || fail err-ptz-name
            if ! ptz_local "do=save&name=$(printf '%s' "$name" | tr ' ' '+')" >/dev/null; then
                if ptz_local >/dev/null; then fail err-ptz-full; else fail err-ptz; fi
            fi ;;
        *) fail err-ptz ;;
    esac
    back "ptz-$action"
}

# Object detection (detect/detect.sh runs vaidk-detect). Turning it on or off restarts the streams;
# objects and confidence restart only the detector; the rate and the boxes apply while streaming.
post_detect() {
    detect=$(field detect); conf=$(field confidence); fps=$(field detect_fps); boxes=$(field boxes)
    allowed "$detect" "$DETECT" "0 1" || fail err-camera
    allowed "$conf" "$DETECT_CONFIDENCE" "40 50 60 70 80 90" || fail err-camera
    allowed "$fps" "$DETECT_FPS" "1 2 5 10" || fail err-camera
    allowed "$boxes" "$DETECT_BOXES" "0 1" || fail err-camera
    # Ticked objects arrive as obj=teddy_bear (an underscore for each space, as in the setting).
    objects=""
    for o in $(printf '%s\n' "$FORM" | tr '&' '\n' | sed -n 's/^obj=//p'); do
        objects_list | tr ' ' '_' | grep -qxF "$o" || fail err-camera
        case ",$objects," in *",$o,"*) ;; *) objects="$objects${objects:+,}$o" ;; esac
    done
    [ -n "$objects" ] || fail err-detect-objects
    msg=detect
    if [ "$detect" != "$DETECT" ]; then msg=detect-restart; fi
    # It works from copies of the sub stream's frames, which are readable only at 640x360.
    if [ "$detect" = 1 ] && { [ "$SUB_ENABLED" != 1 ] || [ "${SUB_WIDTH}x$SUB_HEIGHT" != 640x360 ]; }; then
        set_setting SUB_ENABLED 1; set_setting SUB_WIDTH 640; set_setting SUB_HEIGHT 360
        msg=detect-sub
    fi
    set_setting DETECT "$detect"; set_setting DETECT_OBJECTS "$objects"; set_setting DETECT_CONFIDENCE "$conf"
    set_setting DETECT_FPS "$fps"; set_setting DETECT_BOXES "$boxes"
    # reset-failed: after repeated errors systemd won't start the detector again until told to. The MQTT
    # service follows detection, and publishes the chosen objects.
    if [ $msg != detect ]; then
        later "systemctl reset-failed vaidk-detect.service; systemctl restart vaidk-detect.service vaidk-camera.service vaidk-mqtt.service"
        back "$msg"
    fi
    # The detector restarts for new objects or confidence, and when it isn't running (saving tries again).
    if [ "$detect" = 1 ] && { [ "$objects" != "$DETECT_OBJECTS" ] || [ "$conf" != "$DETECT_CONFIDENCE" ] ||
        ! systemctl -q is-active vaidk-detect.service; }; then
        later "systemctl reset-failed vaidk-detect.service; systemctl restart vaidk-detect.service"
    fi
    if [ "$objects" != "$DETECT_OBJECTS" ]; then later "systemctl try-restart vaidk-mqtt.service"; fi
    sh "$VAIDK_DIR/camera/camd.sh" reload
    back detect
}

# MQTT (mqtt/mqttd.py): saving restarts the service, which connects again. The password is kept apart
# from the settings, in a file only root can read.
post_mqtt() {
    mqtt=$(field mqtt); host=$(field mqtt_host); port=$(field mqtt_port); user=$(field mqtt_user)
    pass=$(field mqtt_pass); topic=$(field mqtt_topic)
    if [ "$(field mqtt_discovery)" = 1 ]; then discovery=1; else discovery=0; fi
    allowed "$mqtt" "$MQTT" "0 1" || fail err-camera
    if [ -n "$host" ] || [ "$mqtt" = 1 ]; then
        matches "$host" '[A-Za-z0-9][A-Za-z0-9.-]{0,252}' || fail err-mqtt-host
    fi
    case "$port" in ''|*[!0-9]*|0*|??????*) fail err-mqtt-port ;; esac
    [ "$port" -le 65535 ] || fail err-mqtt-port
    if [ -n "$user" ]; then matches "$user" '[A-Za-z0-9._@+-]{1,64}' || fail err-mqtt-user; fi
    if [ -n "$pass" ] && { [ ${#pass} -gt 128 ] || has_ctrl "$pass"; }; then fail err-mqtt-pass; fi
    if [ -n "$topic" ]; then
        matches "$topic" '[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*' && [ ${#topic} -le 64 ] || fail err-mqtt-topic
    fi
    set_setting MQTT "$mqtt"; set_setting MQTT_HOST "$host"; set_setting MQTT_PORT "$port"
    set_setting MQTT_USER "$user"; set_setting MQTT_TOPIC "$topic"; set_setting MQTT_DISCOVERY "$discovery"
    # Blank keeps the saved password; without a user name there is none.
    if [ -z "$user" ]; then rm -f "$DATA_DIR/mqtt-password"
    elif [ -n "$pass" ]; then (umask 077 && printf '%s' "$pass" > "$DATA_DIR/mqtt-password"); fi
    later "systemctl restart vaidk-mqtt.service"
    # It runs only while detection is on; otherwise the status line says what it waits for.
    if [ "$mqtt" = 1 ] && [ "$DETECT" = 1 ]; then back mqtt; fi
    back mqtt-saved
}

# HDMI output: live view is a stream of the camera's own, so turning it on or off restarts the streams;
# camera/camd.sh then starts or stops the vendor's display server (weston).
post_hdmi() {
    hdmi=$(field hdmi)
    allowed "$hdmi" "$HDMI" "0 1" || fail err-camera
    set_setting HDMI "$hdmi"
    if [ "$hdmi" != "$HDMI" ]; then
        restart_streams
        back camera
    fi
    back hdmi
}

handle_post() {
    read_form
    # Where the form came from, to go back to; both end up in the Location header.
    BACK_P=$(field p); BACK_S=$(field s)
    case "$BACK_P" in overview|video|audio|ptz|detect|frigate|system) ;; *) BACK_P="" ;; esac
    matches "$BACK_S" '[a-z][a-z-]{0,15}' || BACK_S=""
    [ "$(field t)" = "$(token)" ] || fail err-token
    case "$(field action)" in
        setup) [ "$MODE" = ap ] && post_setup ;;
        wifi) post_wifi ;;
        camera) post_camera ;;
        audio) post_audio ;;
        picture) post_picture ;;
        overlay) post_overlay ;;
        talk) post_talk ;;
        chime) sh "$VAIDK_DIR/camera/camd.sh" chime; back chime ;;
        onvif) post_onvif ;;
        ptz) post_ptz ;;
        detect) post_detect ;;
        mqtt) post_mqtt ;;
        hdmi) post_hdmi ;;
        device) post_device ;;
        stream-key) post_stream_key ;;
        restart-streams) restart_streams; back restart ;;
        reboot)
            later "sleep 3; reboot"
            notice_start "Restarting"
            printf '<h1>Restarting</h1><p>The camera restarts now and is back in about 2 minutes.</p>'
            if [ "$MODE" = ap ] && [ -n "$(wlan_ip)" ]; then
                printf '<p>Switch back to your usual Wi-Fi and open <a href="http://%s/">http://%s/</a>.</p>' "$(wlan_ip)" "$(wlan_ip)"
            fi
            notice_end; exit 0 ;;
        reset)
            [ "$(field confirm)" = yes ] || fail err-reset
            later "sh $VAIDK_DIR/web/ui.sh reset"
            notice_start "Camera reset"
            printf '<h1>Camera reset</h1><p>The camera forgets its Wi-Fi network, settings and admin account, then restarts in setup mode (about 2 minutes).</p>'
            printf '<p>To set it up again, join its Wi-Fi network <b>%s</b> (password on the sticker under the camera) and open <a href="%s">%s</a>.</p>' "$(h "$(ap_ssid)")" "$AP_URL" "$AP_URL"
            notice_end; exit 0 ;;
    esac
    back
}

# ----- pages -----

signal_word() { if [ "$1" -ge -60 ] 2>/dev/null; then echo strong; elif [ "$1" -ge -72 ] 2>/dev/null; then echo good; else echo weak; fi; }

network_fields() { # network_fields MODE(auto|cached|fresh)
    list=$(networks "$1")
    printf '<div class="fields"><label>Network <select name="ssid"><option value="">Choose a network</option>'
    printf '%s\n' "$list" | while IFS='	' read -r signal ssid; do
        [ -n "$ssid" ] || continue
        printf '<option value="%s">%s (%s)</option>' "$(h "$ssid")" "$(h "$ssid")" "$(signal_word "$signal")"
    done
    printf '</select></label>'
    printf '<label>Or type its name <input name="other_ssid" maxlength="32" autocomplete="off"></label>'
    printf '<label>Wi-Fi password <input name="wifi_pass" type="password" maxlength="63" autocomplete="off"></label></div>'
    if [ "$MODE" = lan ]; then printf '<p class="hint"><a href="%s?p=system&amp;scan=1#wifi">Scan again for networks</a></p>' "$SELF"; fi
}

account_fields() {
    current=$(admin_user)
    printf '<label>Username <input name="admin_user" value="%s" maxlength="31" autocapitalize="none" autocomplete="username" required></label>' "$(h "${current:-admin}")"
    printf '<label>%s <input name="admin_pass" type="password" maxlength="64" autocomplete="new-password"></label>' "$([ -n "$current" ] && echo 'New password (blank keeps the current one)' || echo 'Password (8+ characters)')"
    printf '<label>Confirm password <input name="admin_pass2" type="password" maxlength="64" autocomplete="new-password"></label>'
}

setup_page() {
    page_start "Set up your camera"
    printf '<header class="top narrow"><div class="bar"><div class="brand"><span class="name">Set up your camera</span></div><div class="who">Vision AI DevKit RTSP camera</div></div></header><main class="narrow">'
    show_message
    form_start setup
    printf '<section class="card"><div class="card-head"><h2>1. Your Wi-Fi</h2></div>'
    network_fields auto
    printf '</section><section class="card"><div class="card-head"><h2>2. Admin account</h2></div>'
    hint "Signs in to this page from your network, to the camera's streams, and over SSH."
    printf '<div class="fields">'
    account_fields
    printf '</div></section><section class="card"><div class="card-head"><h2>3. Camera</h2></div>'
    printf '<label>Camera name <input name="name" value="%s" maxlength="32" required></label>' "$(h "$NAME")"
    printf '<label>Streams (main + sub) <select name="profile">'
    option hd "1080p + 640x360 (recommended)" hd
    option 4k "4K + 720p" ""
    printf '</select></label>'
    hint "You can fine-tune resolution, frame rate and bitrate later."
    printf '<label class="check"><input type="checkbox" name="audio" value="1"%s> Include microphone audio on the main stream</label>' "$([ "$AUDIO_ENABLED" = 1 ] && echo ' checked')"
    hint "Recording sound can be regulated where you live; let people know the camera records audio."
    printf '</section><div class="actions"><button>Save and connect</button></div></form>'
    page_end
}

# ----- Overview -----

rate_text() { if [ $(( $1 % 1000000 )) = 0 ]; then echo "$(( $1 / 1000000 )) Mbps"; else echo "$(( $1 / 1000 )) kbps"; fi; }
main_summary() {
    if [ "$MAIN_CODEC" = 0 ]; then codec=H.265; else codec=H.264; fi
    printf '%sx%s, %s fps, %s, %s' "$MAIN_WIDTH" "$MAIN_HEIGHT" "$MAIN_FPS" "$codec" "$(rate_text "$MAIN_BITRATE")"
    if [ "$AUDIO_ENABLED" = 1 ]; then printf ', with sound'; fi
}
sub_summary() { printf '%sx%s, %s fps, H.264, %s' "$SUB_WIDTH" "$SUB_HEIGHT" "$SUB_FPS" "$(rate_text "$SUB_BITRATE")"; }

# Badges: "CLASS TEXT" for section_start and feature (on, off or warn)
detect_badge() {
    if [ "$DETECT" != 1 ]; then echo "off Off"
    elif ! systemctl -q is-active vaidk-detect.service; then echo "warn Stopped"
    elif [ "$(detect_value status)" = running ]; then echo "on On"
    else echo "warn Starting"; fi
}
mqtt_badge() {
    if [ "$MQTT" != 1 ]; then echo "off Off"
    elif [ -z "$MQTT_HOST" ] || [ "$DETECT" != 1 ]; then echo "warn Waiting"
    elif ! systemctl -q is-active vaidk-mqtt.service; then echo "warn Stopped"
    else
        case "$(mqtt_value status)" in connected) echo "on Connected" ;; error) echo "warn Error" ;; *) echo "warn Connecting" ;; esac
    fi
}
hdmi_badge() {
    if [ "$HDMI" != 1 ]; then echo "off Off"
    elif pidof weston >/dev/null; then echo "on Live view"
    else echo "warn Starting"; fi
}
overlay_badge() {
    case "$OVERLAY" in
        time) echo "on Date and time" ;; name) echo "on Camera name" ;; time-name) echo "on Date, time and name" ;;
        *) echo "off Off" ;;
    esac
}

feature() { # feature TAB CARD LABEL BADGE_CLASS BADGE_TEXT...: a line of the Features tile
    _ft=$1; _fc=$2; _fl=$3; _fb=$4; shift 4
    printf '<li><a href="%s?p=%s#%s">%s</a><span class="badge %s">%s</span></li>' "$SELF" "$_ft" "$_fc" "$_fl" "$_fb" "$(h "$*")"
}
tile_link() { printf '<div class="actions"><a class="button secondary" href="%s?p=%s">%s</a>' "$SELF" "$1" "$2"; } # TAB LABEL

ov_streams() {
    if [ -e "$RUN_DIR/streaming" ]; then section_start ov-streams "Streams" on Streaming
    else section_start ov-streams "Streams" warn "Starting or recovering"; fi
    printf '<dl><dt>Main</dt><dd><code class="url">rtsp://%s:8900/live</code><br><span class="muted">%s</span></dd>' "${ip:-camera-ip}" "$(h "$(main_summary)")"
    if [ "$SUB_ENABLED" = 1 ]; then
        printf '<dt>Sub</dt><dd><code class="url">rtsp://%s:8901/live</code><br><span class="muted">%s</span></dd>' "${ip:-camera-ip}" "$(h "$(sub_summary)")"
    else
        item "Sub" "Off"
    fi
    item "Players" "$(viewers_text)"
    case "$(stream_auth)" in
        on) item "Sign-in" "Admin account ($(admin_user))" ;;
        off) item "Sign-in" "Off: anyone on your network can watch" ;;
        locked) printf '<dt>Sign-in</dt><dd><span class="badge warn">Locked</span> <a href="%s?p=video#stream-auth">Enter the admin password</a> to unlock the streams</dd>' "$SELF" ;;
    esac
    printf '</dl>'
    tile_link video "Stream settings"
    form_start restart-streams; printf '<button class="secondary">Restart streams</button></form></div>'
    section_end
}

ov_detect() {
    section_start ov-detect "Object detection" $(detect_badge)
    if [ "$DETECT" = 1 ]; then
        printf '<dl>'
        if [ "$(detect_value status)" = running ]; then item "In view" "$(in_view)"; fi
        item "Status" "$(detect_status)"
        printf '</dl>'
    else
        hint "The camera's own detector can find people, vehicles and animals, draw boxes around them on the main stream, and tell your MQTT broker."
    fi
    tile_link detect "Detection settings"; printf '</div>'
    section_end
}

ov_health() {
    power_read
    section_start ov-health "Health"
    printf '<dl>'
    cpu=$(cpu_busy 0.5)
    if [ -n "$cpu" ]; then item "Processor" "$cpu% busy"; fi
    temps=$(temperatures)
    if [ -n "$temps" ]; then printf '<dt>Temperatures</dt><dd>%s</dd>' "$temps"; fi
    m=$(mem_text)
    if [ -n "$m" ]; then item "Memory" "$m"; fi
    set -- $(storage_kb)
    if [ "${1:-0}" -gt 0 ]; then item "Storage" "$(fmt_kb "$2") of $(fmt_kb "$1") used ($(( $2 * 100 / $1 ))%)"; fi
    b=$(battery_text)
    if [ -n "$b" ]; then item "Battery" "$b"; fi
    if [ "$pc" = 1 ]; then printf '<dt>Power</dt><dd class="warn-text">%s</dd>' "$(h "$(power_text)")"
    else item "Power" "$(power_text)"; fi
    if [ -s "$RUN_DIR/crashes" ]; then item "Crashes" "$(crash_text)"; fi
    item "Running for" "$(uptime_text)"
    printf '</dl>'
    tile_link system "System details"; printf '</div>'
    section_end
}

ov_wifi() {
    if [ -n "$ip" ]; then
        section_start ov-wifi "Wi-Fi" on Connected
        sig=$(wifi_signal)
        printf '<dl>'
        item "Network" "$(wifi_ssid)"
        if [ -n "$sig" ]; then item "Signal" "$sig dBm, $(signal_word "$sig")"; fi
        item "Address" "$ip"
        link=$(wifi_link)
        if [ -n "$link" ]; then item "Link" "$link"; fi
        printf '</dl>'
    else
        section_start ov-wifi "Wi-Fi" warn "Not connected"
        s=$(saved_ssid)
        hint "$(h "Not connected${s:+. Saved network: $s}")"
    fi
    printf '<div class="actions"><a class="button secondary" href="%s?p=system#wifi">Wi-Fi settings</a></div>' "$SELF"
    section_end
}

ov_features() {
    section_start ov-features "Features"
    printf '<ul class="states">'
    if [ "$AUDIO_ENABLED" = 1 ]; then feature audio mic "Microphone" on "On, +$AUDIO_GAIN_DB dB"
    else feature audio mic "Microphone" off Off; fi
    if [ "$TALKBACK" = 1 ]; then feature audio talk "Talk-back" on "On, volume $SPEAKER_VOLUME%"
    else feature audio talk "Talk-back" off Off; fi
    feature ptz ptz "Pan, tilt and zoom" $(onoff "$ONVIF")
    feature video overlay "On-screen text" $(overlay_badge)
    feature detect mqtt "MQTT" $(mqtt_badge)
    feature video hdmi "HDMI output" $(hdmi_badge)
    printf '</ul>'
    section_end
}

overview_page() {
    printf '<div class="tiles">'
    ov_streams; ov_detect; ov_health; ov_wifi; ov_features
    printf '</div>'
}

# ----- System section -----

fmt_kb() { # fmt_kb KILOBYTES -> "1.3 GB", "75 MB" or "512 KB"
    if [ "$1" -ge 1048576 ]; then g=$(( ($1 * 10 + 524288) / 1048576 )); printf '%d.%d GB' $((g / 10)) $((g % 10))
    elif [ "$1" -ge 1024 ]; then printf '%d MB' $(( ($1 + 512) / 1024 ))
    else printf '%d KB' "$1"; fi
}
ghz() { g=$(( ($1 + 50000) / 100000 )); printf '%d.%d' $((g / 10)) $((g % 10)); }    # kHz
volts() { v=$(( ($1 + 5000) / 10000 )); printf '%d.%02d' $((v / 100)) $((v % 100)); } # microvolts
age() { # age SECONDS -> "5 min", "3 h" or "2 days"
    if [ "$1" -lt 3600 ]; then echo "$(( $1 / 60 )) min"
    elif [ "$1" -lt 172800 ]; then echo "$(( $1 / 3600 )) h"
    else echo "$(( $1 / 86400 )) days"; fi
}

system_snapshot() { # system_snapshot N: the counters system_load compares
    up=0; tx=0; rx=0
    read -r up _ 2>/dev/null < /proc/uptime
    read -r tx 2>/dev/null < /sys/class/net/wlan0/statistics/tx_bytes
    read -r rx 2>/dev/null < /sys/class/net/wlan0/statistics/rx_bytes
    echo "@ $1 $up $tx $rx"
    grep '^cpu' /proc/stat
    cat /proc/[0-9]*/stat 2>/dev/null
}
system_load() { # "cpu %", "cores % ...", "net TX RX" (Mbit/s) and "top % PID NAME" lines, over one second
    # Both readings come first, so that working them out doesn't count as load.
    s1=$(system_snapshot 1); sleep 1; s2=$(system_snapshot 2)
    printf '%s\n%s\n' "$s1" "$s2" | awk '
        function pct(b2, b1, a2, a1) { return (a2 > a1) ? int(100 * (b2 - b1) / (a2 - a1) + 0.5) : "" }
        $1 == "@" { s = $2; up[s] = $3; tx[s] = $4; rx[s] = $5; next }
        /^cpu/ {
            b = $2 + $3 + $4 + $7 + $8 + $9; busy[s, $1] = b; all[s, $1] = b + $5 + $6
            if (s == 1 && $1 != "cpu") core[++nc] = $1
            next
        }
        {   # /proc/PID/stat: "PID (NAME) STATE ...", where NAME may hold spaces and brackets
            r = $0; k = 0
            while ((p = index(r, ")")) > 0) { k += p; r = substr(r, p + 1) }
            split(substr($0, k + 2), f, " ")
            if (s == 1) { t1[$1] = f[12] + f[13]; next }
            if ($1 in t1) { used[$1] = f[12] + f[13] - t1[$1]; i = index($0, "("); name[$1] = substr($0, i + 1, k - i - 1) }
        }
        END {
            dt = up[2] - up[1]; if (dt <= 0) dt = 1
            printf "cpu %s\ncores", pct(busy[2, "cpu"], busy[1, "cpu"], all[2, "cpu"], all[1, "cpu"])
            for (i = 1; i <= nc; i++) { c = core[i]; v = pct(busy[2, c], busy[1, c], all[2, c], all[1, c]); if (v != "") printf " %s", v }
            printf "\nnet %.1f %.1f\n", (tx[2] - tx[1]) * 8 / dt / 1e6, (rx[2] - rx[1]) * 8 / dt / 1e6
            for (n = 0; n < 5; n++) { # in % of one core: the kernel counts 100 ticks a second
                best = ""
                for (p in used) if (best == "" || used[p] > used[best]) best = p
                if (best == "" || used[best] / dt < 1) break
                printf "top %d %s %s\n", used[best] / dt + 0.5, best, name[best]
                delete used[best]
            }
        }'
}
prog_label() { # prog_label PID NAME: how the busiest-programs list shows a program
    case "$2" in
        python3*)
            case "$(tr '\0' ' ' 2>/dev/null < "/proc/$1/cmdline")" in
                *rtspd.py*) echo "rtspd.py (RTSP)" ;;
                *onvifd.py*) echo "onvifd.py (PTZ)" ;;
                *mqttd.py*) echo "mqttd.py (MQTT)" ;;
                *) echo "$2" ;;
            esac ;;
        qmmf-server) echo "qmmf-server (camera)" ;;
        vaidk-camd) echo "vaidk-camd (streams)" ;;
        vaidk-detect) echo "vaidk-detect (object detection)" ;;
        altekflow) echo "altekflow (lights)" ;;
        dockerd|containerd) echo "$2 (Docker, unused)" ;;
        *) echo "$2" ;;
    esac
}
cpu_limit() { # "; top speed limited to X of Y GHz" when something (such as heat) holds the processor back
    for d in /sys/devices/system/cpu/cpufreq/policy*; do
        m=; x=
        read -r m 2>/dev/null < "$d/scaling_max_freq"
        read -r x 2>/dev/null < "$d/cpuinfo_max_freq"
        if [ -n "$m" ] && [ -n "$x" ] && [ "$m" -lt "$x" ]; then
            printf '; top speed limited to %s of %s GHz' "$(ghz "$m")" "$(ghz "$x")"
            return
        fi
    done
}
temperatures() { # "processor 52 &deg;C, camera 51 &deg;C, Wi-Fi 50 &deg;C" (HTML). The battery's sensor reads
    # a fixed value on this camera (README.md), so it isn't shown.
    set -- $(grep -E '^(cpu[0-9]+-(silver|gold)-usr|camera-usr|wlan-usr)$' /sys/class/thermal/thermal_zone*/type 2>/dev/null |
        while IFS=: read -r f z; do v=; read -r v 2>/dev/null < "${f%/type}/temp" && echo "${z%%-*} $v"; done |
        awk '{ k = ($1 ~ /^cpu/) ? "cpu" : $1; if (!(k in m) || $2 > m[k]) m[k] = $2 }
            END { split("cpu camera wlan", ks, " "); for (i = 1; i <= 3; i++) printf "%s ", (ks[i] in m) ? int(m[ks[i]] / 1000 + 0.5) : "-" }')
    out=""
    if [ "${1:--}" != - ]; then out="processor $1 &deg;C"; fi
    if [ "${2:--}" != - ]; then out="$out${out:+, }camera $2 &deg;C"; fi
    if [ "${3:--}" != - ]; then out="$out${out:+, }Wi-Fi $3 &deg;C"; fi
    printf '%s' "$out"
}
viewers_of() { # viewers_of main|sub -> "192.168.1.20, 192.168.1.30 (2 connections)": players, as the RTSP server lists them
    awk -v k="$1_viewers=" 'index($0, k) == 1 {
            n = split(substr($0, length(k) + 1), a, " ")
            for (i = 1; i <= n; i++) c[a[i]]++
            for (ip in c) printf "%s%s%s", (s++ ? ", " : ""), ip, (c[ip] > 1 ? " (" c[ip] " connections)" : "")
        }' "$RUN_DIR/rtsp.status" 2>/dev/null
}

viewers_text() { # "main: 192.168.1.20; sub: none"
    main=$(viewers_of main); sub=$(viewers_of sub)
    v="main: ${main:-none}"
    if [ "$SUB_ENABLED" = 1 ] || [ -n "$sub" ]; then v="$v; sub: ${sub:-none}"; fi
    printf '%s' "$v"
}
cpu_busy() { # cpu_busy SECONDS: how busy the processor was over that time, in % (as system_load counts it)
    read -r _ a1 b1 c1 d1 e1 f1 g1 h1 _ < /proc/stat
    sleep "$1"
    read -r _ a2 b2 c2 d2 e2 f2 g2 h2 _ < /proc/stat
    busy=$(( a2 + b2 + c2 + f2 + g2 + h2 - a1 - b1 - c1 - f1 - g1 - h1 ))
    all=$(( busy + d2 + e2 - d1 - e1 ))
    if [ "$all" -gt 0 ]; then echo $(( (100 * busy + all / 2) / all )); fi
}
mem_text() { # "614 MB of 1.8 GB in use (33%)"
    set -- $(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { print t - a, t + 0 }' /proc/meminfo)
    if [ "${2:-0}" -gt 0 ]; then printf '%s of %s in use (%s%%)' "$(fmt_kb "$1")" "$(fmt_kb "$2")" "$(( $1 * 100 / $2 ))"; fi
}
storage_kb() { # "DATA_TOTAL DATA_USED ROOT_TOTAL ROOT_USED RAM_USED", in KB
    df -Pk /data / /run /var/volatile 2>/dev/null |
        awk 'NR > 1 { t[$6] = $2; u[$6] = $3 } END { print t["/data"] + 0, u["/data"] + 0, t["/"] + 0, u["/"] + 0, u["/run"] + u["/var/volatile"] }'
}
power_read() { # the battery and the power sources, into pcap st uv usb uvolts pc pcmax dc
    P=/sys/class/power_supply
    pcap=; st=; uv=; usb=; uvolts=; pc=; pcmax=; dc=
    read -r pcap 2>/dev/null < $P/battery/capacity
    read -r st 2>/dev/null < $P/battery/status
    read -r uv 2>/dev/null < $P/battery/voltage_now
    read -r usb 2>/dev/null < $P/usb/online
    read -r uvolts 2>/dev/null < $P/usb/voltage_now
    read -r pc 2>/dev/null < $P/pc_port/online
    read -r pcmax 2>/dev/null < $P/pc_port/current_max
    read -r dc 2>/dev/null < $P/dc/online
}
battery_text() { # after power_read: "100%, full, 4.17 V"
    [ -n "$pcap" ] || return 0
    case "$st" in Charging) bst=charging ;; Discharging) bst="on battery" ;; Full) bst=full ;; "Not charging") bst="not charging" ;; *) bst=$st ;; esac
    printf '%s%%, %s%s' "$pcap" "$bst" "${uv:+, $(volts "$uv") V}"
}
power_text() { # after power_read: where the power comes from
    if [ "$pc" = 1 ]; then printf "a computer's USB port%s: the battery can run down while streaming" "${pcmax:+ (up to $((pcmax / 1000)) mA)}"
    elif [ "$usb" = 1 ]; then printf 'USB charger%s' "${uvolts:+, $(volts "$uvolts") V}"
    elif [ "$dc" = 1 ]; then printf 'DC input'
    else printf 'none, running on the battery'; fi
}
crash_text() { # "3 (latest: weston, signal 5, 1 h ago)", or "none"
    if [ -s "$RUN_DIR/crashes" ]; then
        set -- $(tail -n 1 "$RUN_DIR/crashes")
        ago=$(( $(date +%s) - $1 ))
        if [ "$ago" -ge 0 ]; then ago=", $(age "$ago") ago"; else ago=""; fi
        printf '%s (latest: %s, signal %s%s)' "$(wc -l < "$RUN_DIR/crashes")" "$2" "$3" "$ago"
    else
        printf 'none'
    fi
}
wifi_link() { # "5 GHz, channel 149, 433.3 Mbit/s"
    iw dev wlan0 link 2>/dev/null | awk '/freq:/ { f = $2 } /tx bitrate:/ { r = $3 }
        END { if (f) { b = "2.4"; c = (f == 2484) ? 14 : (f - 2407) / 5; if (f > 4000) { b = "5"; c = (f - 5000) / 5 }
                       printf "%s GHz, channel %d, %s Mbit/s", b, c, r } }'
}

system_section() {
    load=$(system_load)
    cpu=; cores=; tx_rate=; rx_rate=; progs=
    while read -r key k1 k2 k3; do
        case "$key" in
            cpu) cpu=$k1 ;;
            cores) cores="$k1 $k2 $k3" ;;
            net) tx_rate=$k1; rx_rate=$k2 ;;
            top) progs="$progs${progs:+, }$(prog_label "$k2" "$k3") $k1%" ;;
        esac
    done <<EOF
$load
EOF
    section_start system "System"
    printf '<dl>'
    if [ -n "$cpu" ]; then
        per=""
        for v in $cores; do per="$per${per:+, }$v%"; done
        item "Processor" "$cpu% busy${per:+ (cores: $per)}$(cpu_limit)"
    fi
    if [ -n "$progs" ]; then item "Busiest programs" "$progs (of one core)"; fi
    m=$(mem_text)
    if [ -n "$m" ]; then item "Memory" "$m"; fi
    temps=$(temperatures)
    if [ -n "$temps" ]; then printf '<dt>Temperatures</dt><dd>%s</dd>' "$temps"; fi

    set -- $(storage_kb)
    if [ "${1:-0}" -gt 0 ]; then item "Data storage" "$(fmt_kb "$2") of $(fmt_kb "$1") used ($(( $2 * 100 / $1 ))%)"; fi
    if [ "${3:-0}" -gt 0 ]; then item "System storage" "$(fmt_kb "$4") of $(fmt_kb "$3") used (read-only)"; fi
    cap=$(sed -n 's/^[[:space:]]*RuntimeMaxUse=//p' /etc/systemd/journald.conf 2>/dev/null | tail -n 1)
    case "$cap" in *M) cap="${cap%M} MB" ;; *G) cap="${cap%G} GB" ;; esac
    item "Logs and temporary files" "$(fmt_kb "${5:-0}") in RAM${cap:+; the system log keeps up to $cap}"
    w=; read -r _ _ _ _ _ _ w _ 2>/dev/null < /sys/block/mmcblk0/stat
    up=$(uptime_s)
    if [ -n "$w" ] && [ "$up" -gt 0 ]; then
        item "Flash writes" "$(fmt_kb $((w / 2))) since start, on average $(fmt_kb $((w / 2 * 86400 / up))) a day"
    fi
    la=0; lb=0; eol=0
    read -r la lb 2>/dev/null < /sys/block/mmcblk0/device/life_time
    read -r eol 2>/dev/null < /sys/block/mmcblk0/device/pre_eol_info
    lt=$(( ${la:-0} > ${lb:-0} ? ${la:-0} : ${lb:-0} ))
    wear=""
    if [ "$lt" -ge 1 ] && [ "$lt" -le 10 ]; then wear="$((lt * 10 - 10))&ndash;$((lt * 10))% of its rated life used"
    elif [ "$lt" -ge 11 ]; then wear="past its rated life"; fi
    case "$(( ${eol:-0} ))" in
        2) wear="$wear${wear:+; }spare blocks running low" ;;
        3) wear="$wear${wear:+; }spare blocks nearly used up" ;;
    esac
    if [ -n "$wear" ]; then printf '<dt>Flash wear</dt><dd>%s</dd>' "$wear"; fi

    power_read
    b=$(battery_text)
    if [ -n "$b" ]; then item "Battery" "$b"; fi
    item "Power" "$(power_text)"

    link=$(wifi_link)
    if [ -n "$link" ]; then item "Wi-Fi link" "$link"; fi
    txb=0; rxb=0
    read -r txb 2>/dev/null < /sys/class/net/wlan0/statistics/tx_bytes
    read -r rxb 2>/dev/null < /sys/class/net/wlan0/statistics/rx_bytes
    item "Wi-Fi traffic" "sending ${tx_rate:-0} Mbit/s, receiving ${rx_rate:-0} Mbit/s; since start $(fmt_kb $((txb / 1024))) sent, $(fmt_kb $((rxb / 1024))) received"
    item "Stream viewers" "$(viewers_text)"
    item "Crashes since start" "$(crash_text)"
    item "Running for" "$(uptime_text)"
    fw=; read -r fw 2>/dev/null < /etc/version
    if [ -n "$fw" ]; then item "Firmware" "$fw"; fi
    printf '</dl>'
    hint "Measured over one second as the page loaded. <a href=\"$SELF?p=system\">Measure again</a>"
    section_end
}

streams_section() {
    section_start streams "Streams"
    form_start camera
    printf '<fieldset><legend>Main stream <span class="muted">port 8900</span></legend><div class="fields"><label>Resolution <select name="main_res">'
    cur="${MAIN_WIDTH}x$MAIN_HEIGHT"
    option 3840x2160 "4K (3840x2160)" "$cur"; option 1920x1080 "1080p (1920x1080)" "$cur"; option 1280x720 "720p (1280x720)" "$cur"
    printf '</select></label><label>Frame rate <select name="main_fps">'
    for f in 30 25 20 15; do option $f "$f fps" "$MAIN_FPS"; done
    printf '</select></label><label>Bitrate <select name="main_kbps">'
    for b in 2000 4000 6000 8000; do option $b "$((b / 1000)) Mbps" "$((MAIN_BITRATE / 1000))"; done
    printf '</select></label><label>Codec <select name="codec">'
    option 1 "H.264 (any player)" "$MAIN_CODEC"; option 0 "H.265 (smaller)" "$MAIN_CODEC"
    printf '</select></label></div></fieldset><fieldset><legend>Sub stream <span class="muted">port 8901</span></legend>'
    if [ "$DETECT" = 1 ]; then
        # post_camera keeps these too.
        hint "On, at 640x360: object detection works from the sub stream. Turn detection off to change these."
        printf '<input type="hidden" name="sub" value="1"><input type="hidden" name="sub_res" value="640x360"><div class="fields">'
    else
        printf '<div class="fields"><label>On or off <select name="sub">'
        option 1 On "$SUB_ENABLED"; option 0 Off "$SUB_ENABLED"
        printf '</select></label><label>Resolution <select name="sub_res">'
        cur="${SUB_WIDTH}x$SUB_HEIGHT"
        option 1280x720 "720p (1280x720)" "$cur"; option 640x360 "640x360" "$cur"
        printf '</select></label>'
    fi
    printf '<label>Frame rate <select name="sub_fps">'
    for f in 5 10 15; do option $f "$f fps" "$SUB_FPS"; done
    printf '</select></label><label>Bitrate <select name="sub_kbps">'
    for b in 300 500 1000 2000; do option $b "$b kbps" "$((SUB_BITRATE / 1000))"; done
    printf '</select></label></div></fieldset>'
    more "About the streams" "The sub stream is always H.264, the best for Frigate's detection. H.264 plays everywhere; H.265 makes smaller files, but not every player or browser shows it. Tested: 1080p at 15 or 30 fps up to 8 Mbps, 4K at 8 Mbps, and a sub stream of 640x360 or 720p at 5 or 10 fps. The microphone is on the Audio tab."
    save_row "Save and restart streams"
    printf '</form>'
    section_end
}

stream_auth_section() {
    state=$(stream_auth)
    case "$state" in
        on) section_start stream-auth "Stream sign-in" on On ;;
        off) section_start stream-auth "Stream sign-in" off Off ;;
        locked) section_start stream-auth "Stream sign-in" warn Locked ;;
        *) section_start stream-auth "Stream sign-in" warn "Not running" ;;
    esac
    user=$(h "$(admin_user)")
    case "$state" in
        on)
            hint "Players sign in to both streams, and to talk-back, with the admin account: user <b>$user</b> and its password. Most take them in the stream address: <code>rtsp://$user:PASSWORD@camera-ip:8900/live</code>. The Frigate tab has Frigate's addresses." ;;
        locked)
            case "$(stream_auth_reason)" in
                no-account) printf '<p class="error">The streams are locked until the admin account exists (System tab).</p>' ;;
                password-changed) printf '<p class="error">The admin password was changed outside this page, so the streams are locked. Enter it here to unlock them.</p>' ;;
                *) printf '<p class="error">The streams are locked until you enter the admin password here once: after an update that added stream sign-in, or when an existing account became the admin account.</p>' ;;
            esac
            if [ -n "$user" ]; then
                form_start stream-key
                printf '<div class="fields"><label>Password of <b>%s</b> <input name="stream_pass" type="password" maxlength="64" autocomplete="current-password" required></label></div>' "$user"
                save_row "Unlock streams"
                printf '</form>'
            fi ;;
        off)
            hint "Off (<code>STREAM_AUTH=0</code> in the settings file): anyone who can reach the camera can watch the streams and use its speaker." ;;
        *)
            hint "The RTSP server isn't running; restart the streams or the camera (System tab)." ;;
    esac
    more "About stream sign-in" "Digest sign-in: the password itself never crosses the network, but the video isn't encrypted, so keep the camera on a trusted network. A new admin password is also the streams' new password: update Frigate and other players. Pan, tilt and zoom (ONVIF) has no sign-in."
    section_end
}

picture_section() {
    section_start picture "Picture"
    form_start picture
    printf '<div class="fields"><label>Light flicker <select name="antiflicker">'
    options "$ANTIFLICKER" auto "Automatic" 60 "60 Hz (the Americas)" 50 "50 Hz (elsewhere)" off "Off"
    printf '</select></label><label>Exposure <select name="exposure">'
    options "$EXPOSURE_EV" -2 "-2 (darker)" -1.5 "-1.5" -1 "-1" -0.5 "-0.5" 0 "0 (automatic)" 0.5 "+0.5" 1 "+1" 1.5 "+1.5" 2 "+2 (brighter)"
    printf '</select></label><label>White balance <select name="white_balance">'
    options "$WHITE_BALANCE" auto "Automatic" daylight "Daylight" cloudy "Cloudy" shade "Shade" twilight "Twilight" \
        incandescent "Incandescent (warm bulbs)" fluorescent "Fluorescent" warm-fluorescent "Warm fluorescent"
    printf '</select></label><label>Colour <select name="saturation">'
    options "$SATURATION" 0 "0 (black and white)" 1 1 2 2 3 3 4 4 5 "5 (normal)" 6 6 7 7 8 8 9 9 10 "10 (vivid)"
    printf '</select></label><label>Sharpness <select name="sharpness">'
    options "$SHARPNESS" 0 "0 (soft)" 1 1 2 "2 (normal)" 3 3 4 4 5 5 6 "6 (sharpest)"
    printf '</select></label></div>'
    hint "If lights band or flicker, set the light flicker to your mains frequency: 60 Hz in most of the Americas, 50 Hz in most other places."
    save_row "Save" "Applies within a second, without restarting the streams."
    printf '</form>'
    section_end
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
    if [ "$OVERLAY" = off ]; then section_start overlay "On-screen text" off Off
    else section_start overlay "On-screen text" on On; fi
    form_start overlay
    printf '<div class="fields"><label>Show <select name="overlay">'
    options "$OVERLAY" off "Nothing" time "Date and time" name "Camera name" time-name "Date, time and camera name"
    printf '</select></label><label>Date and time <select name="overlay_position">'
    options "$OVERLAY_POSITION" top-left "Top left" top-right "Top right" bottom-left "Bottom left" bottom-right "Bottom right"
    printf '</select></label><label>Streams <select name="overlay_streams">'
    options "$OVERLAY_STREAMS" main "Main stream only" both "Main and sub streams"
    printf '</select></label><label>Time zone <select name="tz">'
    tz_options
    printf '</select></label></div>'
    printf '<details class="more"><summary>Another time zone</summary><label>Time zone in POSIX form <input name="tz_custom" maxlength="64" placeholder="EST5EDT,M3.2.0,M11.1.0" autocapitalize="none" autocomplete="off"></label></details>'
    hint "The camera name goes on the other edge of the same side."
    more "About the clock" "The camera sets its clock from the internet, so the time is right once it has been online. Frigate detects on the sub stream, where a ticking clock can count as motion: keep the text on the main stream only unless you need it there."
    save_row "Save and restart streams"
    printf '</form>'
    section_end
}

mic_section() {
    section_start mic "Microphone" $(onoff "$AUDIO_ENABLED")
    form_start audio
    printf '<div class="fields"><label>Sound on the main stream <select name="audio">'
    options "$AUDIO_ENABLED" 1 "On" 0 "Off"
    printf '</select></label><label>Gain <select name="gain">'
    options "$AUDIO_GAIN_DB" 0 "+0 dB" 6 "+6 dB" 12 "+12 dB" 18 "+18 dB" 24 "+24 dB" 30 "+30 dB" 36 "+36 dB" 40 "+40 dB"
    printf '</select></label></div>'
    hint "The camera's microphones, as AAC at 48 kHz, mono. Raise the gain if Frigate's audio level stays low. Recording sound can be regulated where you live."
    save_row "Save" "Changes restart the streams."
    printf '</form>'
    section_end
}

talk_section() {
    section_start talk "Talk-back" $(onoff "$TALKBACK")
    form_start talk
    printf '<div class="fields"><label>On or off <select name="talkback">'
    options "$TALKBACK" 1 "On" 0 "Off"
    printf '</select></label><label>Speaker volume <select name="volume">'
    options "$SPEAKER_VOLUME" 100 "100%" 90 "90%" 80 "80%" 70 "70%" 60 "60%" 50 "50%" 40 "40%" 30 "30%" 20 "20%" 10 "10%"
    printf '</select></label></div>'
    printf '<label class="check"><input type="checkbox" name="mute_mic" value="1"%s> Mute the microphones while the speaker plays, so the other end doesn'"'"'t hear itself</label>' \
        "$([ "$TALKBACK_MUTE_MIC" = 1 ] && echo ' checked')"
    if [ "$STREAM_AUTH" != 0 ]; then
        hint "A two-way audio channel on the main stream, for Frigate's talk button. It uses the streams' sign-in (Video tab)."
    else
        hint "A two-way audio channel on the main stream, for Frigate's talk button. It has no password: anyone who can reach the camera can use the speaker."
    fi
    more "About talk-back" "It is an ONVIF backchannel with G.711 audio, which Frigate's go2rtc uses. Talking from a browser needs WebRTC and a page on HTTPS (see the Frigate tab). Volume and muting change at once; turning talk-back on or off restarts the streams."
    # Test speaker submits the chime form below, so the two buttons sit together.
    printf '<div class="actions"><button>Save</button><button class="secondary" form="chime">Test speaker</button></div></form>'
    form_start chime "" chime; printf '</form>'
    section_end
}

ptz_section() {
    section_start ptz "Pan, tilt and zoom" $(onoff "$ONVIF")
    form_start onvif
    printf '<div class="fields"><label>On or off <select name="onvif">'
    options "$ONVIF" 1 "On" 0 "Off"
    printf '</select></label></div>'
    hint "Digital: the camera shows part of its 4K picture, up to 4x, on both streams. Frigate and Home Assistant move it over ONVIF (port $ONVIF_PORT). It has no password: anyone who can reach the camera can move the view."
    save_row "Save" "Off shows the whole picture."
    printf '</form>'
    section_end
    [ "$ONVIF" = 1 ] || return 0
    section_start ptz-view "View and presets"
    state=$(ptz_local)
    zoom=$(printf '%s\n' "$state" | sed -n 's/^zoom=//p')
    if [ -z "$zoom" ]; then
        hint "The pan, tilt and zoom service isn't answering yet."
        section_end
        return 0
    fi
    if [ "$zoom" = 1.00 ]; then now="the whole picture"; else now="${zoom}x zoom"; fi
    printf '<div class="row"><span class="preset">Now: %s</span>' "$now"
    form_start ptz; printf '<input type="hidden" name="do" value="full"><button class="secondary">Show the whole picture</button></form></div>'
    printf '<h3>Presets</h3>'
    presets=$(printf '%s\n' "$state" | sed -n 's/^preset=//p')
    if [ -z "$presets" ]; then hint "No presets yet."; fi
    printf '%s\n' "$presets" | while read -r t name; do
        [ -n "$t" ] || continue
        printf '<div class="row"><span class="preset">%s</span>' "$(h "$name")"
        form_start ptz; printf '<input type="hidden" name="do" value="goto"><input type="hidden" name="token" value="%s"><button class="secondary">Go</button></form>' "$(h "$t")"
        form_start ptz; printf '<input type="hidden" name="do" value="delete"><input type="hidden" name="token" value="%s"><button class="secondary">Delete</button></form></div>' "$(h "$t")"
    done
    form_start ptz save-preset
    printf '<input type="hidden" name="do" value="save"><label>Save the current view as <input name="name" maxlength="32" placeholder="Front door" required></label><button>Save preset</button></form>'
    hint "Move the view from Frigate or Home Assistant, then save it here: Frigate goes to presets but can't save them, and lists new ones after it restarts."
    section_end
}

# ----- Object detection section -----

OBJECTS_FILE=$VAIDK_DIR/detect/objects.txt
objects_list() { grep -v '^#' "$OBJECTS_FILE" 2>/dev/null; } # what the built-in model can report
detect_value() { sed -n "s/^$1=//p" "$RUN_DIR/detect.state" 2>/dev/null | head -n 1; } # detect_value KEY

detect_status() { # one line: what the detector is doing
    if [ "$DETECT" != 1 ]; then echo "Off"; return; fi
    st=$(detect_value status); err=$(detect_value error)
    case "$(systemctl is-active vaidk-detect.service 2>/dev/null)" in
        active)
            case "$st" in
                running)
                    rate=$(detect_value rate)
                    if [ "$rate" = 0.0 ]; then echo "Running on the DSP, waiting for frames from the camera"
                    else echo "Running on the DSP: $rate analyses a second, $(detect_value latency_ms) ms each"; fi ;;
                preparing) echo "Copying the built-in model to the camera's storage (27 MB, once)" ;;
                error) echo "Stopping after an error: $err" ;;
                *) echo "Starting" ;;
            esac ;;
        activating) echo "Restarting after an error${err:+: $err}" ;;
        failed) echo "Stopped after repeated errors${err:+: $err}. Save the settings below to try again." ;;
        *) if [ -n "$err" ]; then echo "Off: $err"; else echo "Not running"; fi ;;
    esac
}

in_view() { # "person (2), car (1)" or "nothing"
    v=$(detect_value present | awk -F, '{ for (i = 1; i <= NF; i++) { n = split($i, p, " "); c = p[n]; l = $i; sub(/ [0-9]+$/, "", l); printf "%s%s (%s)", (i > 1) ? ", " : "", l, c } }')
    echo "${v:-nothing}"
}

detect_section() {
    section_start detect "Object detection" $(detect_badge)
    if [ "$DETECT" = 1 ]; then
        printf '<dl>'
        item "Status" "$(detect_status)"
        if [ "$(detect_value status)" = running ]; then
            item "In view" "$(in_view)"
            now=$(date +%s)
            seen=$(sed -n 's/^seen=//p' "$RUN_DIR/detect.state" 2>/dev/null | awk -F'|' -v now="$now" '
                { a = now - $2; t = (a < 60) ? "under a minute" : (a < 3600) ? int(a / 60) " min" : (a < 172800) ? int(a / 3600) " h" : int(a / 86400) " days"
                  printf "%s%s %s ago (%s%%)", (NR > 1) ? ", " : "", $1, t, $3 }')
            if [ -n "$seen" ]; then item "Last seen" "$seen"; fi
            recent=$(TZ="$TIME_ZONE" awk -F'|' 'NR <= 8 {
                    f = (strftime("%Y%m%d", $1) == strftime("%Y%m%d", systime())) ? "%H:%M:%S" : "%b %d %H:%M"
                    printf "%s%s %s %s%%", (NR > 1) ? ", " : "", strftime(f, $1), $2, $3 }' "$RUN_DIR/detect.recent" 2>/dev/null)
            if [ -n "$recent" ]; then item "Recent" "$recent"; fi
            snpe=$(detect_value snpe); snpe=${snpe%%,*}
            item "Model" "SSD MobileNet v1 (COCO), built in${snpe:+; $snpe on the DSP}"
        fi
        printf '</dl>'
    fi
    form_start detect
    printf '<div class="fields"><label>On or off <select name="detect">'
    options "$DETECT" 1 "On" 0 "Off"
    printf '</select></label><label>Lowest confidence <select name="confidence">'
    options "$DETECT_CONFIDENCE" 40 "40%" 50 "50%" 60 "60% (recommended)" 70 "70%" 80 "80%" 90 "90%"
    printf '</select></label><label>Analyses a second <select name="detect_fps">'
    options "$DETECT_FPS" 1 1 2 2 5 5 10 10
    printf '</select></label><label>Boxes on the main stream <select name="boxes">'
    options "$DETECT_BOXES" 1 "On" 0 "Off"
    printf '</select></label></div><fieldset><legend>Objects</legend>'
    # The default objects first; the rest of what the model knows folds away (open when one is ticked).
    defaults=",$(. "$VAIDK_DIR/defaults.conf"; echo "$DETECT_OBJECTS"),"
    open_more=""
    for v in $(printf '%s' "$DETECT_OBJECTS" | tr ',' ' '); do
        case "$defaults" in *",$v,"*) ;; *) open_more=' open' ;; esac
    done
    for pass in main more; do
        if [ $pass = main ]; then printf '<div class="objects">'
        else printf '<details%s><summary>More objects</summary><div class="objects">' "$open_more"; fi
        objects_list | while read -r o; do
            v=${o// /_} # (this BusyBox sh has bash's substitution; a tr for each of 80 objects took 0.5 s)
            case "$defaults" in *",$v,"*) [ $pass = main ] || continue ;; *) [ $pass = more ] || continue ;; esac
            case ",$DETECT_OBJECTS," in *",$v,"*) c=' checked' ;; *) c='' ;; esac
            printf '<label class="check"><input type="checkbox" name="obj" value="%s"%s> %s</label>' "$v" "$c" "$o"
        done
        printf '</div>'
        if [ $pass = more ]; then printf '</details>'; fi
    done
    printf '</fieldset>'
    hint "The camera's own detector runs on its DSP and works from the sub stream, which stays on at 640x360 while detection is on. Labelled boxes go on the main stream; the sub stream stays clean for Frigate."
    more "About detection" "It is SSD MobileNet v1, trained on COCO, and adds about 3% to the processor load. It analyses at most at the sub stream's frame rate ($SUB_FPS fps). Up to 10 boxes are drawn, or 6 with the date and name shown, people first."
    save_row "Save" "Turning it on or off restarts the streams; other changes apply within seconds."
    printf '</form>'
    section_end
}

# ----- MQTT section -----

mqtt_value() { sed -n "s/^$1=//p" "$RUN_DIR/mqtt.state" 2>/dev/null | head -n 1; } # mqtt_value KEY

mqtt_status() { # one line: what the MQTT service is doing
    if [ "$MQTT" != 1 ]; then echo "Off"; return; fi
    if [ -z "$MQTT_HOST" ]; then echo "On, but no broker is set"; return; fi
    if [ "$DETECT" != 1 ]; then echo "Waiting for object detection to be turned on"; return; fi
    if ! systemctl -q is-active vaidk-mqtt.service; then echo "Not running"; return; fi
    case "$(mqtt_value status)" in
        connected) echo "Connected to $MQTT_HOST:$MQTT_PORT; $(mqtt_value published) messages sent" ;;
        error) echo "Can't publish: $(mqtt_value error). Trying again." ;;
        *) echo "Connecting to $MQTT_HOST:$MQTT_PORT" ;;
    esac
}

mqtt_section() {
    section_start mqtt "MQTT" $(mqtt_badge)
    if [ "$MQTT" = 1 ]; then printf '<dl>'; item "Status" "$(mqtt_status)"; printf '</dl>'; fi
    form_start mqtt
    printf '<div class="fields"><label>On or off <select name="mqtt">'
    options "$MQTT" 1 "On" 0 "Off"
    printf '</select></label>'
    printf '<label>Broker <input name="mqtt_host" value="%s" maxlength="253" placeholder="192.168.1.10 or homeassistant.local" autocapitalize="none" autocomplete="off"></label>' "$(h "$MQTT_HOST")"
    printf '<label>Port <input name="mqtt_port" value="%s" maxlength="5" inputmode="numeric"></label>' "$(h "$MQTT_PORT")"
    printf '<label>User name (blank for none) <input name="mqtt_user" value="%s" maxlength="64" autocapitalize="none" autocomplete="off"></label>' "$(h "$MQTT_USER")"
    if [ -s "$DATA_DIR/mqtt-password" ]; then ph="Saved; blank keeps it"; else ph=""; fi
    printf '<label>Password <input name="mqtt_pass" type="password" maxlength="128" placeholder="%s" autocomplete="new-password"></label>' "$ph"
    printf '<label>Topic <input name="mqtt_topic" value="%s" maxlength="64" placeholder="vaidk/%s" autocapitalize="none" autocomplete="off"></label></div>' "$(h "$MQTT_TOPIC")" "$(h "$NAME")"
    printf '<label class="check"><input type="checkbox" name="mqtt_discovery" value="1"%s> Add a sensor for each object to Home Assistant (MQTT discovery)</label>' \
        "$([ "$MQTT_DISCOVERY" = 1 ] && echo ' checked')"
    topic=$(h "${MQTT_TOPIC:-vaidk/$NAME}")
    hint "Publishes what object detection sees, so it needs detection on. Plain MQTT 3.1.1, without TLS: the password and the messages cross your network unencrypted."
    more "Topics" "<code>$topic/status</code> (online or offline); for each chosen object <code>$topic/person</code> (ON or OFF) and <code>$topic/person/count</code>, all retained; and <code>$topic/detections</code> (JSON) after each analysis while something is in view."
    save_row "Save"
    printf '</form>'
    section_end
}

# ----- HDMI section -----

hdmi_section() {
    section_start hdmi "HDMI output" $(hdmi_badge)
    form_start hdmi
    printf '<div class="fields"><label>Show <select name="hdmi">'
    options "$HDMI" 0 "Off" 1 "Live view of the main stream"
    printf '</select></label></div>'
    hint "Live view shows the main stream, with its on-screen text and detection boxes, on a monitor plugged into the camera's HDMI port. Use a computer monitor and a plain HDMI cable."
    more "About live view" "The camera always sends 1920x1080 at 60 Hz without asking the monitor what it supports, so adapters, switches and some TVs won't show it. Live view takes about a fifth of one processor core. Off, the display output is stopped, which saves about 0.8 W, nearly a third of the camera's power."
    save_row "Save" "Turning it on or off restarts the streams."
    printf '</form>'
    section_end
}

wifi_section() {
    section_start wifi "Wi-Fi"
    if [ "$MODE" = lan ]; then
        hint "The camera moves to the new network at once, so this page stops responding. If it can't join within a minute, it returns to the current network."
        if [ -n "$(qparam scan)" ]; then mode=fresh; else mode=cached; fi
    else
        mode=auto
    fi
    form_start wifi
    network_fields "$mode"
    save_row "Join network"
    printf '</form>'
    section_end
}

device_section() {
    section_start device "Camera name and admin account"
    form_start device
    printf '<div class="fields"><label>Camera name <input name="name" value="%s" maxlength="32" required></label>' "$(h "$NAME")"
    account_fields
    printf '</div>'
    if [ "$STREAM_AUTH" != 0 ]; then
        uses="this page from your network, the streams, and SSH"; note=" A new password is also the streams' password: update it in Frigate."
    else
        uses="this page from your network, and SSH"; note=""
    fi
    hint "The name is the page title, the name in Frigate's configuration and on the video, and the camera's host name. The admin account signs in to $uses (<code>ssh $(h "$(admin_user)")@$(h "${ip:-camera-ip}")</code>).$note"
    save_row "Save"
    printf '</form>'
    section_end
}

frigate_section() {
    section_start frigate "Frigate configuration"
    about="Frigate's go2rtc keeps one connection to each stream for recording and detection."
    if [ "$TALKBACK" = 1 ]; then about="$about The live view uses a separate two-way stream, so talking never interrupts a recording. Talking needs WebRTC and a page on HTTPS: Frigate on HTTPS, or Home Assistant on HTTPS with the Advanced Camera Card (see the add-on's README)."; fi
    if [ "$ONVIF" = 1 ]; then about="$about The onvif part gives Frigate's live view pan, tilt and zoom controls, and the presets saved on the Pan &amp; zoom tab."; fi
    hint "Add this to your Frigate configuration. It follows this camera's settings, so copy it again after changing them. A click selects all of it."
    hint "$about"
    if [ "$STREAM_AUTH" != 0 ]; then
        hint "The stream addresses carry the admin account, for stream sign-in. Type its password here to fill it in below: it stays in this browser and isn't sent to the camera. Characters such as @ : / ? # % are encoded, as go2rtc needs."
        printf '<div class="fields"><label>Admin password <input id="fill-password" type="password" autocomplete="off"></label></div>'
    fi
    printf '<pre class="copy" id="frigate-yaml">'
    {
        if [ "$STREAM_AUTH" != 0 ]; then url="rtsp://$(admin_user):PASSWORD@${ip:-camera-ip}"; else url="rtsp://${ip:-camera-ip}"; fi
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
    printf '</pre>'
    if [ "$STREAM_AUTH" != 0 ]; then
        # The page's only script: fills the typed password into the addresses, URL-encoded, in the browser.
        printf '<script>(function () { var pre = document.getElementById("frigate-yaml"), box = document.getElementById("fill-password"), text = pre.textContent; box.addEventListener("input", function () { pre.textContent = text.split(":PASSWORD@").join(":" + (box.value ? encodeURIComponent(box.value) : "PASSWORD") + "@"); }); })();</script>'
    fi
    section_end
}

maintenance_section() {
    section_start maintenance "Maintenance"
    printf '<div class="actions">'
    form_start restart-streams; printf '<button class="secondary">Restart streams</button></form>'
    form_start reboot
    if [ "$MODE" = ap ]; then printf '<button class="secondary">Leave setup mode</button></form>'
    else printf '<button class="secondary">Restart camera</button></form>'; fi
    printf '</div>'
    form_start reset danger
    printf '<label class="check"><input type="checkbox" name="confirm" value="yes"> Forget the Wi-Fi network, settings and admin account</label>'
    printf '<div class="actions"><button class="danger">Reset camera</button></div></form>'
    section_end
}

# ----- the settings: tabs -----

PAGES="overview video audio ptz detect frigate system"
page_label() {
    case "$1" in
        video) echo Video ;; audio) echo Audio ;; ptz) echo 'Pan &amp; zoom' ;; detect) echo Detection ;;
        frigate) echo Frigate ;; system) echo System ;; *) echo Overview ;;
    esac
}

top_bar() { # the camera's name and state, and the tabs
    if [ -e "$RUN_DIR/streaming" ]; then state='<span class="pill ok">Streaming</span>'
    else state='<span class="pill warn">Starting or recovering</span>'; fi
    printf '<header class="top"><div class="bar"><div class="brand"><span class="name">%s</span>%s</div>' "$(h "$NAME")" "$state"
    if [ "$MODE" = ap ]; then printf '<div class="who">Setup mode</div>'
    else printf '<div class="who">Signed in as %s</div>' "$(h "$REMOTE_USER")"; fi
    printf '</div><nav class="tabs" aria-label="Settings">'
    for tab in $PAGES; do
        if [ "$tab" = "$PAGE" ]; then cur=' aria-current="page"'; else cur=''; fi
        printf '<a href="%s?p=%s"%s>%s</a>' "$SELF" "$tab" "$cur" "$(page_label "$tab")"
    done
    printf '</nav></header>'
}

settings_page() {
    PAGE=$(qparam p)
    case "$PAGE" in video|audio|ptz|detect|frigate|system) ;; *) PAGE=overview ;; esac
    MSG_S=$(qparam s)
    TOKEN=$(token)
    ip=""
    case "$PAGE" in overview|frigate|system) if wifi_connected; then ip=$(wlan_ip); fi ;; esac
    case "$PAGE" in
        overview) page_start "$NAME" ;;
        ptz) page_start "$NAME - Pan and zoom" ;;
        *) page_start "$NAME - $(page_label "$PAGE")" ;;
    esac
    top_bar
    printf '<main>'
    if [ "$MODE" = ap ]; then
        printf '<div class="banner"><p>Setup mode: you are connected to the camera'"'"'s own Wi-Fi. When you are done, leave setup mode: the camera restarts on your network.</p>'
        SECTION=""; form_start reboot; printf '<button>Leave setup mode</button></form></div>'
    fi
    if [ -z "$MSG_S" ]; then show_message; fi
    case "$PAGE" in
        overview) overview_page ;;
        video) streams_section; stream_auth_section; picture_section; overlay_section; hdmi_section ;;
        audio) mic_section; talk_section ;;
        ptz) ptz_section ;;
        detect) detect_section; mqtt_section ;;
        frigate) frigate_section ;;
        system) system_section; wifi_section; device_section; maintenance_section ;;
    esac
    page_end
}

wifi_page() {
    st=$(cat "$RUN_DIR/wifi-try" 2>/dev/null)
    ssid=$(cat "$RUN_DIR/wifi-try-ssid" 2>/dev/null)
    again="$SELF?p=system#wifi"
    case "$st" in
        connecting)
            notice_start "Connecting" 3
            printf '<h1>Joining %s</h1><p>This takes up to a minute.</p>' "$(h "$ssid")" ;;
        ok\ *)
            ip=${st#ok }
            notice_start "Connected"
            printf '<h1>Connected</h1><p>The camera joined <b>%s</b> at <b>%s</b>.</p>' "$(h "$ssid")" "$(h "$ip")"
            if [ "$MODE" = ap ]; then
                printf '<p>It restarts in about 20 seconds to finish setup. Then switch this phone or computer back to your usual Wi-Fi and open <a href="http://%s/">http://%s/</a> (sign in with the admin account).</p>' "$ip" "$ip"
            else
                printf '<p>Open <a href="http://%s/">http://%s/</a>.</p>' "$ip" "$ip"
            fi
            printf '<p>Streams: <code>rtsp://%s:8900/live</code> and <code>rtsp://%s:8901/live</code>%s</p>' "$ip" "$ip" \
                "$([ "$STREAM_AUTH" != 0 ] && echo ', signed in with the admin account')" ;;
        failed\ wrong-password)
            notice_start "Couldn't connect"
            printf '<h1>Couldn'"'"'t join %s</h1><p>The Wi-Fi password was rejected.</p><p><a href="%s">Try again</a></p>' "$(h "$ssid")" "$again" ;;
        failed\ no-address)
            notice_start "Couldn't connect"
            printf '<h1>Couldn'"'"'t join %s</h1><p>The camera joined it but didn'"'"'t get an address from the router.</p><p><a href="%s">Try again</a></p>' "$(h "$ssid")" "$again" ;;
        failed*)
            notice_start "Couldn't connect"
            printf '<h1>Couldn'"'"'t find %s</h1><p>Check the network name and that the camera is in range.</p><p><a href="%s">Try again</a></p>' "$(h "$ssid")" "$again" ;;
        *)
            redirect "$SELF" ;;
    esac
    notice_end
}

entry_page() {
    notice_start "Finish setup"
    printf '<h1>Finish setting up this camera</h1><p>It has no admin account yet. Hold its power button for 5 seconds until the lights blink, join its Wi-Fi network <b>%s</b> (password on the sticker under the camera), then open <a href="%s">%s</a>.</p>' "$(h "$(ap_ssid)")" "$AP_URL" "$AP_URL"
    notice_end
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
        read_password "New password for $2"
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
        # Its password isn't known here: the streams stay locked until it is entered (ui.sh stream-key).
        rm -f "$STREAM_KEY_FILE"
        reload_web
        echo "admin account: $2" ;;
    stream-key)
        user=$(admin_user)
        [ -n "$user" ] || { echo "there is no admin account" >&2; exit 1; }
        read_password "Password for $user"
        account_lock; stream_key "$user" "$pass"; rc=$?; account_unlock
        case $rc in
            0) echo "stream sign-in: the streams accept $user's password" ;;
            2) echo "that isn't $user's password" >&2; exit 1 ;;
            *) echo "couldn't write the streams' key" >&2; exit 1 ;;
        esac ;;
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
        echo "admin=$(admin_user)"
        echo "stream_auth=$(stream_auth)" ;;
    *) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
