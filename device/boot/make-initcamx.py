#!/usr/bin/python3
"""Builds the add-on's boot script from the camera's own vendor InitCamx.

usage: make-initcamx.py [--force] VENDOR_INITCAMX OUTPUT   build OUTPUT (run by install-device.sh)
       make-initcamx.py --check VENDOR_INITCAMX            exit 0 if it is the tested vendor file

The vendor script (/vendor/etc/camera/InitCamx) carries no licence, so the add-on doesn't ship a
copy of it: each camera builds InitCamx.vaidk from its own file. Both the input and the result are
checked against the hashes tested on firmware v0.5370_Perf; --force skips those checks for other
firmware, but every edit point must still be found exactly once.
"""
import hashlib
import os
import sys

KNOWN_IN = "58afd1afc0ba05bd75a3b957a0cd0a9a"
KNOWN_OUT = "76ec70dd6c678160a6a6ad11246e249f"

HEADER = """#!/bin/bash
# Vision AI DevKit RTSP add-on: the camera's boot script, built by /opt/vaidk/boot/make-initcamx.py
# from the vendor /vendor/etc/camera/InitCamx (left untouched) and run instead of it by
# /lib/systemd/system/InitCamx.service.d/vaidk.conf. Changes:
#  - Wi-Fi: with a saved network (/data/misc/vaidk/wpa_supplicant.conf) join it directly;
#    otherwise open the vendor setup access point, unchanged. The vendor station path (setting.conf
#    + connectap) is gone: setting.conf only appears after the retired IoT Hub step, and connectap
#    writes a Wi-Fi configuration wpa_supplicant cannot parse.
#  - A vendor factory reset (which deletes /data/misc/etc) also clears the add-on's saved settings.
#  - The vendor setup site (websettings) is not started: vaidk-web.service serves port 80 instead.
#  - 'stop' does nothing (the vendor script re-ran its whole boot sequence at shutdown).
#  - altekflow gets /opt/vaidk/lights first on PATH so the status lights show the stream state.
[ "$1" = "stop" ] && exit 0
"""

WIFI_START = 'timestampLog "WiFi setup"'
WIFI_END = 'if [ ! -e "/etc/rpm/rpm_extract" ] ; then'
AP_START = 'if [ ! -e "/persist/data/wifi.bin" ] ; then'
AP_END_AFTER = "setprop persist.comm.lock 0"
WEBSETTINGS = 'timestampLog "Active OOBE server"\nwebsettings&\n'
ALTEKFLOW = "\naltekflow &\n"

WIFI_BLOCK = '''timestampLog "WiFi setup"
declare -i needreboot=0
mkdir -p /run/vaidk
if [ ! -d /data/misc/etc/upper ] && [ -d /data/misc/vaidk ] ; then
	timestampLog "vaidk: factory reset detected; clearing saved Wi-Fi and settings"
	rm -rf /data/misc/vaidk
fi
setprop persist.wifi.station.status 0
if [ -s /data/misc/vaidk/wpa_supplicant.conf ] ; then
	if /bin/sh /opt/vaidk/wifi/wifi.sh boot ; then
		timestampLog "vaidk: Wi-Fi connected"
	else
		timestampLog "vaidk: Wi-Fi not connected yet; still trying"
	fi
	setprop persist.wifi.property.mode 1
	echo "vaidk wifi station" > /data/misc/wifi/wifi_boot
else
	timestampLog "vaidk: no saved Wi-Fi network; starting the setup access point"
	sleep 8
	'''


class EditError(Exception):
    pass


def find_once(text, anchor, start=0):
    if text.count(anchor) != 1:
        raise EditError("expected exactly one %r in the vendor script" % anchor)
    pos = text.find(anchor, start)
    if pos < 0:
        raise EditError("%r is not where expected in the vendor script" % anchor)
    return pos


def build(vendor):
    if not vendor.startswith("#!/bin/bash\n"):
        raise EditError("the vendor script doesn't start with #!/bin/bash")
    wifi_start = find_once(vendor, WIFI_START)
    wifi_end = find_once(vendor, WIFI_END)
    # The vendor's own setup access point block is kept as it is, for cameras with no saved network.
    ap_start = vendor.find(AP_START, wifi_start)
    lock = vendor.find(AP_END_AFTER, wifi_start)
    ap_end = vendor.find("else", lock) if lock >= 0 else -1
    if not wifi_start < ap_start < lock < ap_end < wifi_end:
        raise EditError("the vendor Wi-Fi section has an unexpected layout")
    vendor_ap = vendor[ap_start:ap_end].rstrip() + "\n"
    suffix = vendor[wifi_end:]
    find_once(suffix, WEBSETTINGS)
    find_once(suffix, ALTEKFLOW)
    suffix = suffix.replace(WEBSETTINGS, 'timestampLog "vaidk: setup page served by vaidk-web.service"\n')
    suffix = suffix.replace(ALTEKFLOW, "\nPATH=/opt/vaidk/lights:$PATH altekflow &\n")
    body = vendor[len("#!/bin/bash\n"):wifi_start]
    return HEADER + body + WIFI_BLOCK + vendor_ap + "fi\ntouch /run/vaidk/boot-wifi-done\n\t\n" + suffix


def md5(data):
    return hashlib.md5(data).hexdigest()


def main(argv):
    force = "--force" in argv
    args = [a for a in argv if a != "--force"]
    if len(args) == 2 and args[0] == "--check":
        with open(args[1], "rb") as f:
            ok = md5(f.read()) == KNOWN_IN
        print("%s is %sthe tested vendor boot script" % (args[1], "" if ok else "not "))
        return 0 if ok else 1
    if len(args) != 2:
        sys.stderr.write(__doc__)
        return 2
    with open(args[0], "rb") as f:
        raw = f.read()
    if md5(raw) != KNOWN_IN and not force:
        sys.stderr.write("%s isn't the tested vendor boot script (MD5 %s)\n" % (args[0], md5(raw)))
        return 1
    try:
        result = build(raw.decode("latin-1")).encode("latin-1")
    except EditError as e:
        sys.stderr.write("can't build the boot script: %s\n" % e)
        return 1
    if md5(result) != KNOWN_OUT and not force:
        sys.stderr.write("the built boot script doesn't match the tested one (MD5 %s)\n" % md5(result))
        return 1
    tmp = args[1] + ".tmp"
    with open(tmp, "wb") as f:
        f.write(result)
    os.chmod(tmp, 0o755)
    os.rename(tmp, args[1])
    print("built %s (%d bytes)" % (args[1], len(result)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
