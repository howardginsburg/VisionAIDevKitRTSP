#!/usr/bin/python3
# Vision AI DevKit RTSP add-on: ONVIF service (device, media and PTZ), so Frigate, Home Assistant and
# NVRs can find the camera's streams and pan, tilt and zoom it. The pan, tilt and zoom are digital: a
# crop of the sensor that both streams are scaled from. This service keeps the position, writes it to
# /run/vaidk/ptz.conf and signals vaidk-camd (SIGUSR2), which applies it to the camera. No password,
# like the RTSP streams; WS-Security headers are ignored.
#
# The camera's Python has only part of the standard library (no socket, threading, signal, json or xml
# modules), so this uses _socket and select directly and reads SOAP requests with regular expressions.
#
# Requests from the setup page (127.0.0.1 only):
#   GET /local/ptz                       position and presets as text
#   GET /local/ptz?do=full               show the whole picture
#   GET /local/ptz?do=home               go to the home position
#   GET /local/ptz?do=goto&token=T       go to a preset
#   GET /local/ptz?do=save&name=N        save the current view as a preset
#   GET /local/ptz?do=delete&token=T     delete a preset
import _socket
import binascii
import errno
import os
import re
import select
import sys
import time

PORT = int(os.environ.get("ONVIF_PORT") or 8080)
SETTINGS = ("/opt/vaidk/defaults.conf", "/data/misc/vaidk/vaidk.conf")
STATE = "/data/misc/vaidk/ptz"   # position, home and presets, kept across restarts
LIVE = "/run/vaidk/ptz.conf"      # what vaidk-camd applies
SIGUSR2 = 12
MAX_ZOOM = 4.0                    # 2x keeps full detail on a 1080p stream; beyond 4x is too soft
ZOOM_RATE = 0.5                   # zoom position per second at full speed: 1x to 4x in 2 s
PAN_RATE = 1.0                    # pictures per second at full speed (a picture = the current view)
DEFAULT_TIMEOUT = 30              # seconds a continuous move runs without Stop (the PTZ timeout)
TICK = 0.1                        # seconds between position updates while moving
MAX_PRESETS = 16
MAX_REQUEST = 65536
SENSOR = (3840, 2160)

NS = {
    "env": "http://www.w3.org/2003/05/soap-envelope",
    "tt": "http://www.onvif.org/ver10/schema",
    "tds": "http://www.onvif.org/ver10/device/wsdl",
    "trt": "http://www.onvif.org/ver10/media/wsdl",
    "tptz": "http://www.onvif.org/ver20/ptz/wsdl",
    "ter": "http://www.onvif.org/ver10/error",
}
SPACE = "http://www.onvif.org/ver10/tptz/"
PT_POS, Z_POS = SPACE + "PanTiltSpaces/PositionGenericSpace", SPACE + "ZoomSpaces/PositionGenericSpace"
PT_TRANS, PT_FOV = SPACE + "PanTiltSpaces/TranslationGenericSpace", SPACE + "PanTiltSpaces/TranslationSpaceFov"
Z_TRANS = SPACE + "ZoomSpaces/TranslationGenericSpace"
PT_VEL, Z_VEL = SPACE + "PanTiltSpaces/VelocityGenericSpace", SPACE + "ZoomSpaces/VelocityGenericSpace"
PT_SPEED, Z_SPEED = SPACE + "PanTiltSpaces/GenericSpeedSpace", SPACE + "ZoomSpaces/ZoomGenericSpeedSpace"


def log(text):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def esc(text):
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def read_file(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default


# ----- settings (re-read when the setup page saves them) -----

_settings, _stamp = {}, None


def settings():
    global _settings, _stamp
    stamp = tuple(os.stat(p).st_mtime if os.path.exists(p) else 0 for p in SETTINGS)
    if stamp != _stamp:
        values = {}
        for path in SETTINGS:
            for line in read_file(path).splitlines():
                m = re.match(r"\s*([A-Z_][A-Z0-9_]*)=(.*)$", line)
                if m:
                    values[m.group(1)] = m.group(2).strip().strip("'\"")
        _settings, _stamp = values, stamp
    return _settings


def setting(key, default=""):
    return settings().get(key) or default


def number(key, default):
    try:
        return int(setting(key, str(default)))
    except ValueError:
        return default


# ----- pan, tilt and zoom -----

class Ptz:
    """Pan and tilt run from -1 to 1 across the room the zoom leaves (tilt 1 = top); zoom runs from 0
    (the whole picture) to 1 (MAX_ZOOM) in even powers, so each step looks the same."""

    def __init__(self):
        self.pan = self.tilt = self.zoom = 0.0
        self.home = (0.0, 0.0, 0.0)
        self.presets = []  # [token, name, pan, tilt, zoom]
        self.velocity = (0.0, 0.0, 0.0)
        self.until = self.last = time.monotonic()
        self.written = None
        self.camd = None
        self.load()

    def moving(self):
        return any(self.velocity)

    def factor(self):
        return MAX_ZOOM ** self.zoom

    def set(self, pan=None, tilt=None, zoom=None):
        if zoom is not None:
            self.zoom = clamp(zoom, 0.0, 1.0)
        if pan is not None:
            self.pan = clamp(pan, -1.0, 1.0)
        if tilt is not None:
            self.tilt = clamp(tilt, -1.0, 1.0)
        self.apply()

    def shift(self, across, up):
        """Moves the view by a number of pictures (current views) across and up."""
        room = self.factor() - 1.0  # how many pictures fit in the room the zoom leaves
        if room > 1e-3:
            self.set(pan=self.pan + 2.0 * across / room, tilt=self.tilt + 2.0 * up / room)

    def start(self, vx, vy, vz, timeout):
        if self.moving():
            self.advance()
        self.velocity = (vx, vy, vz)
        self.last = time.monotonic()
        self.until = self.last + (timeout or DEFAULT_TIMEOUT)
        if not self.moving():
            self.save()

    def stop(self):
        if self.moving():
            self.advance()
        self.velocity = (0.0, 0.0, 0.0)
        self.save()

    def goto(self, pan, tilt, zoom):
        self.velocity = (0.0, 0.0, 0.0)
        self.set(pan, tilt, zoom)
        self.save()

    def advance(self):
        """Moves by the time since the last update, up to the move's timeout."""
        now = time.monotonic()
        dt, self.last = clamp(min(now, self.until) - self.last, 0.0, 0.5), now
        vx, vy, vz = self.velocity
        if vz:
            self.set(zoom=self.zoom + vz * ZOOM_RATE * dt)
        if vx or vy:
            self.shift(vx * PAN_RATE * dt, vy * PAN_RATE * dt)
        return now

    def tick(self):
        if self.moving() and self.advance() >= self.until:
            self.stop()

    # Applying and keeping

    def apply(self):
        text = "ZOOM=%.4f\nZOOM_X=%.2f\nZOOM_Y=%.2f\n" % (self.factor(), (self.pan + 1) * 50, (1 - self.tilt) * 50)
        if text == self.written:
            return
        try:
            with open(LIVE + ".tmp", "w") as f:
                f.write(text)
            os.rename(LIVE + ".tmp", LIVE)
        except OSError as e:
            log("could not write %s: %s" % (LIVE, e))
            return
        self.written = text
        # Checks the name each time: after vaidk-camd restarts, its old process number can be reused.
        if self.camd is None or read_file("/proc/%d/comm" % self.camd).strip() != "vaidk-camd":
            self.camd = find_process("vaidk-camd")
        if self.camd is not None:
            try:
                os.kill(self.camd, SIGUSR2)
            except OSError:
                self.camd = None

    def load(self):
        for line in read_file(STATE).splitlines():
            parts = line.split(" ", 5)
            try:
                if parts[0] == "position" and len(parts) >= 4:
                    self.pan, self.tilt, self.zoom = (float(v) for v in parts[1:4])
                elif parts[0] == "home" and len(parts) >= 4:
                    self.home = tuple(float(v) for v in parts[1:4])
                elif parts[0] == "preset" and len(parts) == 6:
                    self.presets.append([parts[1], parts[5], float(parts[2]), float(parts[3]), float(parts[4])])
            except ValueError:
                continue
        self.apply()

    def save(self):
        lines = ["position %.4f %.4f %.4f" % (self.pan, self.tilt, self.zoom), "home %.4f %.4f %.4f" % self.home]
        lines += ["preset %s %.4f %.4f %.4f %s" % (t, p, ti, z, n) for t, n, p, ti, z in self.presets]
        try:
            os.makedirs(os.path.dirname(STATE), 0o700, True)  # gone after a reset until the next save
            with open(STATE + ".tmp", "w") as f:
                f.write("\n".join(lines) + "\n")
            os.rename(STATE + ".tmp", STATE)
        except OSError as e:
            log("could not save %s: %s" % (STATE, e))

    # Presets

    def preset(self, token):
        return next((p for p in self.presets if p[0] == token), None)

    def save_preset(self, name, token=None):
        """Saves the current view; a name or token already in use updates that preset."""
        name = re.sub(r"[\x00-\x1f\x7f]", "", name or "").strip()[:64]
        p = self.preset(token) if token else None
        if p is None and name:
            p = next((q for q in self.presets if q[1].lower() == name.lower()), None)
        if p is None:
            if len(self.presets) >= MAX_PRESETS:
                return None
            used = set(q[0] for q in self.presets)
            token = next(str(i) for i in range(1, MAX_PRESETS + 2) if str(i) not in used)
            p = [token, name or "Preset " + token, 0, 0, 0]
            self.presets.append(p)
        elif name:
            p[1] = name
        p[2:5] = [self.pan, self.tilt, self.zoom]
        self.save()
        return p[0]

    def remove_preset(self, token):
        p = self.preset(token)
        if p is not None:
            self.presets.remove(p)
            self.save()
        return p is not None


def find_process(name):
    for pid in os.listdir("/proc"):
        if pid.isdigit() and read_file("/proc/%s/comm" % pid).strip() == name:
            return int(pid)
    return None


# ----- reading requests -----

class SoapFault(Exception):
    def __init__(self, subcode, reason, code="Sender"):
        Exception.__init__(self, reason)
        self.code, self.subcode, self.reason = code, subcode, reason


def element(xml, name):
    """The content of the first element called `name` (any prefix), or None."""
    m = re.search(r"<(?:[\w.-]+:)?%s\b[^>]*?(?:/>|>(.*?)</(?:[\w.-]+:)?%s\s*>)" % (name, name), xml, re.S)
    return None if m is None else (m.group(1) or "")


def text(xml, name, default=None):
    value = element(xml, name)
    return default if value is None else re.sub(r"<[^>]*>", "", value).strip()


def attrs(xml, name):
    """The attributes of the first element called `name`, or None."""
    m = re.search(r"<(?:[\w.-]+:)?%s\b([^>]*?)/?>" % name, xml, re.S)
    return None if m is None else dict(re.findall(r'([\w.:-]+)\s*=\s*"([^"]*)"', m.group(1)))


def vector(xml, container):
    """(x, y, zoom, pan_tilt_space) from the PanTilt and Zoom inside `container`; None if it's missing."""
    inner = element(xml, container)
    if inner is None:
        return None
    pt, z = attrs(inner, "PanTilt") or {}, attrs(inner, "Zoom") or {}

    def num(d, key):
        try:
            return float(d[key])
        except (KeyError, ValueError):
            return None
    return num(pt, "x"), num(pt, "y"), num(z, "x"), pt.get("space", "")


def duration(value):
    """Seconds in an xs:duration such as PT5S or PT1M30.5S; 0 if missing or unreadable."""
    m = re.match(r"P(?:\d+D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?$", (value or "").strip())
    if not m:
        return 0.0
    h, mi, s = m.groups()
    return int(h or 0) * 3600 + int(mi or 0) * 60 + float(s or 0)


# ----- answers -----

def envelope(body):
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<env:Envelope %s><env:Body>%s</env:Body></env:Envelope>'
            % (" ".join('xmlns:%s="%s"' % kv for kv in sorted(NS.items())), body))


def fault(code, subcode, reason):
    return ('<env:Fault><env:Code><env:Value>env:%s</env:Value><env:Subcode><env:Value>ter:%s</env:Value>'
            '</env:Subcode></env:Code><env:Reason><env:Text xml:lang="en">%s</env:Text></env:Reason></env:Fault>'
            % (code, subcode, esc(reason)))


def space1(tag, uri, lo, hi):
    return ("<tt:%s><tt:URI>%s</tt:URI><tt:XRange><tt:Min>%g</tt:Min><tt:Max>%g</tt:Max></tt:XRange></tt:%s>"
            % (tag, uri, lo, hi, tag))


def space2(tag, uri, lo, hi):
    return ("<tt:%s><tt:URI>%s</tt:URI><tt:XRange><tt:Min>%g</tt:Min><tt:Max>%g</tt:Max></tt:XRange>"
            "<tt:YRange><tt:Min>%g</tt:Min><tt:Max>%g</tt:Max></tt:YRange></tt:%s>" % (tag, uri, lo, hi, lo, hi, tag))


SPACES = (space2("AbsolutePanTiltPositionSpace", PT_POS, -1, 1) + space1("AbsoluteZoomPositionSpace", Z_POS, 0, 1)
          + space2("RelativePanTiltTranslationSpace", PT_TRANS, -1, 1)
          + space2("RelativePanTiltTranslationSpace", PT_FOV, -1, 1)
          + space1("RelativeZoomTranslationSpace", Z_TRANS, -1, 1)
          + space2("ContinuousPanTiltVelocitySpace", PT_VEL, -1, 1) + space1("ContinuousZoomVelocitySpace", Z_VEL, -1, 1)
          + space1("PanTiltSpeedSpace", PT_SPEED, 0, 1) + space1("ZoomSpeedSpace", Z_SPEED, 0, 1))


def position_xml(tag, pan, tilt, zoom):
    return ('<tt:%s><tt:PanTilt x="%.4f" y="%.4f" space="%s"/><tt:Zoom x="%.4f" space="%s"/></tt:%s>'
            % (tag, pan, tilt, PT_POS, zoom, Z_POS, tag))


def ptz_configuration(tag):
    return ('<%s token="ptz"><tt:Name>Digital PTZ</tt:Name><tt:UseCount>2</tt:UseCount><tt:NodeToken>ptz</tt:NodeToken>'
            "<tt:DefaultAbsolutePantTiltPositionSpace>%s</tt:DefaultAbsolutePantTiltPositionSpace>"
            "<tt:DefaultAbsoluteZoomPositionSpace>%s</tt:DefaultAbsoluteZoomPositionSpace>"
            "<tt:DefaultRelativePanTiltTranslationSpace>%s</tt:DefaultRelativePanTiltTranslationSpace>"
            "<tt:DefaultRelativeZoomTranslationSpace>%s</tt:DefaultRelativeZoomTranslationSpace>"
            "<tt:DefaultContinuousPanTiltVelocitySpace>%s</tt:DefaultContinuousPanTiltVelocitySpace>"
            "<tt:DefaultContinuousZoomVelocitySpace>%s</tt:DefaultContinuousZoomVelocitySpace>"
            '<tt:DefaultPTZSpeed><tt:PanTilt x="1" y="1" space="%s"/><tt:Zoom x="1" space="%s"/></tt:DefaultPTZSpeed>'
            "<tt:DefaultPTZTimeout>PT%dS</tt:DefaultPTZTimeout>"
            "<tt:PanTiltLimits><tt:Range><tt:URI>%s</tt:URI><tt:XRange><tt:Min>-1</tt:Min><tt:Max>1</tt:Max></tt:XRange>"
            "<tt:YRange><tt:Min>-1</tt:Min><tt:Max>1</tt:Max></tt:YRange></tt:Range></tt:PanTiltLimits>"
            "<tt:ZoomLimits><tt:Range><tt:URI>%s</tt:URI><tt:XRange><tt:Min>0</tt:Min><tt:Max>1</tt:Max></tt:XRange>"
            "</tt:Range></tt:ZoomLimits></%s>"
            % (tag, PT_POS, Z_POS, PT_TRANS, Z_TRANS, PT_VEL, Z_VEL, PT_SPEED, Z_SPEED, DEFAULT_TIMEOUT, PT_POS, Z_POS,
               tag))


def streams():
    """(token, name, encoding, width, height, fps, kbps, port, keyframe seconds) for each stream that's on."""
    keyframe = max(1, number("KEYFRAME_SECONDS", 1))
    out = [("main", "Main stream", "H264" if setting("MAIN_CODEC", "1") == "1" else "H265",
            number("MAIN_WIDTH", 1920), number("MAIN_HEIGHT", 1080), number("MAIN_FPS", 30),
            number("MAIN_BITRATE", 4000000) // 1000, 8900, keyframe)]
    if setting("SUB_ENABLED", "1") == "1":
        out.append(("sub", "Sub stream", "H264", number("SUB_WIDTH", 640), number("SUB_HEIGHT", 360),
                    number("SUB_FPS", 5), number("SUB_BITRATE", 500000) // 1000, 8901, keyframe))
    return out


def stream(token):
    s = next((s for s in streams() if s[0] == token), None)
    if s is None:
        raise SoapFault("NoProfile", "No such profile: %s" % token)
    return s


def video_source_configuration(tag):
    return ('<%s token="video"><tt:Name>Camera</tt:Name><tt:UseCount>2</tt:UseCount><tt:SourceToken>video'
            '</tt:SourceToken><tt:Bounds x="0" y="0" width="%d" height="%d"/></%s>' % (tag, SENSOR[0], SENSOR[1], tag))


def video_encoder_configuration(tag, s):
    token, name, encoding, w, h, fps, kbps, _, keyframe = s
    h264 = ("<tt:H264><tt:GovLength>%d</tt:GovLength><tt:H264Profile>High</tt:H264Profile></tt:H264>"
            % (fps * keyframe) if encoding == "H264" else "")
    return ('<%s token="%s_video"><tt:Name>%s</tt:Name><tt:UseCount>1</tt:UseCount><tt:Encoding>%s</tt:Encoding>'
            "<tt:Resolution><tt:Width>%d</tt:Width><tt:Height>%d</tt:Height></tt:Resolution><tt:Quality>5</tt:Quality>"
            "<tt:RateControl><tt:FrameRateLimit>%d</tt:FrameRateLimit><tt:EncodingInterval>1</tt:EncodingInterval>"
            "<tt:BitrateLimit>%d</tt:BitrateLimit></tt:RateControl>%s"
            "<tt:Multicast><tt:Address><tt:Type>IPv4</tt:Type><tt:IPv4Address>0.0.0.0</tt:IPv4Address></tt:Address>"
            "<tt:Port>0</tt:Port><tt:TTL>0</tt:TTL><tt:AutoStart>false</tt:AutoStart></tt:Multicast>"
            "<tt:SessionTimeout>PT60S</tt:SessionTimeout></%s>"
            % (tag, token, name, encoding, w, h, fps, kbps, h264, tag))


def profile_xml(tag, s):
    return ('<%s token="%s" fixed="true"><tt:Name>%s</tt:Name>%s%s%s</%s>'
            % (tag, s[0], s[1], video_source_configuration("tt:VideoSourceConfiguration"),
               video_encoder_configuration("tt:VideoEncoderConfiguration", s), ptz_configuration("tt:PTZConfiguration"),
               tag))


def serial():
    m = re.search(r"androidboot\.serialno=(\S+)", read_file("/proc/cmdline"))
    return m.group(1) if m else read_file("/sys/class/net/wlan0/address").strip().replace(":", "")


# ----- operations: each returns the response's content, or None when it isn't the service's -----

def device_op(op, body, ctx, ptz):
    base = "http://%s:%d" % (ctx["host"], PORT)
    if op == "GetServices":
        return "".join('<tds:Service><tds:Namespace>%s</tds:Namespace><tds:XAddr>%s/onvif/%s</tds:XAddr><tds:Version>'
                       "<tt:Major>2</tt:Major><tt:Minor>60</tt:Minor></tds:Version></tds:Service>"
                       % (NS[prefix], base, path) for prefix, path in
                       (("tds", "device_service"), ("trt", "media_service"), ("tptz", "ptz_service")))
    if op == "GetCapabilities":
        category = text(body, "Category", "All") or "All"
        parts = []
        if category in ("All", "Device"):
            parts.append(
                "<tt:Device><tt:XAddr>%s/onvif/device_service</tt:XAddr><tt:Network><tt:IPFilter>false</tt:IPFilter>"
                "<tt:ZeroConfiguration>false</tt:ZeroConfiguration><tt:IPVersion6>false</tt:IPVersion6>"
                "<tt:DynDNS>false</tt:DynDNS></tt:Network><tt:System><tt:DiscoveryResolve>false</tt:DiscoveryResolve>"
                "<tt:DiscoveryBye>false</tt:DiscoveryBye><tt:RemoteDiscovery>false</tt:RemoteDiscovery>"
                "<tt:SystemBackup>false</tt:SystemBackup><tt:SystemLogging>false</tt:SystemLogging>"
                "<tt:FirmwareUpgrade>false</tt:FirmwareUpgrade><tt:SupportedVersions><tt:Major>2</tt:Major>"
                "<tt:Minor>60</tt:Minor></tt:SupportedVersions></tt:System><tt:IO>"
                "<tt:InputConnectors>0</tt:InputConnectors><tt:RelayOutputs>0</tt:RelayOutputs></tt:IO>"
                "<tt:Security><tt:TLS1.1>false</tt:TLS1.1><tt:TLS1.2>false</tt:TLS1.2>"
                "<tt:OnboardKeyGeneration>false</tt:OnboardKeyGeneration><tt:AccessPolicyConfig>false"
                "</tt:AccessPolicyConfig><tt:X.509Token>false</tt:X.509Token><tt:SAMLToken>false</tt:SAMLToken>"
                "<tt:KerberosToken>false</tt:KerberosToken><tt:RELToken>false</tt:RELToken></tt:Security></tt:Device>"
                % base)
        if category in ("All", "Media"):
            parts.append("<tt:Media><tt:XAddr>%s/onvif/media_service</tt:XAddr><tt:StreamingCapabilities>"
                         "<tt:RTPMulticast>false</tt:RTPMulticast><tt:RTP_TCP>true</tt:RTP_TCP>"
                         "<tt:RTP_RTSP_TCP>true</tt:RTP_RTSP_TCP></tt:StreamingCapabilities></tt:Media>" % base)
        if category in ("All", "PTZ"):
            parts.append("<tt:PTZ><tt:XAddr>%s/onvif/ptz_service</tt:XAddr></tt:PTZ>" % base)
        if not parts:
            raise SoapFault("NoSuchService", "No %s service" % category, "Receiver")
        return "<tds:Capabilities>%s</tds:Capabilities>" % "".join(parts)
    if op == "GetDeviceInformation":
        return ("<tds:Manufacturer>Microsoft</tds:Manufacturer><tds:Model>Vision AI DevKit</tds:Model>"
                "<tds:FirmwareVersion>%s (RTSP add-on)</tds:FirmwareVersion><tds:SerialNumber>%s</tds:SerialNumber>"
                "<tds:HardwareId>QCS603</tds:HardwareId>"
                % (esc(read_file("/etc/version").strip() or "unknown"), esc(serial())))
    if op == "GetSystemDateAndTime":
        t = time.gmtime()
        return ("<tds:SystemDateAndTime><tt:DateTimeType>NTP</tt:DateTimeType><tt:DaylightSavings>false"
                "</tt:DaylightSavings><tt:TimeZone><tt:TZ>%s</tt:TZ></tt:TimeZone><tt:UTCDateTime><tt:Time>"
                "<tt:Hour>%d</tt:Hour><tt:Minute>%d</tt:Minute><tt:Second>%d</tt:Second></tt:Time><tt:Date>"
                "<tt:Year>%d</tt:Year><tt:Month>%d</tt:Month><tt:Day>%d</tt:Day></tt:Date></tt:UTCDateTime>"
                "</tds:SystemDateAndTime>" % (esc(setting("TIME_ZONE", "UTC0")), t.tm_hour, t.tm_min, t.tm_sec,
                                               t.tm_year, t.tm_mon, t.tm_mday))
    if op == "GetNetworkInterfaces":
        return ('<tds:NetworkInterfaces token="wlan0"><tt:Enabled>true</tt:Enabled><tt:Info><tt:Name>wlan0</tt:Name>'
                "<tt:HwAddress>%s</tt:HwAddress><tt:MTU>1500</tt:MTU></tt:Info><tt:IPv4><tt:Enabled>true</tt:Enabled>"
                "<tt:Config><tt:FromDHCP><tt:Address>%s</tt:Address><tt:PrefixLength>24</tt:PrefixLength>"
                "</tt:FromDHCP><tt:DHCP>true</tt:DHCP></tt:Config></tt:IPv4></tds:NetworkInterfaces>"
                % (esc(read_file("/sys/class/net/wlan0/address").strip()), esc(ctx["host"])))
    if op == "GetScopes":
        name = re.sub(r"[^A-Za-z0-9_-]", "_", setting("NAME", "vision-ai-devkit"))
        return "".join("<tds:Scopes><tt:ScopeDef>Fixed</tt:ScopeDef><tt:ScopeItem>onvif://www.onvif.org/%s"
                       "</tt:ScopeItem></tds:Scopes>" % s for s in
                       ("type/video_encoder", "type/ptz", "Profile/Streaming", "hardware/Vision_AI_DevKit",
                        "name/" + name))
    if op == "GetHostname":
        return ("<tds:HostnameInformation><tt:FromDHCP>false</tt:FromDHCP><tt:Name>%s</tt:Name>"
                "</tds:HostnameInformation>" % esc(setting("NAME", "vision-ai-devkit")))
    if op == "GetServiceCapabilities":
        return ('<tds:Capabilities><tds:Network IPFilter="false" ZeroConfiguration="false" IPVersion6="false" '
                'DynDNS="false" Dot11Configuration="false" HostnameFromDHCP="false" NTP="0"/>'
                '<tds:Security TLS1.0="false" TLS1.1="false" TLS1.2="false" OnboardKeyGeneration="false" '
                'AccessPolicyConfig="false" DefaultAccessPolicy="false" Dot1X="false" RemoteUserHandling="false" '
                'X.509Token="false" SAMLToken="false" KerberosToken="false" UsernameToken="false" HttpDigest="false" '
                'RELToken="false"/><tds:System DiscoveryResolve="false" DiscoveryBye="false" RemoteDiscovery="false" '
                'SystemBackup="false" SystemLogging="false" FirmwareUpgrade="false"/></tds:Capabilities>')
    return None


def media_op(op, body, ctx, ptz):
    if op == "GetServiceCapabilities":
        return ('<trt:Capabilities SnapshotUri="false" Rotation="false" VideoSourceMode="false" OSD="false">'
                '<trt:ProfileCapabilities MaximumNumberOfProfiles="2"/><trt:StreamingCapabilities RTPMulticast="false" '
                'RTP_TCP="true" RTP_RTSP_TCP="true" NonAggregateControl="false" NoRTSPStreaming="false"/>'
                "</trt:Capabilities>")
    if op == "GetProfiles":
        return "".join(profile_xml("trt:Profiles", s) for s in streams())
    if op == "GetProfile":
        return profile_xml("trt:Profile", stream(text(body, "ProfileToken", "")))
    if op == "GetStreamUri":
        s = stream(text(body, "ProfileToken", ""))
        return ("<trt:MediaUri><tt:Uri>rtsp://%s:%d/live</tt:Uri><tt:InvalidAfterConnect>false</tt:InvalidAfterConnect>"
                "<tt:InvalidAfterReboot>false</tt:InvalidAfterReboot><tt:Timeout>PT0S</tt:Timeout></trt:MediaUri>"
                % (ctx["host"], s[7]))
    if op == "GetVideoSources":
        return ('<trt:VideoSources token="video"><tt:Framerate>%d</tt:Framerate><tt:Resolution><tt:Width>%d</tt:Width>'
                "<tt:Height>%d</tt:Height></tt:Resolution></trt:VideoSources>"
                % (number("MAIN_FPS", 30), SENSOR[0], SENSOR[1]))
    if op == "GetVideoSourceConfigurations":
        return video_source_configuration("trt:Configurations")
    if op == "GetVideoEncoderConfigurations":
        return "".join(video_encoder_configuration("trt:Configurations", s) for s in streams())
    if op == "GetSnapshotUri":
        raise SoapFault("ActionNotSupported", "No snapshot URL; take stills from the RTSP stream")
    return None


def ptz_op(op, body, ctx, ptz):
    if op == "GetServiceCapabilities":
        return ('<tptz:Capabilities EFlip="false" Reverse="false" GetCompatibleConfigurations="false" '
                'MoveStatus="true" StatusPosition="true"/>')
    if op in ("GetNodes", "GetNode"):
        return ('<tptz:PTZNode token="ptz" FixedHomePosition="false" GeoMove="false"><tt:Name>Digital PTZ</tt:Name>'
                "<tt:SupportedPTZSpaces>%s</tt:SupportedPTZSpaces><tt:MaximumNumberOfPresets>%d"
                "</tt:MaximumNumberOfPresets><tt:HomeSupported>true</tt:HomeSupported></tptz:PTZNode>"
                % (SPACES, MAX_PRESETS))
    if op in ("GetConfigurations", "GetConfiguration"):
        return ptz_configuration("tptz:PTZConfiguration")
    if op == "GetConfigurationOptions":
        return ("<tptz:PTZConfigurationOptions><tt:Spaces>%s</tt:Spaces><tt:PTZTimeout><tt:Min>PT1S</tt:Min>"
                "<tt:Max>PT1M</tt:Max></tt:PTZTimeout></tptz:PTZConfigurationOptions>" % SPACES)
    if op == "GetStatus":
        status = "MOVING" if ptz.moving() else "IDLE"
        return ("<tptz:PTZStatus>%s<tt:MoveStatus><tt:PanTilt>%s</tt:PanTilt><tt:Zoom>%s</tt:Zoom></tt:MoveStatus>"
                "<tt:UtcTime>%s</tt:UtcTime></tptz:PTZStatus>"
                % (position_xml("Position", ptz.pan, ptz.tilt, ptz.zoom), status, status,
                   time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
    if op == "GetPresets":
        return "".join('<tptz:Preset token="%s"><tt:Name>%s</tt:Name>%s</tptz:Preset>'
                       % (esc(t), esc(n), position_xml("PTZPosition", p, ti, z)) for t, n, p, ti, z in ptz.presets)
    if op == "SetPreset":
        token = ptz.save_preset(text(body, "PresetName", ""), text(body, "PresetToken", "") or None)
        if token is None:
            raise SoapFault("TooManyPresets", "The camera keeps %d presets" % MAX_PRESETS, "Receiver")
        return "<tptz:PresetToken>%s</tptz:PresetToken>" % esc(token)
    if op == "RemovePreset":
        if not ptz.remove_preset(text(body, "PresetToken", "")):
            raise SoapFault("NoToken", "No such preset")
        return ""
    if op == "GotoPreset":
        p = ptz.preset(text(body, "PresetToken", ""))
        if p is None:
            raise SoapFault("NoToken", "No such preset")
        ptz.goto(p[2], p[3], p[4])
        return ""
    if op == "GotoHomePosition":
        ptz.goto(*ptz.home)
        return ""
    if op == "SetHomePosition":
        ptz.home = (ptz.pan, ptz.tilt, ptz.zoom)
        ptz.save()
        return ""
    if op == "ContinuousMove":
        v = vector(body, "Velocity") or (None, None, None, "")
        ptz.start(clamp(v[0] or 0.0, -1.0, 1.0), clamp(v[1] or 0.0, -1.0, 1.0), clamp(v[2] or 0.0, -1.0, 1.0),
                  duration(text(body, "Timeout")))
        return ""
    if op == "RelativeMove":
        v = vector(body, "Translation")
        if v is None:
            raise SoapFault("InvalidTranslation", "No Translation")
        x, y, z, space = v
        ptz.velocity = (0.0, 0.0, 0.0)
        if z:
            ptz.set(zoom=ptz.zoom + z)
        if x or y:
            if "TranslationSpaceFov" in space:
                ptz.shift(0.5 * (x or 0.0), 0.5 * (y or 0.0))  # 1 = half the view: an edge comes to the centre
            else:
                ptz.set(pan=ptz.pan + (x or 0.0), tilt=ptz.tilt + (y or 0.0))
        ptz.save()
        return ""
    if op == "AbsoluteMove":
        v = vector(body, "Position")
        if v is None:
            raise SoapFault("InvalidPosition", "No Position")
        ptz.goto(ptz.pan if v[0] is None else v[0], ptz.tilt if v[1] is None else v[1],
                 ptz.zoom if v[2] is None else v[2])
        return ""
    if op == "Stop":
        # Stops every movement, whatever the PanTilt and Zoom flags say, as many cameras do: Home
        # Assistant ends a timed continuous zoom with Zoom=false, which would otherwise zoom all the way.
        ptz.stop()
        return ""
    return None


SERVICES = (("/onvif/device_service", "tds", device_op), ("/onvif/media_service", "trt", media_op),
            ("/onvif/ptz_service", "tptz", ptz_op))


def handle_soap(path, body, ctx, ptz):
    m = re.search(r"<(?:[\w.-]+:)?Body\b[^>]*>\s*<(?:[\w.-]+:)?(\w+)", body)
    if not m:
        return 400, envelope(fault("Sender", "WellFormed", "No SOAP request"))
    op = m.group(1)
    own = [s for s in SERVICES if s[0] == path]
    if not own:
        return 404, envelope(fault("Sender", "ActionNotSupported", "No ONVIF service at %s" % path))
    # The service at `path` first; some clients send every request to one address.
    order = own if op == "GetServiceCapabilities" else own + [s for s in SERVICES if s[0] != path]
    try:
        for _, prefix, handler in order:
            result = handler(op, body, ctx, ptz)
            if result is not None:
                return 200, envelope("<%s:%sResponse>%s</%s:%sResponse>" % (prefix, op, result, prefix, op))
        raise SoapFault("ActionNotSupported", "%s is not supported" % op)
    except SoapFault as e:
        return (400 if e.code == "Sender" else 500), envelope(fault(e.code, e.subcode, e.reason))


def unquote(value):
    return re.sub(r"%([0-9A-Fa-f]{2})", lambda m: binascii.unhexlify(m.group(1)).decode("latin-1"),
                  value.replace("+", " ")).encode("latin-1").decode("utf-8", "replace")


def handle_local(query, ptz):
    q = dict((unquote(k), unquote(v)) for k, _, v in (p.partition("=") for p in query.split("&") if p))
    action, token = q.get("do", ""), q.get("token", "")
    if action == "full":
        ptz.goto(ptz.pan, ptz.tilt, 0.0)
    elif action == "home":
        ptz.goto(*ptz.home)
    elif action == "goto" and ptz.preset(token):
        p = ptz.preset(token)
        ptz.goto(p[2], p[3], p[4])
    elif action == "save":
        if ptz.save_preset(q.get("name", "")) is None:
            return 409, "too many presets\n"
    elif action == "delete" and ptz.remove_preset(token):
        pass
    elif action:
        return 400, "unknown request\n"
    lines = ["zoom=%.2f" % ptz.factor(), "pan=%.3f" % ptz.pan, "tilt=%.3f" % ptz.tilt]
    lines += ["preset=%s %s" % (t, n) for t, n, _, _, _ in ptz.presets]
    return 200, "\n".join(lines) + "\n"


# ----- HTTP -----

REASONS = {200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
           409: "Conflict", 413: "Payload Too Large", 500: "Internal Server Error"}


class Client:
    def __init__(self, sock, peer):
        self.sock, self.peer = sock, peer
        self.inbuf, self.outbuf = b"", b""
        self.since = time.monotonic()

    def respond(self, status, body, content_type="application/soap+xml; charset=utf-8"):
        data = body.encode("utf-8")
        self.outbuf = ("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                       % (status, REASONS.get(status, ""), content_type, len(data))).encode() + data

    def handle(self, ptz):
        head, sep, rest = self.inbuf.partition(b"\r\n\r\n")
        if not sep:
            if len(self.inbuf) > MAX_REQUEST:
                self.respond(413, "Too large\n", "text/plain")
            return
        m = re.search(rb"(?im)^content-length:\s*(\d+)", head)
        length = int(m.group(1)) if m else 0
        if length > MAX_REQUEST:
            self.respond(413, "Too large\n", "text/plain")
            return
        if len(rest) < length:
            return
        head, body = head.decode("latin-1"), rest[:length].decode("utf-8", "replace")
        method, target = (head.split("\r\n", 1)[0].split() + ["", ""])[:2]
        path, _, query = target.partition("?")
        host = self.sock.getsockname()[0]  # the camera address the client reached
        if path == "/local/ptz":
            if self.peer[0] != "127.0.0.1":
                self.respond(403, "Forbidden\n", "text/plain")
            else:
                status, reply = handle_local(query, ptz)
                self.respond(status, reply, "text/plain; charset=utf-8")
        elif method != "POST":
            self.respond(405, "ONVIF service: POST SOAP requests to /onvif/device_service\n", "text/plain")
        else:
            status, xml = handle_soap(path, body, {"host": host}, ptz)
            self.respond(status, xml)


def main():
    ptz = Ptz()
    server = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
    server.setsockopt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", PORT))
    server.listen(16)
    server.setblocking(False)
    clients = {}
    log("ONVIF service on port %d: zoom %.2fx, %d presets" % (PORT, ptz.factor(), len(ptz.presets)))
    while True:
        readers = [server] + [c.sock for c in clients.values() if not c.outbuf]
        writers = [c.sock for c in clients.values() if c.outbuf]
        readable, writable, _ = select.select(readers, writers, [], TICK if ptz.moving() else 1.0)
        for sock in readable:
            if sock is server:
                try:
                    fd, peer = server._accept()
                except OSError:
                    continue
                conn = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM, 0, fd)
                conn.setblocking(False)
                clients[conn.fileno()] = Client(conn, peer)
                continue
            c = clients[sock.fileno()]
            try:
                data = sock.recv(16384)
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                data = b""
            if not data:
                del clients[sock.fileno()]
                sock.close()
                continue
            c.inbuf += data
            try:
                c.handle(ptz)
            except Exception as e:  # a bad request must not take the service down
                log("request failed: %r" % e)
                c.respond(500, envelope(fault("Receiver", "Action", "Internal error")))
        for sock in writable:
            c = clients[sock.fileno()]
            try:
                c.outbuf = c.outbuf[sock.send(c.outbuf):]
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                c.outbuf = b""
            if not c.outbuf:
                del clients[sock.fileno()]
                sock.close()
        now = time.monotonic()
        for fd, c in list(clients.items()):
            if now - c.since > 15:
                del clients[fd]
                c.sock.close()
        ptz.tick()


if __name__ == "__main__":
    main()
