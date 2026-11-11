#!/bin/sh
# Wi-Fi for the Vision AI DevKit RTSP add-on.
#   wifi.sh boot             join the saved network (called by InitCamx.vaidk at boot)
#   wifi.sh watch            watchdog (vaidk-wifi.service): renews DHCP when needed, opens the
#                            setup access point when the saved network is unavailable, and leaves
#                            setup mode once Wi-Fi works and nobody is using the access point
#   wifi.sh scan             nearby networks as "signal<TAB>ssid", strongest first
#   wifi.sh try FILE [yes]   join the network in FILE and save it on success, otherwise return
#                            to the saved network; "yes" restarts the camera after success
. /opt/vaidk/common.sh
load_settings

WPA_CTRL=/var/run/wpa_supplicant

log() { printf '%s\n' "$*"; }
wpa() { wpa_cli -p "$WPA_CTRL" -i wlan0 "$@" 2>/dev/null; }
wpa_state() { wpa status | sed -n 's/^wpa_state=//p'; }

start_wpa() { # start_wpa CONF
    killall wpa_supplicant 2>/dev/null
    i=0
    while pidof wpa_supplicant >/dev/null && [ $i -lt 30 ]; do usleep 100000; i=$((i + 1)); done
    rm -rf "$WPA_CTRL/wlan0"
    ifconfig wlan0 up 2>/dev/null
    wpa_supplicant -B -iwlan0 -c "$1" >/dev/null 2>&1
}

start_scanner() { # a Wi-Fi client without networks, used for scanning in setup mode
    mkdir -p "$RUN_DIR"
    printf 'ctrl_interface=%s\nap_scan=1\ncountry=%s\n' "$WPA_CTRL" "$WIFI_COUNTRY" > "$RUN_DIR/scan.conf"
    start_wpa "$RUN_DIR/scan.conf"
}

start_dhcp() { # forget the old address first so a stale lease never looks like a connection
    killall udhcpc 2>/dev/null
    ip -4 addr flush dev wlan0 2>/dev/null
    setsid /sbin/udhcpc -i wlan0 -A 1 -s /etc/udhcpc.conf -x "hostname:$NAME" </dev/null >/dev/null 2>&1 &
}

connected() { [ "$(wpa_state)" = COMPLETED ] && [ -n "$(wlan_ip)" ]; }
wpa_uses() { # wpa_uses CONF: a running wpa_supplicant was started with CONF
    for pid in $(pidof wpa_supplicant); do
        if grep -q -a "$1" "/proc/$pid/cmdline" 2>/dev/null; then return 0; fi
    done
    return 1
}

ap_running() { pidof hostapd >/dev/null && ip link show softap0 2>/dev/null | grep -q '[<,]UP[,>]'; }
ap_clients() { # the driver lists the camera's own Wi-Fi interface as a station; don't count it
    own=$(cat /sys/class/net/wlan0/address 2>/dev/null)
    iw dev softap0 station dump 2>/dev/null | awk -v own="$own" '$1 == "Station" && tolower($2) != tolower(own) { n++ } END { print n + 0 }'
}

start_ap() { # the same setup access point the camera opens out of the box
    pass=$(cat /persist/data/wifi.bin 2>/dev/null)
    [ "${#pass}" -ge 8 ] || pass=12345678
    /usr/bin/startvirtualsoftap -1 0 "$pass" US >/dev/null 2>&1
}

stop_ap() {
    killall hostapd 2>/dev/null
    if [ -f /var/run/virtualsoftap0_dnsmasq.pid ]; then kill "$(cat /var/run/virtualsoftap0_dnsmasq.pid)" 2>/dev/null; fi
    ifconfig softap0 down 2>/dev/null
}

boot() {
    i=0
    while [ $i -lt 30 ] && ! ifconfig wlan0 >/dev/null 2>&1; do sleep 1; i=$((i + 1)); done
    killall connectap hostapd udhcpc 2>/dev/null
    ifconfig softap0 down 2>/dev/null
    start_wpa "$WIFI_CONF"
    start_dhcp
    killall wifimonitor 2>/dev/null
    setsid wifimonitor </dev/null >/dev/null 2>&1 &
    i=0
    while [ $i -lt 60 ]; do
        if connected; then log "connected at $(wlan_ip)"; return 0; fi
        sleep 1; i=$((i + 1))
    done
    log "not connected yet; still trying"
    return 1
}

watch() {
    mkdir -p "$RUN_DIR"
    i=0
    while [ ! -e "$RUN_DIR/boot-wifi-done" ] && [ $i -lt 300 ]; do sleep 2; i=$((i + 2)); done
    down_since=""; no_ip=0; ap_since=""; idle_since=""
    while :; do
        sleep 10
        if [ -d "$RUN_DIR/wifi.lock" ]; then continue; fi
        now=$(uptime_s)
        online=0
        if connected; then online=1; fi
        if [ -s "$WIFI_CONF" ]; then
            # a joined network keeps running from candidate.conf (identical to the saved one)
            if ! wpa_uses "$WIFI_CONF" && ! wpa_uses "$RUN_DIR/candidate.conf"; then
                log "Wi-Fi client not running with the saved network; restarting it"
                start_wpa "$WIFI_CONF"
                start_dhcp
            elif [ $online = 0 ] && [ "$(wpa_state)" = COMPLETED ]; then
                no_ip=$((no_ip + 1))
                if [ $no_ip -ge 3 ]; then log "connected without an address; renewing DHCP"; start_dhcp; no_ip=0; fi
            else
                no_ip=0
            fi
            if [ $online = 1 ]; then down_since=""; else down_since=${down_since:-$now}; fi
            if [ -n "$down_since" ] && [ $((now - down_since)) -ge "$FALLBACK_AFTER" ] && ! ap_running; then
                log "saved Wi-Fi network unavailable for $((now - down_since))s; opening the setup access point"
                start_ap
                touch "$RUN_DIR/fallback-ap"
            fi
        fi
        if ap_running; then
            ap_since=${ap_since:-$now}
            if [ "$(ap_clients)" -gt 0 ]; then idle_since=""; else idle_since=${idle_since:-$now}; fi
            if [ -s "$WIFI_CONF" ] && [ $online = 1 ] && [ -n "$idle_since" ] \
                && [ $((now - ap_since)) -ge "$AP_MIN_UP" ] && [ $((now - idle_since)) -ge "$AP_IDLE_EXIT" ]; then
                if [ -e "$RUN_DIR/fallback-ap" ]; then
                    log "Wi-Fi is back and nobody is using the setup access point; closing it"
                    stop_ap
                    rm -f "$RUN_DIR/fallback-ap"
                else
                    log "Wi-Fi works and nobody is using setup mode; restarting to leave it"
                    reboot
                fi
            fi
        else
            ap_since=""; idle_since=""
            rm -f "$RUN_DIR/fallback-ap"
        fi
    done
}

scan() {
    if ! pidof wpa_supplicant >/dev/null; then start_scanner; fi
    i=0; while [ $i -lt 20 ] && [ "$(wpa ping)" != PONG ]; do usleep 250000; i=$((i + 1)); done
    i=0; while [ $i -lt 5 ] && [ "$(wpa scan)" != OK ]; do sleep 1; i=$((i + 1)); done
    i=0; results=""
    while [ $i -lt 10 ]; do # results arrive band by band; give a full scan a few seconds
        sleep 1; i=$((i + 1))
        results=$(wpa scan_results | awk -F'\t' 'NR > 1 && $5 != "" { print $3 "\t" $5 }')
        if [ -n "$results" ] && [ $i -ge 4 ]; then break; fi
    done
    printf '%s\n' "$results" | sort -rn | awk -F'\t' '$2 != "" && !seen[$2]++'
}

try() { # try CANDIDATE_CONF [yes]
    mkdir -p "$RUN_DIR"
    mkdir "$RUN_DIR/wifi.lock" 2>/dev/null || return 1
    status=$RUN_DIR/wifi-try
    echo connecting > "$status"
    start_wpa "$1"
    start_dhcp
    seen_auth=0; last=""; i=0
    while [ $i -lt 45 ]; do
        last=$(wpa_state)
        case "$last" in 4WAY_HANDSHAKE|GROUP_HANDSHAKE) seen_auth=1 ;; esac
        if connected; then
            mkdir -p "$DATA_DIR" && chmod 700 "$DATA_DIR"
            cp "$1" "$WIFI_CONF.new" && chmod 600 "$WIFI_CONF.new" && mv "$WIFI_CONF.new" "$WIFI_CONF"
            echo "ok $(wlan_ip)" > "$status"
            log "joined the new Wi-Fi network at $(wlan_ip)"
            rmdir "$RUN_DIR/wifi.lock"
            if [ "$2" = yes ]; then sleep 20; reboot; fi
            return 0
        fi
        sleep 1; i=$((i + 1))
    done
    if [ "$last" = COMPLETED ]; then echo "failed no-address" > "$status"
    elif [ $seen_auth = 1 ]; then echo "failed wrong-password" > "$status"
    else echo "failed not-found" > "$status"; fi
    log "could not join the new Wi-Fi network ($(cat "$status"))"
    rm -f "$1"
    if [ -s "$WIFI_CONF" ]; then start_wpa "$WIFI_CONF"; start_dhcp; else start_scanner; fi
    rmdir "$RUN_DIR/wifi.lock"
    return 1
}

case "$1" in
    boot) boot ;;
    watch) watch ;;
    scan) scan ;;
    try) try "$2" "$3" ;;
    *) echo "usage: $0 boot|watch|scan|try FILE [yes]" >&2; exit 2 ;;
esac
