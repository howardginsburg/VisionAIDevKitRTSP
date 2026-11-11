#!/bin/sh
# Vision AI DevKit RTSP add-on: network settings, applied before the RTSP server starts.
. /opt/vaidk/common.sh
load_settings

# Larger socket send buffers absorb keyframe bursts to clients on slow Wi-Fi.
echo 4194304 > /proc/sys/net/core/wmem_max
echo 1048576 > /proc/sys/net/core/wmem_default
echo "4096 1048576 4194304" > /proc/sys/net/ipv4/tcp_wmem

# The vendor's unauthenticated control APIs (media server :4000, preview server :1080) stay
# reachable from the camera itself only.
if [ "$LOCK_CONTROL_API" = 1 ]; then
    for port in 4000 1080; do
        iptables -C INPUT ! -i lo -p tcp --dport "$port" -j REJECT 2>/dev/null \
            || iptables -I INPUT ! -i lo -p tcp --dport "$port" -j REJECT
    done
fi
# The setup page trusts clients of the setup access point: drop that subnet arriving over Wi-Fi.
iptables -C INPUT -i wlan0 -s 192.168.143.0/24 -j DROP 2>/dev/null \
    || iptables -I INPUT -i wlan0 -s 192.168.143.0/24 -j DROP
exit 0
