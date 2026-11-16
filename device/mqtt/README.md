# MQTT

`vaidk-mqtt.service` runs [mqtt.sh](mqtt.sh), which starts `mqttd.py`: it publishes what the
[object detector](../detect/README.md) sees to your MQTT broker, for Home Assistant, Node-RED and the
like. It runs only while MQTT is on (`MQTT=1`), a broker is set and object detection is on.

| File | What it is |
|---|---|
| [mqttd.py](mqttd.py) | The MQTT client: receives the detector's events, publishes them, keeps the connection |
| [mqtt.sh](mqtt.sh) | Starts it with the settings, or exits when MQTT, the broker or detection is missing |
| [vaidk-mqtt.service](vaidk-mqtt.service) | systemd unit: starts at boot, and again 5 s after a failure |

## Topics

Under `MQTT_TOPIC`, by default `vaidk/<camera name>`:

| Topic | Payload | Retained |
|---|---|---|
| `status` | `online` once connected; `offline` when the service stops, the camera loses power or the network goes (the broker sends it, as the connection's last will) | Yes |
| `<object>` | `ON` while the object is in view, `OFF` 3 s after it was last seen | Yes |
| `<object>/count` | How many are in view, `0` when none | Yes |
| `detections` | After each analysis while a chosen object is in view, then once with none: `{"time":1794855704.144,"objects":[{"label":"person","confidence":74,"x":1.25,"y":21.11,"width":75.31,"height":78.61}]}`. Time in Unix seconds; confidence in percent; position and size in percent of the picture | No |

- **Objects** are the ones chosen in the setup page's **Object detection** section, with an underscore
  for a space: `vaidk/vision-ai-devkit/teddy_bear`.
- **Counts don't flicker:** a rise counts at once, a fall once the lower count has held for 3 s, so a
  second person missed in an analysis or two doesn't bounce the count.
- **Restarts:** when the detector starts again, or stops updating its status (it rewrites it every
  second), whatever was in view is published as gone. On every connection the service publishes
  `status` and every object's state again, so a broker that restarted gets them back.
- **QoS 0**, MQTT 3.1.1. The client ID is `vaidk-<camera name>`. Give each camera a name of its own:
  a broker disconnects a client when another connects with the same ID, and the topics would mix.

## Home Assistant discovery

With **Add a sensor for each object to Home Assistant** ticked (`MQTT_DISCOVERY=1`), the service
announces, for each chosen object, on one device named after the camera:
- a binary sensor, `homeassistant/binary_sensor/vaidk_<name>/<object>/config`: occupancy, from
  `<object>`;
- a count sensor, `homeassistant/sensor/vaidk_<name>/<object>_count/config`, from `<object>/count`.

Both use `status` for their availability. Announcements are retained. When an object is no longer
chosen, or discovery is turned off, the service removes what it announced before (an empty retained
message), the next time it connects. It remembers what it announced in
`/data/misc/vaidk/mqtt-discovery`, written only when that changes. To remove the sensors, turn
discovery off and save while MQTT is still on.

## Connection

- **Broker:** a name or address, and a port (1883 by default).
- **Sign-in:** a user name and password, or none. The password is kept apart from the settings, in
  `/data/misc/vaidk/mqtt-password`, which only root can read. Without a user name no password is sent,
  and saving one deletes it.
- **No TLS.** The camera's Python has no `ssl` module. The password and the messages cross your
  network unencrypted, like the streams.
- **Reconnects** 5, 10, 30, then every 60 s after a failure. The broker's answer is shown on the setup
  page: wrong user name or password, not authorised, and so on.
- **Keep-alive** 60 s: when nothing has been sent for 30 s it pings, and it reconnects if the broker
  hasn't answered within a minute. If the broker stops reading and more than 1 MB waits to be sent, it
  reconnects too.

## How events arrive

The detector sends text datagrams to `/run/vaidk/events.sock`, which the service binds when it starts:
`reset` when the detector starts; then `time T`, `object LABEL CONFIDENCE X Y WIDTH HEIGHT` (in
ten-thousandths of the picture) and `state LABEL ON|OFF COUNT` lines. When nothing listens, the
detector's datagrams go nowhere: it never waits for the service.

## Settings it uses

| Setting | Default | Meaning |
|---|---|---|
| `MQTT` | `0` | `1`: publish |
| `MQTT_HOST`, `MQTT_PORT` | empty, `1883` | The broker |
| `MQTT_USER` | empty | User name; empty for none |
| `MQTT_TOPIC` | empty | Topic prefix; empty means `vaidk/<NAME>` |
| `MQTT_DISCOVERY` | `0` | `1`: Home Assistant discovery |
| `DETECT`, `DETECT_OBJECTS` | | The service runs only with detection on, and publishes the chosen objects |
| `NAME` | | The default topic, the client ID, and Home Assistant's device |

The setup page restarts the service when it saves the MQTT section, turns detection on or off,
changes the objects or renames the camera.

## Logs and checks

```sh
journalctl -u vaidk-mqtt --no-pager -n 20     # the broker and topic at start, connections, errors
cat /run/vaidk/mqtt.state                     # status, error, broker, topic, since, messages sent
```

From a computer with the Mosquitto clients: `mosquitto_sub -h <broker> -u <user> -P <password> -t 'vaidk/#' -v`.

It costs about 0.5% of one core and 6 MB of memory while detections are published 5 times a second,
and writes nothing to the flash unless the discovery announcements change.

## Why it is written this way

Like the [RTSP server](../rtsp/README.md#why-python-and-how), it runs on the camera's Python 3.5.3,
which has no `socket`, `ssl`, `threading`, `signal` or `json` modules. So it speaks MQTT over `_socket`
and `select`, writes its few packet types and its JSON by hand, and stops when systemd ends it: the
broker then sends the last will.
