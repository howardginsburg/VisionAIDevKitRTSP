# Provenance: how each feature works without Azure

The Vision AI DevKit was built for Azure: its setup finished in Azure IoT Hub, its lights reported
Azure IoT Edge, and its samples ran as IoT Edge modules. This document goes through the camera's
features one at a time:
- what stood in the way of each, on a camera that no longer reaches Azure;
- what the add-on does about it, and why that way;
- which files do it.

It ends with where every component comes from, and the licences. The camera as found is in
[ASSESSMENT.md](ASSESSMENT.md); how the pieces fit together is in [ARCHITECTURE.md](ARCHITECTURE.md).

Every piece of the add-on is one of three kinds:

| Kind | Meaning |
|---|---|
| **From the device** | The camera's own software: used where it is, or read from the camera while installing or building. Never committed to this repository |
| **Downloaded** | Fetched from a public upstream at a pinned version, and checked |
| **Authored** | Written for this project |

## Contents

- [Booting without IoT Hub](#booting-without-iot-hub)
- [Wi-Fi and the setup network](#wi-fi-and-the-setup-network)
- [Camera and microphone](#camera-and-microphone)
- [RTSP streams](#rtsp-streams)
- [Talk-back, picture and on-screen text](#talk-back-picture-and-on-screen-text)
- [Pan, tilt and zoom](#pan-tilt-and-zoom)
- [How it was tested](#how-it-was-tested)
- [Status lights](#status-lights)
- [Restart after a crash](#restart-after-a-crash)
- [Setup page and admin account](#setup-page-and-admin-account)
- [Installing over USB](#installing-over-usb)
- [Where every component comes from](#where-every-component-comes-from)
- [Licences and what must not be shared](#licences-and-what-must-not-be-shared)
- [Verify it yourself](#verify-it-yourself)

---

## Booting without IoT Hub

**Files**: `device/boot/make-initcamx.py`, `device/boot/InitCamx-vaidk.conf`. Authored. The boot
script they produce, `InitCamx.vaidk`, is built on each camera from that camera's own vendor script.

**In the way.** At every boot, `InitCamx.service` runs the vendor's `/vendor/etc/camera/InitCamx`, a
238-line bash script that prepares the camera libraries, Wi-Fi, the `/etc` overlay, Docker, the
vendor setup site and the LED controller.

| Finding | Where it was found |
|---|---|
| It joins a Wi-Fi network only when `/data/misc/websettings/setting.conf` exists, which the setup site writes after the IoT Hub step. Otherwise it opens the setup network | The script's Wi-Fi section |
| Its helper, `connectap`, writes a Wi-Fi configuration that `wpa_supplicant` can't parse | Running it on the camera |
| It starts the vendor setup site, `websettings`, on port 80 at every boot | `websettings&` in the script |
| At shutdown, `InitCamx stop` runs the whole boot sequence again: the script ignores its argument | The unit's `ExecStop`, and the script |
| It carries no licence | The file |

**What the add-on does.** It runs a copy of the vendor script with five changes, listed in
[device/boot/README.md](device/boot/README.md#what-changes). Chiefly, the Wi-Fi section joins the
saved network with the add-on's own [Wi-Fi script](#wi-fi-and-the-setup-network), and the vendor
setup site is left out. A systemd drop-in points `InitCamx.service` at the copy.
- **Built, not shipped.** The vendor script has no licence, so this repository holds only the edits.
  `make-initcamx.py` builds the copy on each camera, from that camera's own file, while installing.
- **Exactly as tested.** It checks the input's MD5 against the vendor script of v0.5370_Perf, applies
  each edit at an anchor that must appear exactly once, and checks the result's MD5 against the
  script tested on that firmware. Other firmware stops the install unless forced, and even then every
  anchor must be found exactly once.
- **The vendor file is never changed.** Uninstalling removes the drop-in, and the vendor script runs
  again from the next boot.
- **Everything else runs as the vendor wrote it**, in the same order: the camera libraries, the `/etc`
  overlay, Docker, and the LED controller, `altekflow`, which now finds the add-on's
  [status-light stand-in](#status-lights) first on its `PATH`.

| Option | Outcome |
|---|---|
| Write `setting.conf`, so that the vendor script joins the network | Rejected: `connectap` would still write a configuration `wpa_supplicant` can't parse, and the vendor setup site would still start at every boot |
| Edit the vendor script in place | Rejected: it is on the read-only root, and an exact uninstall would need a copy of the original, which can't be shipped |
| **A copy built on each camera, run through a drop-in** | Chosen |

## Wi-Fi and the setup network

**Files**: `device/wifi/wifi.sh`, `device/wifi/vaidk-wifi.service`. Authored. They drive the camera's
own `wpa_supplicant`, `udhcpc`, `wifimonitor`, `startvirtualsoftap`, `hostapd` and `dnsmasq`.

**In the way.**
- Without the vendor setup, nothing joins a Wi-Fi network ([above](#booting-without-iot-hub)).
- Without it, there is also no way to move the camera to another network, short of a USB cable.

**What the add-on does.**
- **Its own Wi-Fi configuration.** The setup page writes the `wpa_supplicant` configuration: the
  network name in hex, so any character works, and the WPA2 key as the hash `wpa_passphrase` derives,
  so the password itself is never stored.
- **The camera's tools, called directly.** `wifi.sh boot` starts `wpa_supplicant` and `udhcpc` with
  it, and restarts `wifimonitor` so the lights follow the connection.
- **The vendor's setup network, kept.** Its name and the password on the sticker stay the same, and
  its DNS already answers every name with the camera's address, which is what makes phones open a
  sign-in page.
- **A watchdog** opens the setup network alongside the Wi-Fi client when the saved network has been
  gone for 5 minutes, and closes it again once the network is back and nobody uses the setup network.
- **Joining a new network can roll back.** `wifi.sh try` saves the new network only once it has
  given the camera an address, and returns to the saved one if that doesn't happen within 45 s.

Details: [device/wifi/README.md](device/wifi/README.md).

| Obstacle | Fix |
|---|---|
| An address left from an earlier lease made the camera look connected | DHCP starts by removing the old address, and "connected" needs both an associated client and an address |
| Restarting the watchdog, or the web server that started a network change, would kill the Wi-Fi client and the setup network they had started | `KillMode=process` in both units, and `setsid` for what they start |
| The driver lists the camera's own `wlan0` among the setup network's stations, so the setup network never looked unused | The camera's own MAC address isn't counted |
| In setup mode no Wi-Fi client runs, so nothing can scan | `wifi.sh scan` starts a client without networks, to scan with |
| Scan results arrive one band at a time | `wifi.sh scan` collects them for 4 to 10 s |
| The setup page trusts the setup network's subnet, which a device on your network could otherwise claim | `net.sh` drops that subnet arriving over the Wi-Fi client, and `ui.sh` checks the client's address again |

## Camera and microphone

**Files**: `camd/camd.cpp`, `camd/common.h`, `camd/build.ps1`, `camd/android/`, and `device/camera/`
(`camd.sh`, `mic.sh`, the unit, and `vaidk-camd`, built from `camd/`). Authored.
`camd/third_party/qmmf-sdk/` is [downloaded](#downloaded). The program links against the camera's
own qmmf client libraries.

**On the stock camera**, Qualcomm's camera service, `qmmf-server`, ran the sensor, the encoders and
the microphones. Its clients were the vendor's media server, `qmmf-webserver` (RTSP, and an HTTP API
on port 4000 that the IoT Edge samples drove), and the preview server, `ipc-webserver` (port 1080).

**In the way.** Those two were the only way to get video and sound out, and neither suits an NVR:

| Problem | Effect |
|---|---|
| `qmmf-webserver` puts audio on RTSP only inside MPEG-TS, with a dynamic payload type (`a=rtpmap:96 MP2T/90000/2`) | ffmpeg, and so Frigate, can't play it |
| Its MPEG-TS packager cuts off video frames larger than about 200 KB | Corrupted keyframes at 1080p and above |
| It crashed ("buffer overflow detected") when clients connected or disconnected at awkward moments, or when its ports were probed | Streams stop until systemd restarts it |
| Its HTTP API on port 4000 has no authentication | Anyone on the network can reconfigure the camera |
| `ipc-webserver` (user `admin`, password `admin`) keeps a preview running only as long as the browser session that started it | No unattended streaming |

Underneath, `qmmf-server` has quirks that any client must handle: audio timestamps that run slow, a
stall when a stream is added to a running camera, and a crash on very small video tracks. Each, and
what the program does about it, is in [camd/README.md](camd/README.md#things-learned-about-qmmf).

**What the add-on does.** It replaces everything above `qmmf-server` with its own client,
`vaidk-camd`: C++ that starts the camera, creates the main video, sub video and microphone tracks,
and passes each encoded frame to the add-on's RTSP server
([what it does](camd/README.md#what-it-does)). It grew to about 1,500 lines with the features in
[Talk-back, picture and on-screen text](#talk-back-picture-and-on-screen-text).

| Option | Outcome |
|---|---|
| `qmmf-webserver` as it is | Rejected: the problems above |
| `qmmf-webserver`, with a relay that repackages its MPEG-TS audio for RTSP | Rejected. It worked only while nothing else touched the vendor server's ports, and kept the truncated keyframes and the crashes |
| **A native client of `qmmf-server`** | Chosen. `qmmf-server` and the closed drivers below it stay; everything above it is replaceable |

**Building it.** Clients reach `qmmf-server` over Binder, through Qualcomm's C++ client library on
the camera, so the client had to be C++ built for the camera:
- **Headers.** Qualcomm published `qmmf-sdk` on CodeLinaro. Its tag matching the camera's apps build,
  `LE.UM.2.3.3.r1-04300-QCS605.0`, has the camera's API. Its 17 public headers and its `NOTICE` are
  copied unchanged into `camd/third_party/qmmf-sdk/`. Qualcomm's `qmmf-webserver` source at the same
  tag was read as a reference for calling the API; none of it is copied.
- **Two Android headers** that the qmmf headers include. `utils/Log.h` is an empty stand-in.
  `camera/CameraMetadata.h` declares the camera metadata C functions and Android 7's
  `CameraMetadata` class exactly as the camera's `libcamera_metadata.so.0` and
  `libcamera_client.so.0` export them (read from their symbol tables), because the picture settings
  call them. Both are in `camd/android/`.
- **The client libraries.** `libqmmf_recorder_client.so`, `libqmmf_player_client.so` and the two
  camera metadata libraries are the camera's binaries, without a published licence, so they never
  enter this repository: `build.ps1` copies them from the camera into a local build cache, only to
  link against.
- **The compiler.** The camera's C++ runtime is GCC 6's (`libstdc++.so.6.0.22`), and its libraries
  use the pre-C++11 `std::string` ABI. Linaro GCC 6.5-2018.12 for Windows matches both.
  releases.linaro.org no longer serves its toolchains, so `build.ps1` downloads it from Arm's archive
  of legacy Linaro toolchains and checks its published MD5. The flags, and why:
  [camd/README.md](camd/README.md#build).
- **Reproducible.** The same compiler and sources produce a byte-identical binary
  ([verify it yourself](#verify-it-yourself)).

**The microphone.**
- **Which microphones.** For a built-in microphone, the camera's audio driver picks its
  `dmic-endfire` path: two digital microphones mixed to mono, with the audio DSP's echo and noise
  processing ([device/camera/README.md](device/camera/README.md#the-microphone)).
- **A calibration step at boot.** About 5 s after `qmmf-webserver` starts, it runs a one-off audio
  calibration (`http_interface_gtest --gtest_filter=HTTPInterfaceGtest.INIT_AUDIO_ACDB`). The step
  itself crashes, leaving a core dump in `/tmp`, but it holds the microphone until about 14 s after
  the start, and a microphone track created meanwhile fails. The add-on leaves `qmmf-webserver`
  running as the vendor starts it, and `camd.sh` waits for that step. Stopping `qmmf-webserver`
  altogether wasn't tried.
- **Gain.** At 0 dB, speech recorded very quietly. The codec's digital decimators for the two
  microphones, `DEC7 Volume` and `DEC8 Volume` (0 to 124, where 84 is 0 dB), set it; `mic.sh`
  applies `84 + AUDIO_GAIN_DB`.

## RTSP streams

**Files**: `device/rtsp/rtspd.py`, `device/rtsp/net.sh`, `device/rtsp/vaidk-rtsp.service`. Authored.

**In the way.**
- **No RTSP server** on the camera but the vendor's, and no package manager to install one.
- **A partial Python.** The camera's Python 3.5.3 lacks much of its standard library: `socket` (its
  `selectors` dependency is missing), `threading`, `json`, `base64` and `signal`.
- **Wrong audio timestamps.** After the first frame, `qmmf-server`'s audio timestamps advance 16
  times too slowly.
- **A clock that moves under it.** Shortly after boot, chrony often slews the system clock
  (`CLOCK_MONOTONIC`), by 353 ms in the first minutes after one boot. The camera's capture clock
  doesn't follow: it runs at the hardware clock's rate.
- **Wi-Fi loses packets**, and a 1080p keyframe is over a hundred RTP packets. One lost packet
  corrupts the picture until the next keyframe.

**What the add-on does.** `rtspd.py` is a small RTSP server written against what the camera's Python
has: `_socket`, `select.epoll`, `struct`, `binascii` and `re`, in one event loop
([how it works](device/rtsp/README.md#how-it-works)).
- **TCP only**, with RTP inside the RTSP connection. A `SETUP` asking for UDP gets
  `461 Unsupported Transport`: ffmpeg then retries over TCP (tested), and so does VLC (its RTSP
  module switches to TCP on a 461). Frigate and go2rtc use TCP already.
- **Audio timed by its sample count**, from the first frame's timestamp, the only one that is right,
  and kept in line with the video clock ([timing](device/rtsp/README.md#timing)).
- **Players outlive the camera program.** When `vaidk-camd` restarts, players stay connected and
  carry on at the next keyframe.
- **The vendor's control ports are closed** to the network: `net.sh` rejects connections to ports 4000
  and 1080 from anything but the camera itself.

| Obstacle | Fix |
|---|---|
| Players need the video's parameter sets and the AAC configuration before they can start | `DESCRIBE` includes them, waiting up to 6 s for them after the camera starts |
| A player that joins mid-stream can't decode until a keyframe | It gets video from the next keyframe, and audio from the same moment |
| Keyframe bursts to a player on slow Wi-Fi | `net.sh` raises the kernel's socket send buffers, to 4 MB at most |
| One stalled player would hold up the others | It is disconnected once it falls more than 4 MB behind |
| A player can't follow a change of codec, resolution or audio format mid-stream | Players are disconnected on such a change, so they reconnect and read the new description |
| Audio checked against the system clock gets "corrected" away from the video whenever chrony slews that clock: in a test, a 400 ms slew put the audio 400 ms behind | Arrival times are measured on `CLOCK_MONOTONIC_RAW`, which runs at the capture clock's rate, and `vaidk-camd` reports the offset between the two when the camera starts |

## Talk-back, picture and on-screen text

**Files**: `camd/talkback.cpp`, `camd/talkback.h`, `camd/image.cpp`, `camd/image.h`, the on-screen
text in `camd/camd.cpp`, the backchannel in `device/rtsp/rtspd.py`, `camd.sh reload`, `chime` and
`tz`, and the **Picture**, **On-screen text** and **Talk-back** sections of `device/web/ui.sh`.
Authored.

**How they were chosen.** With streaming working, the camera was surveyed for hardware and camera
service features it wasn't using ([ASSESSMENT.md](ASSESSMENT.md#features-beyond-the-streams)). Each
candidate was tried first in a small test program, run in place of `vaidk-camd`, before any of it
went into the add-on.

**Talk-back.**
- **The standard.** Frigate's two-way audio goes through go2rtc, which uses the ONVIF Streaming
  Specification's backchannel: a `Require: www.onvif.org/ver20/backchannel` header on `DESCRIBE`, and
  a `sendonly` audio track that the client sends RTP on. go2rtc's RTSP client source
  (`pkg/rtsp/client.go`, `producer.go`, `consumer.go`) was read for what it depends on: it asks on
  every connection, sets the track up only when someone talks (reconnecting the stream to do so),
  uses the media's position for the interleaved channel, and carries on without a backchannel when
  a `SETUP` fails. Frigate's documentation adds the `#backchannel=0` advice for recording streams.
- **G.711.** Browsers send PCMU or PCMA over WebRTC and go2rtc passes them on unchanged, so the camera
  offers both and nothing transcodes.
- **The speaker.** `qmmf-server` has a player beside its recorder. A test program played PCM on the
  built-in speaker while `vaidk-camd` streamed, with no effect on the streams. The player's source,
  in Qualcomm's qmmf repository at the camera's tag, explained the two quirks it showed: a one-second
  stall on the first buffer, and an unclosed `/dev/ion` descriptor for every connection
  ([camd/README.md](camd/README.md#things-learned-about-qmmf)).
- **Echo cancellation.** The audio HAL has it (`FX_IID_AEC`, and a `speaker-dmic-aec-ns` input
  device), but it is switched on through the audio effects API on the input stream, and that stream
  lives inside `qmmf-server`. qmmf's audio track parameters don't reach it: for audio tracks
  `SetAudioTrackParam` does nothing, and the recorder fixes the input source. So the add-on mutes
  the microphones while the speaker plays.

| Question | Options | Chosen |
|---|---|---|
| Which program plays | A separate one; `vaidk-camd` | `vaidk-camd`: it is already the camera's one qmmf client, and restarts with it |
| How the RTSP server hands the audio over | The media socket, in reverse; a datagram socket | A datagram socket: one packet per datagram, nothing to parse, and when it is full, audio is simply dropped |
| Sample rate | 8 kHz straight to the player; 48 kHz | 48 kHz, the rate the speaker was tested at. The 8 kHz path through the DSP is untested |
| Echo | The DSP's echo cancellation; muting the microphones | Muting: the cancellation isn't reachable |
| Two clients sending | Mix them; the newest wins; the first until it pauses | The first, until it pauses for a second: a stale session never blocks a new one |
| Loudness | The player's volume alone; +12 dB and a limiter ahead of it | +12 dB and a limiter: in the first speaker test, a tone at half volume and half amplitude was "okay, but should be louder" |

**Picture.** qmmf passes Android camera request settings through (`GetCameraParam`,
`SetCameraParam`). A test program listed them (147 entries and 198 Qualcomm vendor tags), then set
each candidate on the running streams while frames were measured from the stream
([results](#how-it-was-tested)). Contrast was dropped: it changed nothing.

**On-screen text.** qmmf overlays, tried in four styles: plain, a shadow, an outline, and a
translucent label. qmmf's font is thin and white, so plain text vanishes on bright scenes; the label
read best. The clock follows `qmmf-server`'s `TZ`, which was confirmed by giving it a time zone through
a temporary systemd drop-in.

**Rotation** was the fourth candidate, and was dropped: the camera ignores it
([camd/README.md](camd/README.md#things-learned-about-qmmf)).

## Pan, tilt and zoom

**Files**: `device/onvif/`, the crop in `camd/image.cpp`, `SIGUSR2` and `CAMD_PTZ` in
`camd/camd.cpp`, and the **Pan, tilt and zoom** section of `device/web/ui.sh`. Authored.

**How it was chosen.** The camera's request settings include a crop region on the sensor
(`android.scaler.cropRegion`) and a maximum digital zoom of 8. A test program set it on the running
camera: both streams followed within a frame or two, centred or off-centre, without restarting. A
zoom only helps if Frigate and Home Assistant can drive it, and both drive cameras through ONVIF
PTZ, so the add-on presents the crop as an ONVIF PTZ camera.

**What the clients need.** Frigate 0.18's `frigate/ptz/onvif.py` and Home Assistant's
`homeassistant/components/onvif/device.py` were read for what they call and check, along with the
library both use, `onvif-zeep-async` (Frigate pins 4.0; Home Assistant uses the latest, 4.3):
- **Discovery.** `GetServices`, or `GetCapabilities` in 4.0. The device service's address is fixed
  at `/onvif/device_service`.
- **Frigate** takes the first profile with a video encoder and a PTZ configuration that has a
  continuous velocity space. Its controls come from the configuration's default spaces: arrows,
  zoom buttons, and click-to-move when a `TranslationSpaceFov` space is offered. Its buttons send
  `ContinuousMove` at half speed and `Stop`. It goes to presets with `GotoPreset`, reads them only
  when it starts, and can't save them. Imaging, snapshots and events are optional.
- **Home Assistant** reads the serial number, the MAC address (its ID for the camera), whether there
  is a snapshot URL, the H.264 profiles and their stream URLs, and the presets. Its `onvif.ptz`
  action sends relative moves by default, and ends a timed continuous move with
  `Stop(PanTilt=true, Zoom=false)`.
- **The library** always sends a WS-Security header, and fails before sending anything when the user
  is missing (`None`). So Frigate's configuration gives an empty user and password.

| Question | Options | Chosen |
|---|---|---|
| How to zoom | Scaling in the RTSP server; the encoders' own crop; the camera's crop region | The crop region: both streams follow at the sensor's full detail, and it changes on the running camera |
| How Frigate and Home Assistant control it | Their PTZ support (ONVIF); a new API | ONVIF: both already speak it |
| Which program serves ONVIF | `rtspd.py`; `vaidk-camd`; a service of its own | A Python service of its own: it can be turned off, and a fault in it never touches the streams |
| How a move reaches `vaidk-camd` | The live settings file and `SIGHUP`; a file and signal of its own | Its own (`/run/vaidk/ptz.conf`, `SIGUSR2`): moves update ten times a second, without re-applying the picture settings |
| Password | WS-Security user tokens; none | None, like the streams |
| `Stop` with `Zoom=false` | As specified: the zoom carries on; stop everything | Stop everything, as many cameras do, so Home Assistant's timed zooms stop |
| Zoom limit | The camera's 8x; 4x | 4x: beyond 2x the 1080p stream enlarges pixels |

**Snapshots** were tried first, for ONVIF's snapshot URL, and dropped: every way of taking a still
picture disturbed or broke the streams
([ASSESSMENT.md](ASSESSMENT.md#features-beyond-the-streams)).

## How it was tested

On the camera described in [ASSESSMENT.md](ASSESSMENT.md), on its Wi-Fi network, with `ffprobe` and
`ffmpeg` on a PC. "Frigate's arguments" means ffmpeg run with the input and output arguments Frigate
uses for recording and detection, without a Frigate server.

| Test | Result |
|---|---|
| 1080p at 30 fps, H.264 at 4 Mbps, the 640x360 sub stream and audio, decoded with ffmpeg | No decoder warnings; keyframes of up to about 213 KB intact |
| The same streams with Frigate's arguments | Recording: 29.7 frames/s at about 4,000 kbps, keyframes of up to 262 KB. Detection: 5.05 fps, no decoding errors |
| 4K at 30 fps, H.265 at 8 Mbps, with a 720p sub stream at 10 fps | No decoder warnings; keyframes of up to 284 KB; video about 197 ms behind capture |
| Sub stream and audio off | The main stream alone; port 8901 answers `503` |
| `kill -9` of `vaidk-camd`, then a restart of `qmmf-server` | Streaming again within about 9 s each time; the connected player stayed connected and carried on without decoder warnings |
| 10 minutes at 1080p30 with audio | 17,780 video and 28,125 audio frames; no warnings; no audio corrections; the longest gap between video frames 0.102 s |
| CPU at 1080p30, with the sub stream and audio (`top`) | `qmmf-server` about 18 to 21 %, `vaidk-camd` about 2 %, `rtspd.py` 0 to 2 % |
| Delay from capture to the RTSP server, at 1080p | Video about 70 to 105 ms; audio about 166 to 179 ms |
| The system clock slewed by +400 ms, then back (`adjtimex` tick ±1 % for 40 s each, with chronyd stopped) | No audio corrections; video delay 93 to 104 ms and audio delay 179 ms throughout |
| Audio and video alignment: 12 knocks in front of the camera, recorded from the main stream | Sound minus picture: −225 to +194 ms, median −35 ms, mean −41 ms. The picture's time comes from the change between frames, so each value is rough |
| Speech at the default gain, +24 dB | 41 of 1,251 windows of 20 ms were louder than Frigate's default `min_volume` (about −36 dBFS RMS) |
| The installers from a fresh clone: `install.ps1` in Windows PowerShell 5.1 (execution policy `AllSigned`, the file marked as downloaded) and `install.sh` in Git Bash on Windows | `.\install.ps1` is refused by the execution policy. `powershell -ExecutionPolicy Bypass -File .\install.ps1 -KeepSettings` and `bash install.sh --keep-settings` both reinstall, and the camera streams again with its settings |
| Talk-back's signal path (`talkback.cpp`'s decoders and filters, run on the camera, compared with ffmpeg) | All 256 µ-law and A-law codes decode as ffmpeg decodes them; +12.1 dB at 1 kHz; 100 Hz at −4 dB after the high-pass; upsampling images 57 dB down; a loud tone peaks at −0.4 dBFS and never clips |
| Talk-back over RTSP, with a test client that sends what go2rtc sends (`DESCRIBE` with the ONVIF `Require` header, `SETUP` of every track, `PLAY`, interleaved PCMU or PCMA) | Without the header: two tracks, no backchannel. With it: a third, send-only track, and 9 s of speech played. Two clients talking at once: only the first was played |
| Listening test: the chime, then speech at volume 80 and 100 | The chime and the speech were clear and loud enough; 80 and 100 sounded alike, so the volume scale is now squared |
| Microphone muting, recorded from the main stream during speech | Muted: digital silence (−120 dBFS) for the whole sentence, back 0.4 s after. Not muted: the speaker came back at up to −37 dBFS, about 50 dB above the room |
| Talk-back resources: three bursts, a pause mid-burst, the chime | `vaidk-camd` held one more file descriptor after the first burst (its player connection) and none more after each further one |
| `kill -9` of `vaidk-camd` during talk-back | The microphones stayed muted until `vaidk-camd` restarted and `mic.sh` set their gain again; the talking client stayed connected |
| Picture settings, measured on frames from the stream | Exposure −2 and +2 EV: mean brightness 53 and 220 (117 at 0). Saturation 0 and 10: 0.000 and 0.257 (0.147 at 5). Sharpness 0 and 6: edge strength 7.1 and 9.6 (8.4 at 2). White balance incandescent and daylight: red-to-blue 0.61 and 1.99 (1.02 automatic). Contrast 0 and 10: no change |
| On-screen text and talk-back together, with Frigate's arguments, at 1080p | Recording 29.3 frames/s at about 4,000 kbps, detection 5.05 fps, no errors; no ffmpeg warnings and no audio corrections. `qmmf-server` used 20 % of both cores with the text and 21 % without |
| The same at 4K, 8 Mbps, with a 720p sub stream | Recording 29.2 frames/s at about 8,000 kbps, detection 5.07 fps, no errors; `qmmf-server` 24 % |
| CPU during talk-back | `qmmf-server` 30 % (its player too), `vaidk-camd` 1 %, `rtspd.py` 2 % |
| The setup page's new forms, posted on the camera | Picture settings applied at once; volume and muting reached the live file; a value not offered, or two values in one field, was refused and left the settings file unchanged; a new time zone rewrote the drop-in, restarted `qmmf-server` and showed on the video |
| A Frigate 0.18 server, with the setup page's configuration | The camera worked in Frigate. Its **All Cameras** tile went live only once motion detection was on, which the configuration now does |
| Frigate 0.18's ONVIF set-up and controls, replayed with `onvif-zeep-async` 4.0.4 (the version Frigate pins), and Home Assistant's with 4.3.0 | Frigate found both profiles and the controls `pt`, `zoom`, `pt-r`, `zoom-r`, `zoom-a` and `pt-r-fov`. Its zoom, pan and tilt buttons, click-to-move, presets and home all moved the view as expected. Home Assistant's set-up, relative, absolute and continuous moves, and its `Stop(Zoom=false)`, worked. Unsupported requests, unknown presets and profiles, and oversized or stalled requests got faults or were closed, and the service carried on |
| The view, measured on frames from both streams (each matched against parts of the whole picture) | 2x centred, in the corners and off-centre, and 4x centred and in a corner: every view matched the requested part on both streams (r 0.86 to 0.98). Back at the whole picture, r 0.98 and 0.95 |
| 17 s of continuous moves: zoom, pan and tilt, the view updated ten times a second | Main stream 29.7 fps, sub 5.0 fps; the longest gap between frames 103 ms on the main stream (101 ms without moves); no lost packets |
| The view and presets through a restart of the ONVIF service, of the camera service, and a reboot | Kept each time; `vaidk-camd` started at the kept view, and after the reboot started only once |
| The setup page's pan, tilt and zoom forms, posted on the camera | Presets saved, used, updated and deleted, and seen by Frigate's request; bad names and tokens and a 17th preset refused. Off showed the whole picture (r 1.00 against it, 0.12 at 2x before); on brought the view and presets back |
| The Frigate 0.18 server again, with the snippet's `onvif` part added in its configuration and applied without a restart; Frigate's commands sent over its websocket API, as its live view sends them | Frigate listed all six controls and the camera's preset. Its zoom, pan, tilt, click-to-move and preset commands each moved the view on the camera as expected, with no ONVIF warnings in Frigate's log |

Not tested yet:
- Talk-back from a browser through Frigate or Home Assistant. It was tested with a client that
  follows go2rtc's RTSP code.
- Home Assistant's own pan, tilt and zoom controls. Its ONVIF code was replayed against the camera
  with the library version it uses.
- Holding the power button for 5 s with the add-on installed.
- `install.sh` on macOS or Linux. It was run in Git Bash on Windows.
- Hidden Wi-Fi networks.

### From stock firmware to Frigate

The camera was reflashed with Altek's v0.5370_Perf package and left without the vendor setup, then
installed and set up as the README describes:

| Step | Result |
|---|---|
| After the reflash | `v0.5370_Perf`; no add-on files or settings; SSH on, with no `AllowUsers` line and no host keys yet; the setup network's password rebuilt at the first boot from the camera module's memory |
| `install.ps1` on Windows, then first-time setup from a phone | The installer finished and named the setup network; the sticker's password joined it; the phone's sign-in page opened by itself; a new admin account was created; the lights turned solid green |
| SSH with the new admin account | Signed in from a PC and used `sudo`. The host key matched the fingerprint read over USB after `systemctl start sshdgenkeys.service` |
| The installed add-on | All 38 files matched the repository; every service running; crash recovery applied; no warnings in its logs |
| The streams | Main: H.264 High 1920x1080 at 29.4 fps with AAC 48 kHz mono, keyframes every 31 frames. Sub: 640x360 at 5.0 fps, keyframes every 6 frames. The talk-back track only when asked for. ONVIF answered without sign-in |
| Setup page changes made from the phone | Colour, on-screen text and the frame rate each applied; Frigate picked the streams up again by itself |
| Frigate 0.18 with the setup page's configuration | Recorded the main stream in 10 s segments of H.264 1920x1080 with AAC 48 kHz mono audio, and read the sub stream at 5.1 fps; the microphone's level reached its audio detector |
| Pan, tilt and zoom | Frigate's buttons moved the view on the camera, and a preset saved on the setup page appeared in Frigate after Frigate restarted. Zooming in Frigate's player moved nothing on the camera |

Not tried this time: going to a preset from Frigate, talk-back, the power button, **Reset camera**,
reinstalling and uninstalling.

## Status lights

**Files**: `device/lights/docker`. Authored.

**In the way.** The vendor's `altekflow` drives the lights. It is a closed program, which also
handles the power button, the battery's over-temperature shutdown and the vendor's factory reset. It
lights solid green ("IoT Hub connected") only when Docker runs Azure IoT Edge's agent, which it checks
every so often with
`docker ps | awk '{ if ( $2~"mcr.microsoft.com/azureiotedge-agent" ) print "found" }'`. Without IoT
Edge the lights would never turn green. This was found in the strings of the `altekflow` binary, then
confirmed on the camera.

**What the add-on does.** It leaves `altekflow` running, and changes what that check sees. The boot
script starts `altekflow` with `/opt/vaidk/lights` first on its `PATH`, where a stand-in `docker` adds
an `azureiotedge-agent` line to `docker ps` while the camera is on Wi-Fi and every stream flows. Every
other `docker` command goes to the real one, including `altekflow`'s reset steps
([device/lights/README.md](device/lights/README.md)).

| Option | Outcome |
|---|---|
| Replace `altekflow` | Rejected: without its source, the power button, the battery protection and the reset would have to be rebuilt |
| Drive the lights directly | Rejected: `altekflow` drives the same lights |
| **Change what `altekflow`'s check sees** | Chosen: one small script, on `altekflow`'s `PATH` only |

## Restart after a crash

**Files**: `device/recovery/`. Authored.

**In the way.** A flat battery crashed the camera: below about 2.7 V its internal storage stopped
responding, `qmmf-server` died and the kernel reported an error
([ASSESSMENT.md](ASSESSMENT.md#features-beyond-the-streams)). The camera stayed unresponsive, lights
off, even once it was on a charger, until its power button was held the next morning. Out of the box
the kernel carries on after an error (`panic_on_oops` 0) and never gives up on a stuck task
(`hung_task_panic` 0), so nothing restarts a camera in that state. Qualcomm's crash-dump mode is on
too (`download_mode` 1), in which, by Qualcomm's design, a panic waits for a PC to collect a memory
dump instead of restarting.

**What the add-on does.** At each boot, `recovery.sh` turns crash-dump mode off, then has the kernel
panic on an error or on a task stuck for 2 minutes, and restart 5 s after a panic
([device/recovery/README.md](device/recovery/README.md)).

| Option | Outcome |
|---|---|
| **Restart after a kernel error or a stuck task** | Chosen: the kernel's own settings, applied at each boot; nothing is written to the firmware |
| A watchdog that the system must keep resetting (systemd's `RuntimeWatchdogSec`) | Not possible: the kernel's watchdog (`msm_watchdog`) offers no `/dev/watchdog` |
| Shut down cleanly before the battery runs flat, and start again when power returns | Built, tested and dropped: a shutdown ends in a restart, with or without a charger, so the camera would restart over and over until the battery ran out |
| Ship mode, in which the charger disconnects the battery until power returns | Not used: the charger driver offers it read-only, and it takes effect at a shutdown, which restarts the camera instead |
| Change the power chip's or the bootloader's start-up settings | Not needed: the power chip is already set to start the camera when a charger is plugged in, and the bootloader's charging screen is off |

Tested on the camera, on its 1.5 A charger unless stated:

| Test | Result |
|---|---|
| A kernel crash (`echo c > /proc/sysrq-trigger`) | Back on the network about 40 s after the crash, and streaming within 2 minutes, with the settings applied again at boot |
| `systemctl poweroff` | Back by itself after about 2 minutes. The power chip recorded a hard reset with the charger present (`PON_REASON1` `0x11`), after a shutdown by the processor (`PS_HOLD`) |
| The same on battery, with the charger unplugged | Back by itself after about 2 minutes: a hard reset again (`PON_REASON1` `0x01`) |
| `RESTART_ON_CRASH=0`, then back to `1` | The vendor's values, then the add-on's, each time the service restarted; the settings file unchanged |
| `RESTART_ON_CRASH=0` in the settings file, then a restart | The camera started with the vendor's values. `vaidk-recovery` ran 9.6 s into the boot, after `/data` was mounted (8.8 s) |
| Normal running: more than four hours of streaming with these settings | No restart; the kernel reported no error, warning or stuck task (`/proc/sys/kernel/tainted`, `hung_task_warnings`) |
| The power button, held | Not run as a test. The power chip's settings restart the camera 12.3 s into a hold (its stage-2 reset, a hard reset), and the hold the morning after the crash ended that way: the power chip recorded a power-off by the power button, then a start by hard reset (`PON_REASON1` `0x91`: power button, charger and hard reset) |

Not tested: the camera starting by itself when a charger is plugged in after the battery has run
flat.

## Setup page and admin account

**Files**: `device/web/`. Authored. Served by the camera's own BusyBox `httpd`.

**In the way.**
- The vendor setup site, `websettings`, ends with the IoT Hub step, and has no settings for streams.
- There is no web framework on the camera, and Python's `http.server` needs the missing `socket`
  module.

**What the add-on does.** BusyBox `httpd` serves pages written by a shell CGI script, `ui.sh`:
- On the setup network: first-time setup and the settings, without sign-in.
- On your network: the settings, behind HTTP Basic sign-in, which BusyBox checks against the admin
  account's Linux password.
- The admin account is an ordinary Linux user in the `sudo` group, so the same account signs in over
  SSH, and saving it turns SSH on ([SSH at setup](#ssh-at-setup)).

Details: [device/web/README.md](device/web/README.md).

| Obstacle | Fix |
|---|---|
| BusyBox turns a CGI `Status: 303` header into `HTTP/1.0  303`, with two spaces, which curl and other strict clients reject | `ui.sh` writes the whole status line itself |
| BusyBox's HTML escaping breaks UTF-8 network names | `ui.sh` escapes its output itself |
| `httpd` listens on IPv6 and reports IPv4 clients as `[::ffff:a.b.c.d]` | `index.cgi` strips that before checking the address |
| Home directories are on the read-only root | `ui.sh` remounts it read-write for the moment it takes |
| `sshd_config` has an `AllowUsers` line from the vendor setup, which shuts out any other user | The admin account is added to it |
| A password on a command line is visible to every process | `chpasswd` reads it on its standard input |
| Phones open a sign-in page only if their connectivity checks are answered | Answers for the checks of Apple, Android and Windows |
| Another web site could submit the forms | A token in every form, new at each boot |

### SSH at setup

**In the way.** The vendor setup's first page had an **SSH enabled** box above an optional SSH login
and password (pictured in
[Microsoft's Quick Start](https://azure.github.io/Vision-AI-DevKit-Pages/docs/quick_start/)).
Unticked, it turned SSH off: the page, `/data/misc/websettings/homepage/index.html` on the camera,
calls `/set_sshd?enable=false`, and `websettings` holds the commands `systemctl disable sshd.socket`
and `systemctl stop sshd.socket`. So an admin account alone didn't guarantee SSH.

**What the add-on does.** Creating, changing or adopting the admin account runs what the ticked box
ran: `systemctl enable` and `start` for `sshd.socket`, after `unmask` if it is masked. The setup page
needs no box of its own, because the add-on never turns SSH off.

Tested on the camera, with the streams running:

| Test | Result |
|---|---|
| SSH turned off the vendor's way (`systemctl disable` and `stop` for `sshd.socket`) | Nothing listening on port 22 |
| A new admin account, `vaidktest`, created as setup does it (`ui.sh set-admin`) | SSH on and enabled again, listening on port 22. The account was added to `AllowUsers`, with a home directory, the groups `sudo`, `inet` and `sdcard`, and a SHA-512 password |
| Signing in as `vaidktest` from a PC | SSH with its password, then `sudo` to root. The setup page accepted it and refused the previous admin account |
| Adopting the vendor setup's account again (`ui.sh adopt-admin`) | `vaidktest` deleted, with its home directory and `AllowUsers` entry, and its SSH and page sign-ins refused. The adopted account signed in to both |

## Installing over USB

**Files**: `install.ps1`, `install.sh`, `device/install-device.sh`. Authored.

**In the way.**
- SSH works only for accounts the vendor setup created, and that setup may never have finished.
- The root file system is read-only, and `/data` is `noexec`.

**What the add-on does.** The installers use ADB, which gives a root shell over USB without any
setup. They copy `device/` to the camera, run `install-device.sh` there, restart the camera, and
follow it with `ui.sh info` until it is in setup mode or streaming
([the install sequence](ARCHITECTURE.md#install)).

| Obstacle | Fix |
|---|---|
| Scripts checked out on Windows can get CRLF line endings, which break `sh` | The installers convert text files to LF before copying; `.gitattributes` keeps them LF |
| A repository committed on Windows loses `install.sh`'s executable bit, so `./install.sh` fails on macOS and Linux | The instructions run it as `bash install.sh` |
| `vaidk-camd` must arrive byte for byte | Files containing a zero byte are copied as they are, and `install-device.sh` checks the ELF header |
| `/data` is `noexec`, so `vaidk-camd` can't run from there | The add-on lives in `/opt/vaidk`, on the root |
| The root is read-only | Remounted read-write only while copying. The new copy is built and checked in `/opt/vaidk.new` before it replaces `/opt/vaidk` |
| `adb` reports progress on standard error, which Windows PowerShell treats as an error | `install.ps1` collects both streams and checks `adb`'s exit code |
| `adb wait-for-device` returns long before the camera has started | The installers poll `ui.sh info` |
| A command started in the background (`&`) from `adb shell` doesn't run | The installers run everything in the foreground; the add-on's own background work is started by systemd or `setsid` |

## Where every component comes from

### From the device

The camera's own software. None of it is committed to this repository.

| Item | Where it goes | Why |
|---|---|---|
| The vendor boot script, `/vendor/etc/camera/InitCamx` | Read on the camera by `make-initcamx.py`; the result, `InitCamx.vaidk`, stays on the camera | The vendor's boot sequence, without the IoT Hub step |
| `libqmmf_recorder_client.so`, `libqmmf_player_client.so`, `libcamera_client.so.0`, `libcamera_metadata.so.0` | Copied by `build.ps1` to the build cache on your PC (`%LOCALAPPDATA%\vaidk-build`), only to link against | `vaidk-camd` calls `qmmf-server`'s recorder and player, and reads and writes the camera's request settings, through them |
| `qmmf-server`, the camera and audio HALs, the sensor driver, the DSP firmware | Used in place | The camera, the encoders, the microphones and the speaker |
| `altekflow`, `wifimonitor` | Used in place | The lights, the power button, the battery protection |
| `wpa_supplicant`, `udhcpc`, `startvirtualsoftap`, `hostapd`, `dnsmasq` | Used in place | Wi-Fi and the setup network |
| The setup network's password, `/persist/data/wifi.bin` | Read in place | The setup network keeps the password on the sticker |
| BusyBox (`sh`, `httpd`), Python 3.5, `tinymix`, `iptables`, `sshd`, `adbd` | Used in place | What the add-on runs on |

### Downloaded

Each is fetched at a version pinned in one place, named in the third column.

| Component | Source | Pinned in | Licence | Used for |
|---|---|---|---|---|
| `qmmf-sdk` headers and `NOTICE` | [CodeLinaro `qmmf-sdk`](https://git.codelinaro.org/clo/le/platform/vendor/qcom-opensource/qmmf-sdk), tag `LE.UM.2.3.3.r1-04300-QCS605.0`, commit `3182154cb6e384f9ce9d2388f6f4005ae28123d0` | `camd/third_party/qmmf-sdk/` (unchanged copies) | BSD-3-Clause, © The Linux Foundation | Compiling `vaidk-camd` |
| Linaro GCC 6.5-2018.12, `i686-mingw32_arm-linux-gnueabihf` | Arm's archive of legacy Linaro toolchains | `camd/build.ps1` (URL and MD5) | GPL-3.0 and others. What it builds is covered by the GCC Runtime Library Exception | Building `vaidk-camd`; never committed |

### Authored

Everything else: `install.ps1`, `install.sh`, `device/` (scripts, units, the setup page, the light
stand-in, `defaults.conf`, and `vaidk-camd` as built from `camd/`), the sources in `camd/`
(`camd.cpp`, `image.cpp`, `talkback.cpp`, their headers and `common.h`), `camd/build.ps1`,
`camd/android/`, and the documents. `camd/android/camera/CameraMetadata.h` declares only what
`vaidk-camd` calls, with the names and layouts the camera libraries' exported symbols and Android 7's
published API require; it was written for this project rather than copied from Android's sources.

## Licences and what must not be shared

Nothing from a camera is ever committed: the vendor boot script is edited on each camera, Qualcomm's
client libraries stay in your build cache, and settings, Wi-Fi networks and passwords stay on the
camera. [.gitignore](.gitignore) keeps such files, and recordings, out of the repository even if
they are copied into its folder.

| Component | Licence | OK to share |
|---|---|---|
| The add-on: its scripts, the setup page, the sources in `camd/`, `build.ps1`, `android/`, the documents | MIT ([LICENSE](LICENSE)) | Yes |
| `camd/third_party/qmmf-sdk/` | BSD-3-Clause, © The Linux Foundation. Keep its `NOTICE` with it | Yes, with the `NOTICE` |
| `device/camera/vaidk-camd` | Built from `camd/`, including the qmmf headers. GCC's runtime parts are covered by the GCC Runtime Library Exception | Yes, with the qmmf `NOTICE` |
| The four camera libraries in your build cache | The camera's binaries; no licence published | **Keep local.** Never commit them |
| The vendor boot script, and `InitCamx.vaidk` built from it | No licence | **Keep on the camera.** This repository carries only the edits |
| The Linaro toolchain | GPL-3.0 and others | Not committed: `build.ps1` downloads it from Arm |
| `/data/misc/vaidk` on the camera | Your settings, your Wi-Fi network's key hash, your admin account | **Keep private** |

## Verify it yourself

```bash
# 1. The boot script is the vendor's plus the documented edits, byte for byte (on the camera):
python3 /opt/vaidk/boot/make-initcamx.py /vendor/etc/camera/InitCamx /tmp/InitCamx.check \
  && cmp /tmp/InitCamx.check /opt/vaidk/boot/InitCamx.vaidk && echo identical
diff /vendor/etc/camera/InitCamx /opt/vaidk/boot/InitCamx.vaidk     # every change
#    make-initcamx.py also checks both files against the tested hashes it holds (KNOWN_IN, KNOWN_OUT).

# 2. The qmmf-sdk headers are Qualcomm's, unchanged (on your PC, in Git Bash or a macOS or Linux shell):
git clone -q --depth 1 --branch LE.UM.2.3.3.r1-04300-QCS605.0 \
  https://git.codelinaro.org/clo/le/platform/vendor/qcom-opensource/qmmf-sdk.git /tmp/qmmf-sdk
git -C /tmp/qmmf-sdk rev-parse HEAD     # 3182154cb6e384f9ce9d2388f6f4005ae28123d0
git diff --no-index --ignore-cr-at-eol /tmp/qmmf-sdk/include/qmmf-sdk camd/third_party/qmmf-sdk/include/qmmf-sdk
git diff --no-index --ignore-cr-at-eol /tmp/qmmf-sdk/NOTICE camd/third_party/qmmf-sdk/NOTICE
#    Both diffs print nothing.
```

```powershell
# 3. vaidk-camd rebuilds byte for byte (Windows PowerShell; the first build needs the camera on USB).
#    build.ps1 checks the toolchain it downloads against Linaro's published MD5.
.\camd\build.ps1 -Output $env:TEMP\vaidk-camd
(Get-FileHash $env:TEMP\vaidk-camd).Hash
(Get-FileHash device\camera\vaidk-camd).Hash    # the same hash
```
