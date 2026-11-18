#!/bin/sh
# Vision AI DevKit RTSP add-on: network settings, applied before the RTSP server starts.
. /opt/vaidk/common.sh
load_settings

# Larger socket send buffers absorb keyframe bursts to clients on slow Wi-Fi.
echo 4194304 > /proc/sys/net/core/wmem_max
echo 1048576 > /proc/sys/net/core/wmem_default
echo "4096 1048576 4194304" > /proc/sys/net/ipv4/tcp_wmem

# The vendor's unauthenticated control APIs (media server :4000, preview server :1080) stay
# reachable from the camera itself only. The media server also listens on IPv6 (:::4000), so both
# address families get the rule; if IPv6 can't be filtered, it is turned off on Wi-Fi instead.
if [ "$LOCK_CONTROL_API" = 1 ]; then
    for port in 4000 1080; do
        for table in iptables ip6tables; do
            $table -C INPUT ! -i lo -p tcp --dport "$port" -j REJECT 2>/dev/null \
                || $table -I INPUT ! -i lo -p tcp --dport "$port" -j REJECT
        done
    done
    for port in 4000 1080; do
        iptables -C INPUT ! -i lo -p tcp --dport "$port" -j REJECT 2>/dev/null \
            || echo "WARNING: port $port is not blocked from the network (iptables)"
        if ! ip6tables -C INPUT ! -i lo -p tcp --dport "$port" -j REJECT 2>/dev/null; then
            echo "WARNING: port $port is not blocked over IPv6 (ip6tables); turning IPv6 off on Wi-Fi"
            for conf in wlan0 softap0 default; do
                if [ -e "/proc/sys/net/ipv6/conf/$conf/disable_ipv6" ]; then echo 1 > "/proc/sys/net/ipv6/conf/$conf/disable_ipv6"; fi
            done
        fi
    done
fi
# The setup page trusts clients of the setup access point: drop that subnet arriving over Wi-Fi.
iptables -C INPUT -i wlan0 -s 192.168.143.0/24 -j DROP 2>/dev/null \
    || iptables -I INPUT -i wlan0 -s 192.168.143.0/24 -j DROP
exit 0
