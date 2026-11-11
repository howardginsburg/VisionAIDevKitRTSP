#!/usr/bin/python3
# Vision AI DevKit RTSP add-on: RTSP server for the camera streams.
#
# vaidk-camd (the add-on's camera program) sends the encoded streams over a Unix socket:
# main video (H.264/H.265), sub video (H.264) and the microphone (AAC-LC). This serves them as
#   rtsp://<camera>:8900/live   main video + microphone
#   rtsp://<camera>:8901/live   sub video
# Talk-back: a client that asks for the ONVIF backchannel (Require: www.onvif.org/ver20/backchannel,
# as Frigate's go2rtc does) also gets a send-only G.711 audio track on the main stream. What it sends
# there goes to vaidk-camd, which plays it on the speaker. One client talks at a time: whoever sends
# first keeps the speaker until they pause for a second.
# Video keeps the camera's capture timestamps. The camera's audio timestamps are wrong after the
# first frame, so audio is timed by its sample count from that first capture time and kept in
# step with the video clock (whole-frame corrections if the two drift apart). Arrival times are
# measured on CLOCK_MONOTONIC_RAW, which runs at the capture clock's rate whatever NTP does to the
# system clock.
# RTSP over TCP only: UDP SETUPs get "461 Unsupported Transport" and clients retry over TCP.
# Writes /run/vaidk/rtsp.status, and /run/vaidk/streaming while every stream is flowing.
#
# usage: rtspd.py [SOCKET [MAIN_PORT [SUB_PORT]]]
# The camera's Python 3.5 has no socket/selectors/threading modules, so this uses _socket and
# a single epoll loop.
import _socket
import binascii
import os
import random
import re
import select
import struct
import sys
import time

SOCKET_PATH = sys.argv[1] if len(sys.argv) > 1 else "/run/vaidk/media.sock"
MAIN_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8900
SUB_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8901
STATUS_FILE = "/run/vaidk/rtsp.status"
STREAMING_FLAG = "/run/vaidk/streaming"

MAX_CLIENTS = 8
MAX_PAYLOAD = 1400              # RTP payload bytes per packet
CLIENT_BACKLOG = 4 << 20        # disconnect clients that fall this far behind
STALE_AFTER = 5.0               # a stream counts as stopped after this long without frames
SR_INTERVAL = 2.0               # RTCP sender reports let players line audio up with video
DESCRIBE_WAIT = 6.0             # wait this long for the stream details before answering DESCRIBE
SYNC_WINDOW = 3.0               # seconds of audio arrival history used to detect clock drift
SYNC_TOLERANCE = 0.06           # audio drift (seconds) that triggers a whole-frame correction
SESSION_TIMEOUT = 60
TALK_HOLD = 1.0                 # a talker keeps the speaker until silent this long
BACKCHANNEL = "www.onvif.org/ver20/backchannel"
MAGIC = 0x4B494156              # "VAIK", see camd.cpp
HEADER = struct.Struct("<IBBHQQI")
AAC_RATES = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)
NTP_EPOCH = 2208988800
EPOLLIN, EPOLLOUT, EPOLLERR, EPOLLHUP = select.EPOLLIN, select.EPOLLOUT, select.EPOLLERR, select.EPOLLHUP


def now():
    """The clock vaidk-camd stamps arrivals with: the hardware clock, never slewed by NTP."""
    return time.clock_gettime(time.CLOCK_MONOTONIC_RAW)


epoll = select.epoll()
clients = {}


def log(msg):
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def b64(data):
    return binascii.b2a_base64(data).decode("ascii").strip()


def parse_head(head):
    lines = head.split("\r\n")
    headers = {}
    for line in lines[1:]:
        key, sep, value = line.partition(":")
        if sep:
            headers[key.strip().lower()] = value.strip()
    return lines[0], headers


def split_annexb(data):
    nals = []
    size = len(data)
    i = data.find(b"\x00\x00\x01")
    while i >= 0:
        start = i + 3
        i = data.find(b"\x00\x00\x01", start)
        end = size if i < 0 else i
        while end > start and data[end - 1] == 0:
            end -= 1
        if end > start:
            nals.append(data[start:end])
    return nals


def rtp_header(marker, pt, seq, ts, ssrc):
    return struct.pack(">BBHII", 0x80, pt | (0x80 if marker else 0), seq & 0xFFFF, ts & 0xFFFFFFFF, ssrc)


def rtcp_sender_report(ssrc, rtp_ts, packets, octets):
    wall = time.time() + NTP_EPOCH
    sec = int(wall)
    frac = int((wall - sec) * 4294967296.0) & 0xFFFFFFFF
    sr = struct.pack(">BBHIIIIII", 0x80, 200, 6, ssrc, sec & 0xFFFFFFFF, frac, rtp_ts & 0xFFFFFFFF,
                     packets & 0xFFFFFFFF, octets & 0xFFFFFFFF)
    item = b"\x01\x05vaidk\x00"
    return sr + struct.pack(">BBHI", 0x81, 202, (4 + len(item)) // 4, ssrc) + item


def interleave(ch, pkt):
    return struct.pack(">BBH", 0x24, ch & 0xFF, len(pkt)) + pkt


class Stream:
    """One RTSP stream: codec details, timing, RTP packetization and fan-out to its clients."""

    def __init__(self, name, port):
        self.name, self.port = name, port
        self.enabled = False        # announced by the camera program
        self.vcodec = None          # "H264" or "H265"
        self.params = {}            # NAL type -> latest VPS/SPS/PPS
        self.audio_expected = False
        self.acfg = None            # (ADTS profile, sampling index, channels)
        self.rate = 0
        self.talk = None            # vaidk-camd's talk-back socket, while talk-back is on
        self.generation = 0         # bumped when clients must re-read the SDP
        self.sdp_id = random.getrandbits(31)
        self.vssrc, self.assrc = random.getrandbits(32), random.getrandbits(32)
        self.vseq, self.aseq = random.getrandbits(16), random.getrandbits(16)
        self.vrtp0, self.artp0 = random.getrandbits(32), random.getrandbits(32)
        self.vpackets = self.voctets = self.apackets = self.aoctets = 0
        self.last_video = self.last_audio = 0.0
        self.video_latency = 0.0
        self.offset = 0.0           # the camera's capture clock minus now()
        self.corrections = 0
        self.last_mt = None
        self.reset_audio_timing()

    def reset_audio_timing(self):
        self.a_anchor = None        # capture time of the first audio frame
        self.a_index = self.a_drop = 0
        self.a_base = None          # steady-state audio delivery latency
        self.aerr = []              # (arrival, latency) of recent audio frames

    def configure(self, codec, audio, talk):
        if self.vcodec is not None and codec != self.vcodec:
            self.generation += 1
            self.params = {}
            log("%s stream codec changed to %s; clients reconnect" % (self.name, codec))
        if talk != self.talk:
            # Only clients that asked for the backchannel see a different SDP.
            for c in self.clients():
                if c.want_talk and c.playing:
                    c.close("talk-back turned %s" % ("on" if talk else "off"))
        self.enabled, self.vcodec, self.audio_expected, self.talk = True, codec, audio, talk
        if not audio:
            self.acfg = None

    def camera_lost(self):
        self.last_mt = None
        self.reset_audio_timing()
        for c in self.clients():
            c.vstarted = False

    def clients(self):
        return [c for c in clients.values() if c.stream is self]

    def param_types(self):
        return (32, 33, 34) if self.vcodec == "H265" else (7, 8)

    def describable(self, full):
        if not self.enabled or self.vcodec is None or not all(t in self.params for t in self.param_types()):
            return False
        return not full or self.acfg is not None or not self.audio_expected

    def sdp(self, host, talk):
        lines = ["v=0", "o=- %d 1 IN IP4 %s" % (self.sdp_id, host), "s=Vision AI DevKit %s stream" % self.name,
                 "t=0 0", "a=tool:vaidk", "a=type:broadcast", "a=control:*", "a=range:npt=0-",
                 "m=video 0 RTP/AVP 96", "c=IN IP4 0.0.0.0"]
        p = self.params
        if self.vcodec == "H265":
            lines += ["a=rtpmap:96 H265/90000",
                      "a=fmtp:96 sprop-vps=%s;sprop-sps=%s;sprop-pps=%s" % (b64(p[32]), b64(p[33]), b64(p[34]))]
        else:
            sps = p[7]
            lines += ["a=rtpmap:96 H264/90000",
                      "a=fmtp:96 packetization-mode=1;profile-level-id=%02X%02X%02X;sprop-parameter-sets=%s,%s"
                      % (sps[1], sps[2], sps[3], b64(sps), b64(p[8]))]
        lines.append("a=control:track1")
        if self.acfg:
            profile, index, channels = self.acfg
            config = ((profile + 1) << 11) | (index << 7) | (channels << 3)
            lines += ["m=audio 0 RTP/AVP 97", "c=IN IP4 0.0.0.0",
                      "a=rtpmap:97 MPEG4-GENERIC/%d/%d" % (self.rate, channels),
                      "a=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;"
                      "indexdeltalength=3;config=%04X" % config,
                      "a=control:track2"]
        if talk:
            # The ONVIF backchannel: "sendonly" from the client's side.
            lines += ["m=audio 0 RTP/AVP 0 8", "c=IN IP4 0.0.0.0", "a=rtpmap:0 PCMU/8000", "a=rtpmap:8 PCMA/8000",
                      "a=control:track3", "a=sendonly"]
        return ("\r\n".join(lines) + "\r\n").encode("ascii")

    # ----- video -----

    def on_video(self, data, timestamp_us, received_us):
        if self.vcodec is None:
            return
        h265 = self.vcodec == "H265"
        params = self.param_types()
        sps_type = params[1] if h265 else params[0]
        au, key, have = [], False, set()
        for nal in split_annexb(data):
            t = (nal[0] >> 1) & 0x3F if h265 else nal[0] & 0x1F
            if t in ((35, 38) if h265 else (9, 12)):        # access unit delimiter, filler
                continue
            if t in params:
                if t == sps_type and self.params.get(t) not in (None, nal):
                    self.generation += 1
                    log("%s stream format changed; clients reconnect" % self.name)
                self.params[t] = nal
            if (16 <= t <= 23) if h265 else t == 5:
                key = True
            have.add(t)
            au.append(nal)
        if not au:
            return
        if key:
            au = [self.params[t] for t in params if t in self.params and t not in have] + au
        mt = timestamp_us / 1e6
        if self.last_mt is not None and mt <= self.last_mt:
            mt = self.last_mt + 0.001
        self.last_mt = mt
        arrival = received_us / 1e6
        self.last_video = arrival
        self.video_latency = arrival + self.offset - mt
        rtp_ts = (self.vrtp0 + int(round(mt * 90000))) & 0xFFFFFFFF
        pkts = []
        last = len(au) - 1
        for i, nal in enumerate(au):
            if len(nal) <= MAX_PAYLOAD:
                pkts.append(self.video_packet(nal, rtp_ts, i == last))
                continue
            if h265:
                head = bytes(((nal[0] & 0x81) | (49 << 1), nal[1]))
                fu, body = (nal[0] >> 1) & 0x3F, nal[2:]
            else:
                head = bytes(((nal[0] & 0xE0) | 28,))
                fu, body = nal[0] & 0x1F, nal[1:]
            step = MAX_PAYLOAD - len(head) - 1
            pos, size = 0, len(body)
            while pos < size:
                flags = (0x80 if pos == 0 else 0) | (0x40 if pos + step >= size else 0)
                chunk = body[pos:pos + step]
                pos += step
                pkts.append(self.video_packet(head + bytes((fu | flags,)) + chunk, rtp_ts, i == last and pos >= size))
        self.deliver(True, pkts, key)

    def video_packet(self, payload, ts, marker):
        self.vseq = (self.vseq + 1) & 0xFFFF
        self.vpackets += 1
        self.voctets += len(payload)
        return rtp_header(marker, 96, self.vseq, ts, self.vssrc) + payload

    # ----- audio -----

    def on_audio_config(self, asc):
        if len(asc) < 2:
            return
        profile = (asc[0] >> 3) - 1
        index = ((asc[0] & 7) << 1) | (asc[1] >> 7)
        channels = (asc[1] >> 3) & 0xF
        if profile < 0 or index >= len(AAC_RATES):
            return
        cfg = (profile, index, channels)
        if cfg == self.acfg:
            return
        if self.acfg is not None:
            self.generation += 1
            log("%s stream audio format changed; clients reconnect" % self.name)
        else:
            for c in self.clients():
                if c.playing and not c.sdp_audio:
                    c.close("audio became available" if not c.local else None)
        self.acfg, self.rate = cfg, AAC_RATES[index]
        self.reset_audio_timing()

    def on_audio(self, frame, timestamp_us, received_us):
        if not self.acfg or not frame:
            return
        arrival = received_us / 1e6
        self.last_audio = arrival
        cam_arrival = arrival + self.offset             # the arrival time on the capture clock
        dur = 1024.0 / self.rate
        if self.a_anchor is None:
            first = timestamp_us / 1e6
            self.a_anchor = first if 0 < cam_arrival - first < 2.0 else cam_arrival - 0.2
        if self.a_drop > 0:                                 # audio clock ran fast: skip a frame
            self.a_drop -= 1
            return
        mt = self.a_anchor + self.a_index * dur
        self.a_index += 1
        self.aerr.append((arrival, cam_arrival - mt))
        if arrival - self.aerr[0][0] >= SYNC_WINDOW:
            latency = min(l for _, l in self.aerr)
            self.aerr = []
            if self.a_base is None:
                self.a_base = latency
            elif abs(latency - self.a_base) > SYNC_TOLERANCE:
                err = latency - self.a_base
                if err > 0:
                    self.a_index += int(round(err / dur))    # audio clock ran slow: leave a gap
                else:
                    self.a_drop += int(round(-err / dur))
                self.corrections += 1
                if self.corrections <= 5 or self.corrections % 100 == 0:
                    log("audio realigned with video by %+d ms (%d corrections)" % (err * 1000, self.corrections))
        ts = (self.artp0 + int(round(mt * self.rate))) & 0xFFFFFFFF
        self.aseq = (self.aseq + 1) & 0xFFFF
        self.apackets += 1
        self.aoctets += len(frame) + 4
        pkt = rtp_header(True, 97, self.aseq, ts, self.assrc) + struct.pack(">HH", 16, len(frame) << 3) + frame
        self.deliver(False, [pkt], False)

    # ----- fan-out -----

    def deliver(self, video, pkts, key):
        framed = {}
        for c in self.clients():
            if not c.playing:
                continue
            if video:
                ch = c.vch
                if ch is None:
                    continue
                if not c.vstarted:
                    if not key:
                        continue
                    c.vstarted = True
            else:
                ch = c.ach
                if ch is None or (c.vch is not None and not c.vstarted):
                    continue
            data = framed.get(ch)
            if data is None:
                data = framed[ch] = b"".join(interleave(ch, p) for p in pkts)
            c.write(data)

    def sender_reports(self, c):
        t = now() + self.offset
        if c.vch is not None:
            c.write(interleave(c.vch + 1, rtcp_sender_report(
                self.vssrc, self.vrtp0 + int(round(t * 90000)), self.vpackets, self.voctets)))
        if c.ach is not None and self.rate:
            c.write(interleave(c.ach + 1, rtcp_sender_report(
                self.assrc, self.artp0 + int(round(t * self.rate)), self.apackets, self.aoctets)))


class CameraInput:
    """Unix-socket server that receives the streams from vaidk-camd."""

    def __init__(self, path):
        self.path = path
        self.listener = self.sock = self.fd = None
        self.buf = bytearray()
        self.connected = False

    def open(self):
        try:
            os.unlink(self.path)
        except OSError:
            pass
        s = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
        s.bind(self.path)
        os.chmod(self.path, 0o600)
        s.listen(2)
        s.setblocking(False)
        self.listener = s
        epoll.register(s.fileno(), EPOLLIN)

    def accept(self):
        try:
            fd, _ = self.listener._accept()
        except OSError:
            return
        if self.sock is not None:
            self.close("the camera program reconnected")
        s = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM, 0, fd)
        s.setblocking(False)
        try:
            s.setsockopt(_socket.SOL_SOCKET, _socket.SO_RCVBUF, 2 << 20)
        except OSError:
            pass
        self.sock, self.fd, self.buf, self.connected = s, s.fileno(), bytearray(), True
        epoll.register(self.fd, EPOLLIN)
        log("camera connected")

    def close(self, reason):
        if self.sock is None:
            return
        try:
            epoll.unregister(self.fd)
        except (OSError, ValueError):
            pass
        self.sock.close()
        self.sock = self.fd = None
        self.connected = False
        for s in streams:
            s.camera_lost()
        log("camera disconnected: %s" % reason)

    def on_event(self, ev):
        if ev & EPOLLIN:
            try:
                data = self.sock.recv(262144)
            except BlockingIOError:
                return
            except OSError as e:
                self.close(str(e))
                return
            if not data:
                self.close("connection closed")
                return
            self.buf += data
            self.parse()
        elif ev & (EPOLLERR | EPOLLHUP):
            self.close("connection error")

    def parse(self):
        buf, pos, size = self.buf, 0, len(self.buf)
        while pos + HEADER.size <= size:
            magic, stream_id, flags, _, timestamp, received, length = HEADER.unpack_from(buf, pos)
            if magic != MAGIC:
                self.close("unexpected data")
                return
            end = pos + HEADER.size + length
            if end > size:
                break
            payload = bytes(buf[pos + HEADER.size:end])
            pos = end
            if stream_id == 1:
                main.on_video(payload, timestamp, received)
            elif stream_id == 2:
                sub.on_video(payload, timestamp, received)
            elif stream_id == 3:
                if flags & 2:
                    main.on_audio_config(payload)
                else:
                    main.on_audio(payload, timestamp, received)
            elif stream_id == 0:
                self.on_info(payload.decode("ascii", "replace"))
        del buf[:pos]

    def on_info(self, text):
        info = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
        clock = info.pop("clock", "")
        if re.match(r"-?\d+$", clock):
            offset = int(clock) / 1e6
        else:
            offset = time.clock_gettime(time.CLOCK_MONOTONIC) - now()
        for s, key in ((main, "main"), (sub, "sub")):
            s.offset = offset
            if key in info:
                s.configure("H265" if info[key].startswith("H265") else "H264", key == "main" and "audio" in info,
                            (info.get("talk") or None) if key == "main" else None)
            else:
                s.enabled = False
        log("camera streams: %s" % "; ".join("%s %s" % kv for kv in sorted(info.items())))


class Client:
    """One RTSP client connection: requests in, interleaved RTP/RTCP out."""

    def __init__(self, sock, addr, stream):
        self.sock, self.fd, self.stream = sock, sock.fileno(), stream
        self.peer = "%s:%d" % addr
        self.local = addr[0].startswith("127.")
        self.inbuf, self.out = bytearray(), bytearray()
        self.session = None
        self.vch = self.ach = self.bch = None       # interleaved channels: video, audio, backchannel
        self.playing = self.vstarted = self.closing = self.closed = self.sdp_audio = False
        self.want_talk = self.sdp_talk = False      # asked for the backchannel; got it in the SDP
        self.generation = 0
        self.pending = None             # deferred DESCRIBE: (cseq, uri, deadline)
        self.next_sr = 0.0
        self.opened = now()

    def write(self, data):
        if self.closed:
            return
        if self.out:
            self.out += data
            if len(self.out) > CLIENT_BACKLOG:
                self.close("can't keep up with the stream")
            return
        try:
            sent = self.sock.send(data)
        except BlockingIOError:
            sent = 0
        except OSError:
            self.close(None)
            return
        if sent < len(data):
            self.out += data[sent:]
            epoll.modify(self.fd, EPOLLIN | EPOLLOUT)

    def on_writable(self):
        try:
            sent = self.sock.send(self.out)
        except BlockingIOError:
            return
        except OSError:
            self.close(None)
            return
        del self.out[:sent]
        if not self.out:
            if self.closing:
                self.close(None)
            else:
                epoll.modify(self.fd, EPOLLIN)

    def close(self, reason):
        if self.closed:
            return
        self.closed = True
        try:
            epoll.unregister(self.fd)
        except (OSError, ValueError):
            pass
        self.sock.close()
        clients.pop(self.fd, None)
        if not self.local and (reason or self.playing):
            log("%s client %s disconnected%s" % (self.stream.name, self.peer, ": " + reason if reason else ""))

    def on_readable(self):
        try:
            data = self.sock.recv(65536)
        except BlockingIOError:
            return
        except OSError:
            self.close(None)
            return
        if not data:
            self.close(None)
            return
        self.inbuf += data
        buf = self.inbuf
        while buf and not self.closed:
            if buf[0] == 0x24:                          # interleaved RTP/RTCP from the client
                if len(buf) < 4:
                    break
                size = (buf[2] << 8) | buf[3]
                if len(buf) < 4 + size:
                    break
                if buf[1] == self.bch and self.playing:
                    talk(self, buf[4:4 + size])
                del buf[:4 + size]
                continue
            end = buf.find(b"\r\n\r\n")
            if end < 0:
                if len(buf) > 16384:
                    self.close("oversized request")
                break
            first, headers = parse_head(bytes(buf[:end]).decode("latin-1"))
            length = int(headers.get("content-length", "0") or 0)
            if len(buf) < end + 4 + length:
                break
            del buf[:end + 4 + length]
            self.handle(first, headers)

    def reply(self, cseq, status, headers=(), body=b""):
        lines = ["RTSP/1.0 " + status, "CSeq: " + cseq, "Server: vaidk"] + list(headers)
        if body:
            lines.append("Content-Length: %d" % len(body))
        self.write(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + body)

    def handle(self, first, headers):
        parts = first.split()
        if len(parts) < 3 or not parts[2].startswith("RTSP/"):
            self.close("not an RTSP request")
            return
        method, uri = parts[0].upper(), parts[1]
        cseq = headers.get("cseq", "0")
        session = headers.get("session", "").split(";")[0].strip()
        if session and session != self.session and method not in ("OPTIONS", "DESCRIBE"):
            self.reply(cseq, "454 Session Not Found")
            return
        session_header = ["Session: " + self.session] if self.session else []
        if method == "OPTIONS":
            self.reply(cseq, "200 OK", ["Public: OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, TEARDOWN, GET_PARAMETER, SET_PARAMETER"])
        elif method == "DESCRIBE":
            self.want_talk = BACKCHANNEL in headers.get("require", "")
            self.pending = (cseq, uri, now() + DESCRIBE_WAIT)
            self.service(now())
        elif method == "SETUP":
            self.setup(cseq, uri, headers.get("transport", ""))
        elif method == "PLAY":
            if not self.session or (self.vch is None and self.ach is None and self.bch is None):
                self.reply(cseq, "455 Method Not Valid in This State")
                return
            if not self.playing:
                if not self.local:
                    log("%s stream: streaming to %s" % (self.stream.name, self.peer))
                self.playing, self.vstarted, self.generation = True, False, self.stream.generation
            self.reply(cseq, "200 OK", session_header + ["Range: npt=0.000-"])
            # A sender report ahead of the first RTP packet lets players sync audio and video from the start.
            self.stream.sender_reports(self)
            self.next_sr = now() + SR_INTERVAL
        elif method == "PAUSE":
            self.playing = False
            self.reply(cseq, "200 OK", session_header)
        elif method == "TEARDOWN":
            self.playing = False
            self.reply(cseq, "200 OK", session_header)
            self.closing = True
            if not self.out:
                self.close(None)
        elif method in ("GET_PARAMETER", "SET_PARAMETER"):
            self.reply(cseq, "200 OK", session_header)
        else:
            self.reply(cseq, "501 Not Implemented")

    def setup(self, cseq, uri, transport):
        s = self.stream
        m = re.search(r"track(?:ID=)?(\d+)/?$", uri)
        track = int(m.group(1)) if m else 0
        if not (track == 1 and s.vcodec) and not (track == 2 and s.acfg) and \
                not (track == 3 and self.sdp_talk and s.talk):
            self.reply(cseq, "404 Not Found")
            return
        if "TCP" not in transport.upper():
            self.reply(cseq, "461 Unsupported Transport")
            return
        m = re.search(r"interleaved=(\d+)", transport)
        ch = int(m.group(1)) if m else 2 * (track - 1)
        if ch > 254:
            self.reply(cseq, "461 Unsupported Transport")
            return
        if self.session is None:
            self.session = "%08X" % random.getrandbits(32)
        reply = "Transport: RTP/AVP/TCP;unicast;interleaved=%d-%d" % (ch, ch + 1)
        if track == 1:
            self.vch = ch
            reply += ";ssrc=%08X" % s.vssrc
        elif track == 2:
            self.ach = ch
            reply += ";ssrc=%08X" % s.assrc
        else:
            self.bch = ch
        self.reply(cseq, "200 OK", [reply, "Session: %s;timeout=%d" % (self.session, SESSION_TIMEOUT)])

    def service(self, t):
        if self.closed:
            return
        s = self.stream
        off = camera.connected and not s.enabled          # the camera isn't producing this stream
        if self.pending and (off or s.describable(True) or t >= self.pending[2]):
            cseq, uri, _ = self.pending
            self.pending = None
            if s.describable(False):
                base = uri if uri.endswith("/") else uri + "/"
                self.sdp_audio = s.acfg is not None
                self.sdp_talk = self.want_talk and s.talk is not None
                self.reply(cseq, "200 OK", ["Content-Base: " + base, "Content-Type: application/sdp"],
                           s.sdp(self.sock.getsockname()[0], self.sdp_talk))
            else:
                self.reply(cseq, "503 Service Unavailable")
        if self.playing:
            if self.generation != s.generation:
                self.close("stream format changed")
            elif t >= self.next_sr:
                self.next_sr = t + SR_INTERVAL
                s.sender_reports(self)
        elif not self.session and t - self.opened > SESSION_TIMEOUT:
            self.close(None)


talk_out = _socket.socket(_socket.AF_UNIX, _socket.SOCK_DGRAM)
talk_out.setblocking(False)
talker = [None, 0.0]                # the client holding the speaker, and until when


def talk(client, pkt):
    """Passes one backchannel RTP packet's G.711 payload to vaidk-camd: [payload type][payload]."""
    if len(pkt) < 12 or pkt[0] >> 6 != 2 or main.talk is None:
        return
    pt = pkt[1] & 0x7F
    start = 12 + 4 * (pkt[0] & 0x0F)                    # after any CSRCs
    if pkt[0] & 0x10:                                   # header extension
        if len(pkt) < start + 4:
            return
        start += 4 + 4 * ((pkt[start + 2] << 8) | pkt[start + 3])
    end = len(pkt) - (pkt[-1] if pkt[0] & 0x20 else 0)  # padding
    if pt not in (0, 8) or end <= start:
        return
    t = now()
    if talker[0] is not client:
        if t < talker[1]:
            return                                      # someone else is talking
        if not client.local:
            log("talk-back from %s" % client.peer)
    talker[0], talker[1] = client, t + TALK_HOLD
    try:
        talk_out.sendto(bytes((pt,)) + bytes(pkt[start:end]), main.talk)
    except OSError:
        pass                                            # vaidk-camd is restarting or behind


def open_listener(port):
    s = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
    try:
        s.setsockopt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", port))
        s.listen(16)
    except OSError:
        s.close()
        raise
    s.setblocking(False)
    epoll.register(s.fileno(), EPOLLIN)
    return s


def accept(listener, stream):
    while True:
        try:
            fd, addr = listener._accept()
        except OSError:
            return
        sock = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM, 0, fd)
        if len(clients) >= MAX_CLIENTS:
            sock.close()
            continue
        sock.setblocking(False)
        sock.setsockopt(_socket.IPPROTO_TCP, _socket.TCP_NODELAY, 1)
        c = Client(sock, addr, stream)
        clients[c.fd] = c
        epoll.register(c.fd, EPOLLIN)


def healthy(t):
    fresh = lambda stamp: stamp and t - stamp < STALE_AFTER
    return camera.connected and fresh(main.last_video) and (not sub.enabled or fresh(sub.last_video)) and \
        (not main.audio_expected or fresh(main.last_audio))


def write_status(t):
    def age(stamp):
        return "%d" % (t - stamp) if stamp else "-1"
    lines = ["time=%d" % time.time(), "camera=%d" % camera.connected,
             "main=%s" % (main.vcodec if main.enabled else "off"), "main_age=" + age(main.last_video),
             "sub=%s" % (sub.vcodec if sub.enabled else "off"), "sub_age=" + age(sub.last_video),
             "audio=%s" % ("AAC %d Hz %d ch" % (main.rate, main.acfg[2]) if main.acfg else "off"),
             "audio_age=" + age(main.last_audio), "audio_corrections=%d" % main.corrections,
             "video_latency_ms=%d" % (main.video_latency * 1000),
             "audio_latency_ms=%d" % ((main.a_base or 0) * 1000),
             "clients=%d" % sum(1 for c in clients.values() if c.playing and not c.local)]
    try:
        with open(STATUS_FILE + ".tmp", "w") as f:
            f.write("\n".join(lines) + "\n")
        os.rename(STATUS_FILE + ".tmp", STATUS_FILE)
        if healthy(t):
            if not os.path.exists(STREAMING_FLAG):
                open(STREAMING_FLAG, "w").close()
        elif os.path.exists(STREAMING_FLAG):
            os.unlink(STREAMING_FLAG)
    except OSError:
        pass


main = Stream("main", MAIN_PORT)
sub = Stream("sub", SUB_PORT)
streams = (main, sub)
camera = CameraInput(SOCKET_PATH)


def run():
    try:
        os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)
    except OSError:
        pass
    camera.open()
    listeners = {}                  # fd -> (listening socket, stream)
    next_bind, next_status, bind_logged = 0.0, 0.0, set()
    log("RTSP server: main :%d, sub :%d, camera input %s" % (MAIN_PORT, SUB_PORT, SOCKET_PATH))
    while True:
        t = now()
        if len(listeners) < len(streams) and t >= next_bind:
            bound = [s for _, s in listeners.values()]
            for s in streams:
                if s in bound:
                    continue
                try:
                    sock = open_listener(s.port)
                    listeners[sock.fileno()] = (sock, s)
                except OSError as e:
                    if s.port not in bind_logged:
                        log("port %d is busy (%s); retrying" % (s.port, e))
                        bind_logged.add(s.port)
            next_bind = t + 2.0
        for c in list(clients.values()):
            c.service(t)
        if t >= next_status:
            write_status(t)
            next_status = t + 1.0
        for fd, ev in epoll.poll(0.2):
            if fd in listeners:
                accept(*listeners[fd])
            elif fd == camera.listener.fileno():
                camera.accept()
            elif fd == camera.fd:
                camera.on_event(ev)
            else:
                c = clients.get(fd)
                if c is None:
                    continue
                if ev & EPOLLIN:
                    c.on_readable()
                if ev & EPOLLOUT and not c.closed:
                    c.on_writable()
                if ev & (EPOLLERR | EPOLLHUP) and not c.closed:
                    c.close(None)


if __name__ == "__main__":
    run()
