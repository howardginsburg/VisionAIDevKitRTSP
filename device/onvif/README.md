# Pan, tilt and zoom (ONVIF)

`vaidk-onvif.service` runs `onvifd.py`, a small ONVIF service. Frigate, Home Assistant and NVRs find
the camera's streams through it, and pan, tilt and zoom the picture. The pan, tilt and zoom are
digital: the camera crops its 4K sensor picture, and both streams are scaled from the crop.

| File | What it is |
|---|---|
| [onvifd.py](onvifd.py) | The ONVIF service, and the view and presets it keeps |
| [onvif.sh](onvif.sh) | Starts it with the settings. With `ONVIF=0` it shows the whole picture and exits |
| [vaidk-onvif.service](vaidk-onvif.service) | systemd unit: starts after the camera service, and again 2 s after a failure |

## What it offers

SOAP 1.2 over HTTP on port 8080 (`ONVIF_PORT`), without sign-in. WS-Security headers are ignored.

| Address | Service | Operations |
|---|---|---|
| `/onvif/device_service` | Device | `GetServices`, `GetCapabilities`, `GetDeviceInformation`, `GetSystemDateAndTime`, `GetNetworkInterfaces`, `GetScopes`, `GetHostname`, `GetServiceCapabilities` |
| `/onvif/media_service` | Media (ver10) | `GetProfiles`, `GetProfile`, `GetStreamUri`, `GetVideoSources`, `GetVideoSourceConfigurations`, `GetVideoEncoderConfigurations`, `GetServiceCapabilities` |
| `/onvif/ptz_service` | PTZ (ver20) | `GetNodes`, `GetNode`, `GetConfigurations`, `GetConfiguration`, `GetConfigurationOptions`, `GetStatus`, `GetPresets`, `SetPreset`, `RemovePreset`, `GotoPreset`, `GotoHomePosition`, `SetHomePosition`, `ContinuousMove`, `RelativeMove`, `AbsoluteMove`, `Stop`, `GetServiceCapabilities` |

- **Profiles.** `main`, and `sub` when the sub stream is on, each with its stream's encoder settings
  and the same PTZ configuration. `GetStreamUri` returns `rtsp://<camera-ip>:8900/live` or `:8901/live`.
- **Not offered:** imaging, events, snapshots, users and Media2. Other operations, and
  `GetSnapshotUri`, answer with a SOAP fault; Frigate and Home Assistant carry on without them, and
  take stills from the stream.
- **Any address.** A request sent to another service's address is answered anyway, since some
  clients send everything to one address.
- **Limits.** Requests up to 64 KB. A connection that hasn't sent a whole request within 15 s is
  closed.

## The view

- **Position.** Pan and tilt run from -1 to 1 (tilt 1 is the top), zoom from 0 (the whole picture)
  to 1 (4x). The zoom factor is 4 to the power of zoom, so equal steps look alike. Pan and tilt place
  the view within the room the zoom leaves: at the whole picture they move nothing, and at any zoom
  -1 and 1 put the view against the edges.
- **Spaces.** The generic position, translation and velocity spaces, and the field-of-view
  translation space (`TranslationSpaceFov`) that Frigate's click-to-move uses: 1 moves the view by
  half its width, so the clicked edge comes to the centre.
- **Continuous moves.** At full speed the zoom goes from 1x to 4x in 2 s and the view pans its own
  width each second; Frigate's buttons use half speed. A move runs until `Stop` or its timeout (30 s
  unless the request gives one, from 1 s to 1 minute), and covers the time between the camera
  receiving the move and the `Stop`.
- **`Stop` ends every movement**, whatever its `PanTilt` and `Zoom` flags say, as many cameras do:
  Home Assistant ends a timed continuous zoom with `Zoom=false`, which would otherwise zoom all the
  way in.
- **Instant moves.** `RelativeMove`, `AbsoluteMove` and `GotoPreset` ignore their speeds.
- **Presets.** Up to 16, named. `SetPreset` with a name or token already in use updates that preset.
  The home position is the whole picture until `SetHomePosition`.
- **Kept.** The position, home and presets are in `/data/misc/vaidk/ptz`, so they survive restarts.
  **Reset camera** clears them.

## How a move reaches the picture

- `onvifd.py` writes the position to `/run/vaidk/ptz.conf` as the crop `vaidk-camd` applies, then
  sends `vaidk-camd` `SIGUSR2`. For example, 2x zoom with pan 0.5 and tilt 0.5:

  ```text
  ZOOM=2.0000
  ZOOM_X=75.00
  ZOOM_Y=25.00
  ```

  `ZOOM` is the factor; `ZOOM_X` and `ZOOM_Y` place the crop from 0 (left or top) to 100 (right or
  bottom).
- `vaidk-camd` sets the camera's crop region on the running camera. Both streams follow without a
  restart or a dropped frame ([camd/README.md](../../camd/README.md#digital-pan-tilt-and-zoom)).
- `vaidk-camd` also reads the file when it starts, so the view survives a restart of the camera
  service. After a reboot, `onvifd.py` writes it again from what it kept.
- With `ONVIF=0`, `onvif.sh` deletes the file and signals `vaidk-camd`, which shows the whole
  picture.

## Detail and what the view changes

- **Detail.** The sensor picture is 3840x2160. At 2x, the 1080p main stream still gets one sensor
  pixel per stream pixel; beyond that, the zoom enlarges pixels. The camera itself would go to 8x;
  the service stops at 4x. A 4K main stream enlarges pixels at any zoom.
- **Both streams show the view.** Frigate records and detects what the view shows, not the whole
  picture. Zones and masks are drawn on the picture, so they don't follow a zoom.

## The setup page

The setup page's **Pan, tilt and zoom** section turns the service on or off, shows the whole
picture, and goes to, deletes or saves presets; Frigate can go to presets but not save them. It asks
`onvifd.py` at `http://127.0.0.1:8080/local/ptz`, which answers only the camera itself (`403`
otherwise):

| Request | Does |
|---|---|
| `/local/ptz` | Nothing; lists the position and presets |
| `?do=full` | Shows the whole picture, keeping pan and tilt for the next zoom |
| `?do=home` | Goes to the home position |
| `?do=goto&token=T` | Goes to preset `T` |
| `?do=save&name=N` | Saves the view as preset `N`, or updates the preset called `N` (`409` when 16 are saved) |
| `?do=delete&token=T` | Deletes preset `T` |

Each answers with text lines: `zoom=2.00`, `pan=0.500`, `tilt=0.500`, then `preset=TOKEN NAME` for
each preset.

## Settings it uses

| Setting | Default | Meaning |
|---|---|---|
| `ONVIF` | `1` | `1`: run the service. `0`: stop it and show the whole picture |
| `ONVIF_PORT` | `8080` | Its TCP port |

Both apply when the service restarts; the setup page restarts it when you turn it on or off.

## Logs and checks

```sh
journalctl -u vaidk-onvif --no-pager -n 20                 # start-up: port, zoom and presets; errors
cat /run/vaidk/ptz.conf                                    # the crop vaidk-camd applies
busybox wget -q -O - http://127.0.0.1:8080/local/ptz      # position and presets
```

## Why it is written this way

Like the [RTSP server](../rtsp/README.md#why-python-and-how), it runs on the camera's Python 3.5.3,
whose standard library has no `socket`, `threading`, `xml` or `json` modules. So it serves HTTP with
`_socket` and `select` in one loop, reads each request's operation and values with regular
expressions, and answers from fixed templates. It was tested against the ONVIF code of Frigate 0.18
and Home Assistant ([PROVENANCE.md](../../PROVENANCE.md#pan-tilt-and-zoom)).
