#!/usr/bin/python3
# Vision AI DevKit RTSP add-on: MQTT service. Publishes what the object detector (vaidk-detect) sees to
# an MQTT broker, for Home Assistant, Node-RED and the like. Under the topic MQTT_TOPIC:
#   status            online, or offline (retained; offline is also the last will)
#   <object>          ON while the object is in view, OFF once it has gone (retained)
#   <object>/count    how many are in view (retained)
#   detections        JSON after each analysis while something is in view, then once with none
# <object> is the label with an underscore for each space (teddy_bear). With MQTT_DISCOVERY=1 it also
# announces a binary sensor and a count sensor for each object to Home Assistant (MQTT discovery), and
# removes the ones it announced before for objects no longer chosen, or all of them once discovery is
# turned off.
#
# MQTT 3.1.1 at QoS 0, with an optional user name and password, without TLS. The camera's Python has
# only part of the standard library (no socket, ssl, threading, signal or json modules), so this uses
# _socket and select directly and writes its JSON by hand. The detector sends its events as text
# datagrams to MQTT_EVENTS (see camd/detect.cpp); between connections, the latest state is kept and
# published once the broker is back. Whatever was in view counts as gone when the detector starts again
# or stops updating its status file.
import _socket
import errno
import os
import re
import select
import sys
import time

HOST = os.environ.get("MQTT_HOST", "")
PORT = int(os.environ.get("MQTT_PORT") or 1883)
USER = os.environ.get("MQTT_USER", "")
PASSWORD_FILE = os.environ.get("MQTT_PASSWORD_FILE", "/data/misc/vaidk/mqtt-password")
NAME = os.environ.get("NAME") or "vision-ai-devkit"
TOPIC = (os.environ.get("MQTT_TOPIC") or "vaidk/" + NAME).strip("/")
DISCOVERY = os.environ.get("MQTT_DISCOVERY") == "1"
DISCOVERY_FILE = os.environ.get("MQTT_DISCOVERY_FILE", "/data/misc/vaidk/mqtt-discovery")
# The chosen objects; "all" (set by hand) means whatever is detected, without Home Assistant sensors.
OBJECTS = [o for o in (os.environ.get("DETECT_OBJECTS") or "person").split(",") if o and o != "all"]
EVENTS = os.environ.get("MQTT_EVENTS", "/run/vaidk/events.sock")
STATE = os.environ.get("MQTT_STATE", "/run/vaidk/mqtt.state")
DETECT_STATE = os.environ.get("DETECT_STATE", "/run/vaidk/detect.state")
KEEPALIVE = 60                 # seconds; a ping goes out after half of it without sending anything
TIMEOUT = 10                   # seconds to connect, and to get the broker's answer
BACKOFF = (5, 10, 30, 60)      # seconds before each new attempt after a failure
CONNACK_ERRORS = {
    1: "the broker doesn't speak MQTT 3.1.1",
    2: "the broker refused the client ID",
    3: "the broker is unavailable",
    4: "wrong user name or password",
    5: "not authorised",
}


def log(text):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def read_file(path, default="", mode="r"):
    try:
        with open(path, mode) as f:
            return f.read()
    except OSError:
        return default


def write_file(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.rename(tmp, path)


def detector_running():
    """The detector rewrites its status file every second while it runs."""
    try:
        fresh = time.time() - os.stat(DETECT_STATE).st_mtime < 10
    except OSError:
        return False
    return fresh and "\nstatus=running\n" in "\n" + read_file(DETECT_STATE)


def js(text):
    """A JSON string."""
    out = []
    for ch in str(text):
        if ch in '"\\':
            out.append("\\" + ch)
        elif ord(ch) < 0x20:
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


# ----- MQTT 3.1.1 packets -----

def varint(n):
    out = bytearray()
    while True:
        digit, n = n % 128, n // 128
        out.append(digit | (0x80 if n else 0))
        if not n:
            return bytes(out)


def mstr(text):
    data = text.encode("utf-8") if isinstance(text, str) else text
    return len(data).to_bytes(2, "big") + data


def packet(kind, body):
    return bytes([kind]) + varint(len(body)) + body


def connect_packet(client_id, password):
    flags = 0x02 | 0x04 | 0x20  # clean session; a will, retained, at QoS 0
    payload = mstr(client_id) + mstr(TOPIC + "/status") + mstr("offline")
    if USER:
        flags |= 0x80
        payload += mstr(USER)
        if password:
            flags |= 0x40
            payload += mstr(password)
    return packet(0x10, mstr("MQTT") + bytes([4, flags]) + KEEPALIVE.to_bytes(2, "big") + payload)


def publish_packet(topic, payload, retain):
    return packet(0x30 | (1 if retain else 0), mstr(topic) + payload.encode("utf-8"))


PINGREQ = b"\xc0\x00"


class Broker:
    def __init__(self):
        self.sock = None
        self.out = b""
        self.inbuf = b""
        self.last_sent = self.ping_sent = 0.0
        self.published = 0
        self.since = 0

    def open(self):
        """Connects and waits for the broker's answer. Returns why it failed, or "" when connected."""
        # As bytes: the camera's Python reads text files as ASCII, and a password may be any UTF-8.
        password = read_file(PASSWORD_FILE, b"", "rb").rstrip(b"\n")
        # Whole: a broker drops a client when another connects with the same ID.
        client_id = "vaidk-" + NAME
        sock = None
        try:
            family, kind, proto, _, address = _socket.getaddrinfo(HOST, PORT, 0, _socket.SOCK_STREAM)[0]
            sock = _socket.socket(family, kind, proto)
            sock.settimeout(TIMEOUT)
            sock.connect(address)
            sock.sendall(connect_packet(client_id, password))
            answer = b""
            while len(answer) < 4:
                data = sock.recv(4 - len(answer))
                if not data:
                    raise OSError(errno.ECONNRESET, "the broker closed the connection")
                answer += data
        except (OSError, IndexError) as e:
            if sock is not None:
                sock.close()
            reason = getattr(e, "strerror", None) or str(e) or e.__class__.__name__
            return "can't reach %s:%d: %s" % (HOST, PORT, reason)
        if answer[0] != 0x20 or answer[3] != 0:
            sock.close()
            return CONNACK_ERRORS.get(answer[3], "the broker refused the connection (%d)" % answer[3])
        sock.setblocking(False)
        self.sock, self.out, self.inbuf = sock, b"", b""
        self.last_sent = time.monotonic()
        self.ping_sent = 0.0
        self.since = int(time.time())
        return ""

    def close(self):
        if self.sock is not None:
            self.sock.close()
        self.sock, self.out = None, b""

    def publish(self, topic, payload, retain=False):
        if self.sock is not None:
            self.out += publish_packet(topic, payload, retain)
            self.published += 1

    def flush(self):
        """Sends what it can; False when the connection is gone."""
        try:
            while self.out:
                sent = self.sock.send(self.out)
                self.out = self.out[sent:]
                self.last_sent = time.monotonic()
        except OSError as e:
            return e.errno in (errno.EAGAIN, errno.EWOULDBLOCK)
        return True

    def receive(self):
        """Reads the broker's packets (only ping answers are expected); False when it hung up."""
        try:
            data = self.sock.recv(4096)
        except OSError as e:
            return e.errno in (errno.EAGAIN, errno.EWOULDBLOCK)
        if not data:
            return False
        self.inbuf += data
        while len(self.inbuf) >= 2:
            length, shift, i = 0, 0, 1
            while i < len(self.inbuf):
                length |= (self.inbuf[i] & 0x7F) << shift
                shift += 7
                i += 1
                if not self.inbuf[i - 1] & 0x80:
                    break
            else:
                return True
            if len(self.inbuf) < i + length:
                return True
            if self.inbuf[0] == 0xD0:  # PINGRESP
                self.ping_sent = 0.0
            self.inbuf = self.inbuf[i + length:]
        return True

    def keepalive(self):
        """Pings when idle; False when the broker stopped answering."""
        now = time.monotonic()
        if self.ping_sent and now - self.ping_sent > KEEPALIVE:
            return False
        if not self.ping_sent and now - self.last_sent > KEEPALIVE / 2:
            self.out += PINGREQ
            self.ping_sent = now
        return True


# ----- what the detector reports -----

class Seen:
    def __init__(self):
        # Object (with underscores) -> how many are in view; out of view when absent. Starts from the
        # detector's status file, in case something is in view already.
        self.counts = {}
        if detector_running():
            for line in read_file(DETECT_STATE).splitlines():
                if line.startswith("present="):
                    for item in line[8:].split(","):
                        parts = item.rsplit(" ", 1)
                        if len(parts) == 2 and parts[1].isdigit():
                            self.counts[parts[0].replace(" ", "_")] = int(parts[1])

    def publish_all(self, broker):
        for label in OBJECTS:
            self.publish(broker, label)

    def publish(self, broker, label):
        count = self.counts.get(label, 0)
        broker.publish("%s/%s" % (TOPIC, label), "ON" if count else "OFF", True)
        broker.publish("%s/%s/count" % (TOPIC, label), str(count), True)

    def clear(self, broker):
        """Nothing is in view: the detector started again, or isn't running."""
        labels, self.counts = list(self.counts), {}
        for label in labels:
            self.publish(broker, label)

    def handle(self, data, broker):
        """One event from the detector: "reset" when it starts; else "time T", then any
        "state LABEL ON|OFF COUNT" and "object LABEL CONFIDENCE X Y WIDTH HEIGHT" lines (positions in
        ten-thousandths)."""
        when, objects = None, []
        for line in data.decode("utf-8", "replace").splitlines():
            parts = line.split()
            try:
                if parts[0] == "reset":
                    self.clear(broker)
                elif parts[0] == "time" and len(parts) == 2:
                    when = float(parts[1])
                elif parts[0] == "state" and len(parts) == 4:
                    label, count = parts[1], int(parts[3]) if parts[2] == "ON" else 0
                    if count:
                        self.counts[label] = count
                    else:
                        self.counts.pop(label, None)
                    self.publish(broker, label)
                elif parts[0] == "object" and len(parts) == 7:
                    v = [int(p) for p in parts[2:]]
                    objects.append('{"label":%s,"confidence":%d,"x":%.2f,"y":%.2f,"width":%.2f,"height":%.2f}'
                                   % (js(parts[1].replace("_", " ")), v[0], v[1] / 100.0, v[2] / 100.0,
                                      v[3] / 100.0, v[4] / 100.0))
            except (IndexError, ValueError):
                continue
        if when is not None:
            broker.publish(TOPIC + "/detections", '{"time":%.3f,"objects":[%s]}' % (when, ",".join(objects)))


# ----- Home Assistant discovery -----

def discovery(broker):
    """Announces this camera's sensors, and removes the ones announced before that are no longer
    wanted. DISCOVERY_FILE remembers what was announced ("NODE LABEL,LABEL"); it is written to the
    flash only when that changes."""
    node = "vaidk_" + re.sub(r"[^a-z0-9_]", "_", NAME.lower())
    old = read_file(DISCOVERY_FILE).split()
    old_node, old_labels = (old[0], old[1].split(",")) if len(old) == 2 else ("", [])
    wanted = OBJECTS if DISCOVERY else []
    for label in old_labels:
        if old_node != node or label not in wanted:
            broker.publish("homeassistant/binary_sensor/%s/%s/config" % (old_node, label), "", True)
            broker.publish("homeassistant/sensor/%s/%s_count/config" % (old_node, label), "", True)
    device = '{"identifiers":[%s],"name":%s,"manufacturer":"Microsoft","model":"Vision AI DevKit"}' % (
        js(node), js(NAME))
    available = js(TOPIC + "/status")
    for label in wanted:
        name = label.replace("_", " ")
        name = name[:1].upper() + name[1:]
        broker.publish("homeassistant/binary_sensor/%s/%s/config" % (node, label),
                       '{"name":%s,"unique_id":%s,"state_topic":%s,"payload_on":"ON","payload_off":"OFF",'
                       '"device_class":"occupancy","availability_topic":%s,"device":%s}'
                       % (js(name), js("%s_%s" % (node, label)), js("%s/%s" % (TOPIC, label)), available, device),
                       True)
        broker.publish("homeassistant/sensor/%s/%s_count/config" % (node, label),
                       '{"name":%s,"unique_id":%s,"state_topic":%s,"state_class":"measurement",'
                       '"availability_topic":%s,"device":%s}'
                       % (js(name + " count"), js("%s_%s_count" % (node, label)),
                          js("%s/%s/count" % (TOPIC, label)), available, device), True)
    record = "%s %s\n" % (node, ",".join(wanted)) if wanted else ""
    if record != read_file(DISCOVERY_FILE):
        if record:
            write_file(DISCOVERY_FILE, record)
        elif os.path.exists(DISCOVERY_FILE):
            os.remove(DISCOVERY_FILE)


def main():
    try:
        os.remove(EVENTS)
    except OSError:
        pass
    events = _socket.socket(_socket.AF_UNIX, _socket.SOCK_DGRAM)
    events.bind(EVENTS)
    os.chmod(EVENTS, 0o600)
    events.setblocking(False)
    broker, seen = Broker(), Seen()
    attempt, retry_at, error, logged = 0, 0.0, "", ""
    shown, shown_at, checked = "", 0.0, 0.0
    log("publishing to %s:%d under %s/: %s; Home Assistant discovery %s"
        % (HOST, PORT, TOPIC, ",".join(OBJECTS), "on" if DISCOVERY else "off"))
    while True:
        now = time.monotonic()
        if broker.sock is None and now >= retry_at:
            error = broker.open()
            if error:
                retry_at = now + BACKOFF[min(attempt, len(BACKOFF) - 1)]
                attempt += 1
            else:
                attempt = 0
                broker.publish(TOPIC + "/status", "online", True)
                discovery(broker)
                seen.publish_all(broker)
            message = error or "connected to %s:%d" % (HOST, PORT)
            if message != logged:
                log(message)
                logged = message
        readers = [events] + ([broker.sock] if broker.sock is not None else [])
        writers = [broker.sock] if broker.sock is not None and broker.out else []
        readable, _, _ = select.select(readers, writers, [], 1.0)
        if events in readable:
            while True:
                try:
                    data = events.recv(8192)
                except OSError:
                    break
                seen.handle(data, broker)
        # A detector that stopped can't say that what it saw has gone.
        if seen.counts and time.monotonic() - checked > 1:
            checked = time.monotonic()
            if not detector_running():
                seen.clear(broker)
        if broker.sock is not None:
            alive = broker.keepalive()
            if alive and broker.sock in readable:
                alive = broker.receive()
            if alive and broker.out:
                alive = broker.flush()
            if alive and len(broker.out) > 1 << 20:  # the broker stopped reading: start afresh
                alive = False
            if not alive:
                broker.close()
                error = logged = "lost the connection to %s:%d" % (HOST, PORT)
                log(error)
                retry_at = time.monotonic() + BACKOFF[0]
        # The setup page's view: rewritten when it changes, and every 10 s for the message count.
        state = "status=%s\nerror=%s\nbroker=%s:%d\ntopic=%s\nsince=%d\n" % (
            "connected" if broker.sock is not None else "error" if error else "connecting", error, HOST, PORT,
            TOPIC, broker.since)
        if state != shown or time.monotonic() - shown_at > 10:
            write_file(STATE, state + "published=%d\n" % broker.published)
            shown, shown_at = state, time.monotonic()


if __name__ == "__main__":
    main()
