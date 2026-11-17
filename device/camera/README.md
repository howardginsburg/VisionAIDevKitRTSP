# Camera

`vaidk-camera.service` runs the camera program, `vaidk-camd`, with the saved settings. The program
drives the camera sensor, the video encoders, the microphone and the speaker through Qualcomm's
camera service (`qmmf-server`), applies the picture settings, the digital pan, tilt and zoom, and the
on-screen text, hands the encoded streams to the [RTSP server](../rtsp/README.md) and, with
[HDMI live view](#hdmi-live-view) on, shows the main stream on the HDMI port. How the program itself
works, and how to build it, is in [camd/README.md](../../camd/README.md).

| File | What it is |
|---|---|
| [camd.sh](camd.sh) | Start script: prepares the camera, then runs `vaidk-camd` with the settings. Also `camd.sh reload`, `chime` and `tz` (below) |
| [mic.sh](mic.sh) | Sets the microphone gain once the camera is streaming |
| `vaidk-camd` | The camera program, built from [camd/](../../camd/README.md) |
| [vaidk-camera.service](vaidk-camera.service) | systemd unit: restarts the program 3 s after it exits |
| [init_display-vaidk.conf](init_display-vaidk.conf) | Drop-in for the vendor's display server: it runs only while live view is on |
| [weston.ini](weston.ini) | The display server's settings for live view: a black background |

## Start-up

1. If `STOP_IPC_WEBSERVER=1`, stops the vendor preview server (`ipc-webserver`), which would compete
   for the camera.
2. Starts the vendor's display server (weston) with live view on, or stops it with live view off, and
   sets whether the camera service keeps its frames compressed ([HDMI live view](#hdmi-live-view)).
3. Waits for the vendor media server's audio calibration. About 5 s after `qmmf-webserver` starts, it
   runs a one-off audio calibration (`http_interface_gtest ... INIT_AUDIO_ACDB`) that holds the
   microphone, and a microphone track created meanwhile fails. `camd.sh` waits until
   `qmmf-webserver` has run for 20 s and the calibration has finished, for up to 40 s. The vendor
   server stays otherwise idle: nothing else uses it. With live view on, it also waits for weston's
   socket, for up to 20 s.
4. Writes the live settings file, `/run/vaidk/camd.conf`, and runs `vaidk-camd` with the other
   settings as environment variables. It creates every track (main video with the microphone, the sub
   video, then the copies for object detection and live view), starts them, applies the picture
   settings and the view kept by the [ONVIF service](../onvif/README.md) (`/run/vaidk/ptz.conf`), adds
   the on-screen text and, with talk-back on, opens the talk-back socket.
5. Once the streams are running, `vaidk-camd` runs `mic.sh`, which applies the microphone gain.

The streams start about 30 s into boot. If the camera pipeline fails or any stream stops
delivering frames for 10 s, `vaidk-camd` exits and systemd starts it again with a fresh camera
session. Players stay connected to the RTSP server meanwhile and pick up again at the next keyframe.

## Commands

| Command | What it does | Used by |
|---|---|---|
| `camd.sh reload` | Rewrites `/run/vaidk/camd.conf` from the settings and sends `vaidk-camd` `SIGHUP`, which applies the picture, speaker and object-detection settings without restarting the streams | The setup page's **Picture**, **Talk-back** and **Object detection** sections |
| `camd.sh chime` | Sends `vaidk-camd` `SIGUSR1`, which plays a short chime on the speaker | **Test speaker** |
| `camd.sh tz` | Puts `TIME_ZONE` into `qmmf-server`'s environment and restarts `qmmf-server` if it changed ([Time zone](#time-zone)) | **On-screen text**, and the installer |

The [ONVIF service](../onvif/README.md) moves the view itself: it writes `/run/vaidk/ptz.conf` and
sends `vaidk-camd` `SIGUSR2`.

`camd.sh` ignores `SIGHUP`, `SIGUSR1` and `SIGUSR2` until `vaidk-camd` takes them over, so a reload,
chime or move during start-up doesn't stop the service. It ignores them rather than trapping them
because an ignored signal stays ignored across `exec`, while a trapped one would go back to its
default, which ends the program, until `vaidk-camd` sets its handlers.

## Settings it uses

Defaults are in [defaults.conf](../defaults.conf). The setup page changes them, then either restarts
this service or, for the live settings, runs `camd.sh reload`.

| Setting | Effect | Applies |
|---|---|---|
| `MAIN_WIDTH`, `MAIN_HEIGHT`, `MAIN_FPS`, `MAIN_BITRATE` | Main stream resolution, frame rate and bitrate (bits/s) | Restart |
| `MAIN_CODEC` | Main stream codec: `1` H.264, `0` H.265 | Restart |
| `SUB_ENABLED`, `SUB_WIDTH`, `SUB_HEIGHT`, `SUB_FPS`, `SUB_BITRATE` | Sub stream on or off, and its resolution, frame rate and bitrate. Always H.264 | Restart |
| `AUDIO_ENABLED`, `AUDIO_BITRATE` | Microphone on the main stream, and its AAC bitrate | Restart |
| `AUDIO_GAIN_DB` | Microphone gain, 0 to 40 dB (`mic.sh`) | Restart |
| `KEYFRAME_SECONDS` | Seconds between keyframes, both streams. The encoder adds a frame: at 1 s, keyframes come every 31 frames at 30 fps and every 6 at 5 fps | Restart |
| `ANTIFLICKER`, `EXPOSURE_EV`, `WHITE_BALANCE`, `SATURATION`, `SHARPNESS` | Picture: anti-flicker (`auto`, `60`, `50`, `off`), exposure (-2 to 2 EV), white balance, colour (0 to 10) and sharpness (0 to 6) | Live |
| `OVERLAY`, `OVERLAY_POSITION`, `OVERLAY_STREAMS`, `NAME` | On-screen text: `off`, `time`, `name` or `time-name`; the corner for the date and time; `main` or `both`; the camera name it shows | Restart |
| `TIME_ZONE` | POSIX time zone of the on-screen clock, e.g. `EST5EDT,M3.2.0,M11.1.0` | `camd.sh tz` |
| `TALKBACK` | `1`: offer the talk-back channel and play it on the speaker | Restart |
| `SPEAKER_VOLUME` | Speaker volume, 0 to 100, on an audio taper | Live |
| `TALKBACK_MUTE_MIC` | `1`: mute the microphones while the speaker plays | Live |
| `DETECT` | `1`: hand copies of the sub stream's frames to the [object detector](../detect/README.md) and draw its boxes on the main stream. Needs the sub stream on at 640x360 | Restart |
| `DETECT_FPS`, `DETECT_BOXES` | Frames a second for the detector (at most the sub stream's frame rate); `0` hides the boxes | Live |
| `HDMI` | `1`: show the main stream on the HDMI port ([HDMI live view](#hdmi-live-view)); `0` keeps the vendor's display server off | Restart |
| `STOP_IPC_WEBSERVER` | Keep the vendor preview server stopped | Restart |

Tested combinations:

| Main stream | Sub stream |
|---|---|
| 1920x1080 at 15 or 30 fps, up to 8 Mbps, H.264 or H.265 | 640x360 or 1280x720, 5 or 10 fps |
| 3840x2160 at 30 fps, 8 Mbps, H.264 or H.265 | 1280x720, 5 or 10 fps |

With object detection on, the sub stream is 640x360; detection was tested with it at 5 and 10 fps.
Live view was tested with the main stream at 1920x1080 and at 3840x2160, H.264 at 30 fps, with the
on-screen text and detection boxes.

The on-screen text was tested at 1080p and at 4K, and the streams kept their frame rates. At 1080p
it made no measurable difference to `qmmf-server`'s CPU use, about 20% of the camera's two cores
with it on or off; at 4K with the text on, `qmmf-server` used about 24%.

The setup page offers only sizes from 640x360 up: a 320x180 track made `qmmf-server` crash. The
image can't be rotated or flipped on this firmware.

## Time zone

`qmmf-server` draws the on-screen date and time from its own clock, in the time zone in its `TZ`
environment variable. The camera has no time zone database, so `TIME_ZONE` is a POSIX string
(`UTC0`, `CET-1CEST,M3.5.0,M10.5.0/3` and so on). `camd.sh tz` writes it into a systemd drop-in,
`/lib/systemd/system/qmmf-server.service.d/vaidk.conf`, which lives on the read-only root file
system and so survives restarts:

```ini
[Service]
Environment=TZ=EST5EDT,M3.2.0,M11.1.0
```

When the value changes, it reloads systemd and restarts `qmmf-server`; `vaidk-camd` notices, exits
and starts again. The installer writes the drop-in, and uninstalling removes it. The camera sets its
clock with NTP (`chronyd`), so the time is only right once it has been online.

## HDMI live view

With `HDMI=1`, `vaidk-camd` shows the main stream full screen on a monitor plugged into the camera's
HDMI port.

- **Hardware.** The processor's display output (DSI) feeds a Lontium LT9611 bridge, which drives the
  HDMI port. The bridge neither detects a monitor nor reads what it supports (EDID): it always sends
  1920x1080 at 60 Hz.
- **Display server.** The vendor's `init_display.service` starts weston 1.9, which drives that
  output. The vendor kept it running all the time, an empty desktop that cost about 0.8 W. The
  installer adds a drop-in, [init_display-vaidk.conf](init_display-vaidk.conf), that lets it start
  only while `/run/vaidk/hdmi-on` exists and points weston at [weston.ini](weston.ini) (a black
  background). At every start, `camd.sh` creates that file and starts weston when `HDMI=1`, or removes
  it and stops weston, which turns the output off.
- **Frames.** `vaidk-camd` creates a track that copies the main stream's frames, uncompressed, at its
  size up to 1920x1080 (the camera scales a 4K stream down). It hands each frame to Qualcomm's display
  client (`libqmmf_display_client`), which copies it into a buffer of its own and passes it to weston;
  weston shows it on a display plane, scaled to the screen. The copies carry the main stream's
  on-screen text and detection boxes: `qmmf-server` draws them before passing the frames on.
- **Uncompressed frames.** `qmmf-server` keeps the streams' frames in the encoders' compressed format
  (UBWC), which a copy can't read, unless the saved property `persist.qmmf.ubwcstream.enable` is `0`.
  `camd.sh` sets it to `0` with live view on, and back to `1` without, before `vaidk-camd` starts;
  `qmmf-server` reads it as it creates each stream. Uninstalling sets it back to `1`.
- **Cost.** At 1080p, about 7% of one processor core for `vaidk-camd`'s copies and 13% for weston; the
  power and the streams' frame rates didn't measurably change. With a 4K main stream, `qmmf-server`'s
  scaling adds about half a core (136% of a core instead of 87%).
- **If weston stops,** the display client's next frame aborts `vaidk-camd` (the camera's Wayland
  library gives up on a broken connection); systemd starts it again 3 s later, and `camd.sh` starts
  weston first. Live view was back 11 s after weston was killed.
- **Shutdown.** `vaidk-camera.service` is ordered after `init_display.service`, so the camera stops
  before the display server.

## The speaker

- **Hardware.** One small speaker, driven by a Qualcomm WSA881x smart amplifier on the codec's
  speaker output.
- **Path.** `vaidk-camd` plays talk-back audio with qmmf's player: 48 kHz mono PCM on the built-in
  speaker, through the audio DSP's offload path (about 250 ms from buffer to sound).
- **Volume.** `SPEAKER_VOLUME` sets the player's volume after squaring it (80 is about -4 dB, 50 about
  -12 dB), on top of +12 dB and a limiter applied to the incoming speech.
- **Microphones.** With `TALKBACK_MUTE_MIC=1`, the microphones are muted while the speaker plays and
  for 400 ms after: without it, the speaker comes back through them about 50 dB above the room's
  noise. The audio DSP's echo cancellation isn't reachable through `qmmf-server`.

## The microphone

- **Hardware.** The camera's audio codec is Qualcomm's WCD934x ("Tavil"). For a built-in microphone
  input, the audio driver picks its `dmic-endfire` path: two digital microphones, mixed to mono, with
  the audio DSP's echo and noise processing. Steady background noise is suppressed, so a quiet room
  sounds almost silent and voices come through clearly.
- **Format.** AAC-LC, 48 kHz, mono, at `AUDIO_BITRATE`.
- **Gain.** `mic.sh` sets the codec's digital decimators for the two microphones
  (`DEC7 Volume` and `DEC8 Volume`) to `84 + AUDIO_GAIN_DB`; 84 is 0 dB. At 0 dB the level is very
  low, so the gain starts at +24 dB. Check it with `tinymix get "DEC7 Volume"`.
- **Off.** With `AUDIO_ENABLED=0`, no microphone track is created and the main stream has video only.
  If the microphone track can't be created, the camera streams without audio and logs
  `microphone unavailable`.
- **Talk-back.** While the speaker plays, `vaidk-camd` sets both decimators to 0 (-84 dB), then puts
  the saved gain back ([The speaker](#the-speaker)).

## Logs and checks

```sh
journalctl -u vaidk-camera --no-pager -n 30      # start-up, restarts, and stream totals every 10 min
systemctl restart vaidk-camera                    # what "Restart streams" on the setup page does
cat /run/vaidk/rtsp.status                        # what the RTSP server receives from the camera
pidof weston; cat /tmp/weston.log                 # the display server, with live view on
```

| Log line | Meaning |
|---|---|
| `streaming: main=H264 1920x1080 30 4000000;sub=...;audio=AAC 48000 1 64000;clock=-854;talk=/run/vaidk/talk.sock;` | Running, with these streams; `talk` when talk-back is on. `clock` is explained in [camd/README.md](../../camd/README.md#output-the-media-socket) |
| `image: aeAntibandingMode=3, aeExposureCompensation=0, awbMode=1, use_saturation=5, strength=2` | The picture settings the camera kept, at start and after each reload |
| `zoom: 2.00x at 75% across, 25% down (crop 1448 272 1932 1090)` | The view it applied first after starting, and the crop on the sensor ([digital pan, tilt and zoom](../../camd/README.md#digital-pan-tilt-and-zoom)) |
| `zoom: <error>` | The camera refused a view; the streams carry on with the previous one |
| `connected to the RTSP server` | Sending to the RTSP server |
| `talk-back: speaker on (volume 80, microphones muted)` | Talk-back audio arrived and is playing |
| `talk-back: speaker off after 4.2 s` | A second without talk-back audio; the speaker track closed |
| `talk-back: failed to ...` | The speaker couldn't be opened; it tries again with the next audio |
| `no frames from the main stream for 10 s; restarting the camera` | A stall; systemd restarts it |
| `connected to the object detector`, `lost the object detector` | The link to [vaidk-detect](../detect/README.md) came up or went; it tries again every second. Boxes hide while it is down |
| `object detection needs the sub stream on at 640x360; streaming without it` | `DETECT=1`, but the sub stream is off or another size |
| `live view: 1920x1080 on the display server (weston)` | Live view is on, at this size |
| `live view: failed to connect to the display server (weston) (<code>)`, `streaming without live view` | weston didn't answer within 5 s; the streams run without live view. See `systemctl status init_display` and `/tmp/weston.log` |
| `camera service event 1 (server died)` | `qmmf-server` restarted; this program restarts too |
| `microphone unavailable; streaming without audio` | The microphone track couldn't be created |
| `main stream 3840x2160@30 H.265 rejected (<code>)` | `qmmf-server` refused that track. Choose another setting |
| `main overlay 0 failed (<code>)` | `qmmf-server` refused an on-screen text item (`0` date and time, `1` name, `4` label); the stream runs without it |
