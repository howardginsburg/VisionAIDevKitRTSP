# Status lights

The camera's three red and green lights (`/sys/class/leds/led1` to `led3`) are driven by the vendor's
controller, `altekflow`, which also handles the power button and the battery's over-temperature
shutdown. The add-on leaves `altekflow` as it is and changes what one of its inputs reports, so that
its "IoT Hub connected" light means "streaming". What each light means is in the
[README](../../README.md#status-lights).

| File | What it is |
|---|---|
| [docker](docker) | A stand-in for the `docker` command, found first on `altekflow`'s `PATH` |

## How altekflow decides

| Input | Set by | Lights |
|---|---|---|
| Setup network or Wi-Fi client (`persist.wifi.property.mode`) | The boot script | Blinking red in setup mode |
| Wi-Fi connected (`persist.wifi.station.status`) | The vendor's `wifimonitor`, restarted by [`wifi.sh boot`](../wifi/README.md) | Amber while not connected |
| "IoT Hub connected" | `altekflow` itself, periodically: `docker ps \| awk '{ if ( $2~"mcr.microsoft.com/azureiotedge-agent" ) print "found" }' > /var/run/IotHub_connstate.txt` | Solid green when found, blinking green otherwise |

On the stock camera the last one means Azure IoT Edge's agent container is running. The add-on runs
no containers, so without the stand-in the lights would never turn solid green.

## The stand-in

The [boot script](../boot/README.md) starts `altekflow` with `/opt/vaidk/lights` first on its `PATH`,
so `altekflow` runs this `docker` script instead of `/usr/bin/docker`:
- **`docker ps`** with no other arguments: runs the real `docker ps`, then adds a line naming an
  `azureiotedge-agent` image when both are true:
  - `/run/vaidk/streaming` exists: the [RTSP server](../rtsp/README.md#status) is receiving every
    enabled stream;
  - `wpa_supplicant` reports the Wi-Fi connection as `COMPLETED`.
- **Every other command** runs the real `docker` unchanged, including `altekflow`'s reset steps,
  which stop and delete containers and images.

Nothing else uses this script: only `altekflow`'s `PATH` includes its folder.

## Check it

```sh
PATH=/opt/vaidk/lights:$PATH docker ps | tail -n 1     # the added line while streaming
cat /var/run/IotHub_connstate.txt                       # "found" when altekflow shows solid green
tr '\0' '\n' < /proc/$(pidof altekflow)/environ | grep ^PATH=
```
