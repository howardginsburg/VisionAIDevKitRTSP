# vaidk-camd: the camera program

`vaidk-camd` runs the camera through Qualcomm's camera service, `qmmf-server`, the same service the
vendor's own software uses. It starts the camera, creates the video and microphone tracks, and sends
every encoded frame to the add-on's [RTSP server](../device/rtsp/README.md). It also applies the
picture settings and the digital pan, tilt and zoom, draws the on-screen text, and plays talk-back
audio from the RTSP server on the speaker. It is about 1,600 lines of C++.

On the camera it runs as `vaidk-camera.service`, started by `camd.sh` with the saved settings; that
side is described in [device/camera/README.md](../device/camera/README.md).

| Path | What it is |
|---|---|
| [camd.cpp](camd.cpp) | The program: camera, tracks, on-screen text, the media socket and the main loop |
| [image.cpp](image.cpp), [image.h](image.h) | Picture settings and the digital zoom's crop, through the camera's request settings (metadata) |
| [talkback.cpp](talkback.cpp), [talkback.h](talkback.h) | Talk-back: the talk socket, G.711 decoding, the speaker through qmmf's player, microphone muting |
| [common.h](common.h) | Shared helpers: clocks, logging, settings |
| [build.ps1](build.ps1) | Builds it on Windows and writes `device/camera/vaidk-camd` |
| [third_party/qmmf-sdk/](third_party/qmmf-sdk/) | Qualcomm's `qmmf-sdk` headers at the camera's release, BSD-3-Clause ([NOTICE](third_party/qmmf-sdk/NOTICE)) |
| [android/](android/) | Two Android headers that the qmmf headers include. `camera/CameraMetadata.h` declares the camera metadata functions and the Android 7 `CameraMetadata` class exactly as the camera's libraries export them; `utils/Log.h` is an empty stand-in |

## What it does

1. **Connects** to `qmmf-server` through Qualcomm's client library, `libqmmf_recorder_client.so`,
   which talks to the service over Binder. If the service reports that it died or that the camera
   failed, the program exits.
2. **Starts camera 0** at `CAMERA_FPS`.
3. **Creates every track first**: session 1 holds the main video (track 1) and the microphone
   (track 101); session 2 holds the sub video (track 2). Adding a track while another is running
   starves the running track's encoder, so nothing starts until all tracks exist. If the microphone
   track can't be created, the program carries on without audio.
4. **Starts** each session, then runs `CAMD_ON_START` in the background (the microphone gain).
5. **Applies the picture settings** from `CAMD_LIVE` and the view from `CAMD_PTZ`, and **adds the
   on-screen text** to the running video tracks (see below).
6. **Opens the talk-back socket** when `CAMD_TALK` is set, and announces it to the RTSP server.
7. **For every buffer**, copies the frame into the output queue and returns the buffer to
   `qmmf-server` straight away: buffers held too long stall the camera pipeline.
8. **Watches** the streams. If an active stream delivers nothing for 10 s, the program exits with
   status 1 and systemd starts it again. Every 10 minutes it logs frame and byte totals.
9. **On `SIGHUP`**, re-reads `CAMD_LIVE` and applies the picture and speaker settings. **On
   `SIGUSR1`**, plays a test chime on the speaker. **On `SIGUSR2`**, re-reads `CAMD_PTZ` and moves
   the view.
10. **On `SIGTERM` or `SIGINT`**, stops talk-back, removes the on-screen text, stops the sessions,
    deletes the tracks and sessions, stops the camera and disconnects. If that teardown hangs for
    20 s, the program exits anyway.

| Track | Session | Format |
|---|---|---|
| Main video (1) | 1 | H.264 High or H.265 Main (the encoder picks the level from the resolution: 4.0 at 1080p), maximum-bitrate rate control at `MAIN_BITRATE`, an IDR frame every `KEYFRAME_SECONDS` with SPS/PPS in front of it, no access unit delimiters |
| Microphone (101) | 1 | AAC-LC from the built-in microphones, 16-bit, at `AUDIO_RATE`, `AUDIO_CHANNELS` and `AUDIO_BITRATE`, as raw AAC frames |
| Sub video (2) | 2 | H.264 High, otherwise like the main video |

## Output: the media socket

The program connects to the Unix socket `CAMD_SOCKET` (`/run/vaidk/media.sock`), retrying every
second until the RTSP server is there. Each message is a 28-byte little-endian header followed by the
payload:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `0x4B494156`, the bytes `VAIK` |
| 4 | 1 | Stream: `0` description, `1` main video, `2` sub video, `3` audio |
| 5 | 1 | Flags: `1` keyframe (IDR), `2` codec configuration |
| 6 | 2 | Reserved, `0` |
| 8 | 8 | Capture time from `qmmf-server`, in microseconds. It matches `CLOCK_MONOTONIC` when the camera starts, then advances at the hardware clock's rate |
| 16 | 8 | When the program received the frame, in microseconds of `CLOCK_MONOTONIC_RAW` (the hardware clock, which NTP never adjusts) |
| 24 | 4 | Payload length |

| Stream | Payload |
|---|---|
| Description (`0`) | Text lines for the streams that started, e.g. `main=H264 1920x1080 30 4000000`, `sub=H264 640x360 5 500000`, `audio=AAC 48000 1 64000`, then `clock=-854`: the capture clock minus `CLOCK_MONOTONIC_RAW` when the camera started, in microseconds. With talk-back on, also `talk=/run/vaidk/talk.sock`, the socket the RTSP server sends talk-back audio to |
| Video (`1`, `2`) | One frame in Annex-B form, with the parameter sets in front of each IDR frame |
| Audio (`3`) | One raw AAC frame, or with flag `2` the 2-byte AudioSpecificConfig |

On every connection the description comes first, then the latest codec configuration of each stream.
Video starts at the next keyframe. The messages are sent from their own thread, so `qmmf-server`'s
callbacks never wait on the socket. If more than 16 MB are waiting (the RTSP server has stalled),
frames are dropped, and video starts again at the next keyframe.

## Picture settings

`image.cpp` reads the camera's current request settings with `GetCameraParam`, changes the tags
below and writes them back with `SetCameraParam`; the running streams pick them up within a frame or
two. It then reads the settings back and logs what the camera kept, for example
`image: aeAntibandingMode=3, aeExposureCompensation=0, awbMode=1, use_saturation=5, strength=2`.

| Setting | Tag | Values |
|---|---|---|
| `ANTIFLICKER` | `android.control.aeAntibandingMode` | `off` 0, `50` 1, `60` 2, `auto` 3 |
| `EXPOSURE_EV` | `android.control.aeExposureCompensation` | EV divided by the camera's step (`aeCompensationStep`, 1/6), clamped to `aeCompensationRange` (-12 to 12) |
| `WHITE_BALANCE` | `android.control.awbMode` | `auto` 1, `incandescent` 2, `fluorescent` 3, `warm-fluorescent` 4, `daylight` 5, `cloudy` 6, `twilight` 7, `shade` 8 |
| `SATURATION` | `org.codeaurora.qcamera3.saturation.use_saturation` | 0 to 10, clamped to `saturation.range` |
| `SHARPNESS` | `org.codeaurora.qcamera3.sharpness.strength` | 0 to 6, clamped to `sharpness.range` |

The `org.codeaurora` names are Qualcomm vendor tags. The recorder client registers their names when
it connects, so `image.cpp` finds them by walking the vendor sections. The C functions and the
`CameraMetadata` class come from the camera's own `libcamera_metadata.so.0` and
`libcamera_client.so.0`, declared in [android/camera/CameraMetadata.h](android/camera/CameraMetadata.h).

## Digital pan, tilt and zoom

The [ONVIF service](../device/onvif/README.md) writes the view to `CAMD_PTZ`
(`/run/vaidk/ptz.conf`) and sends `SIGUSR2`. The program reads the file at start and on every
`SIGUSR2`:

| Key | Meaning | Missing |
|---|---|---|
| `ZOOM` | The zoom factor, 1 (the whole picture) and up | 1 |
| `ZOOM_X`, `ZOOM_Y` | Where the crop sits, from 0 (left or top) to 100 (right or bottom) | 50 |

A missing file means the whole picture. `image.cpp` turns the three values into a crop region on the
sensor and sets it on the running camera, the same way as the picture settings:

1. **Reads** `android.sensor.info.activeArraySize` (`0 0 3864 2180` on this camera) and
   `android.scaler.availableMaxDigitalZoom` (8).
2. **Clamps** the zoom to 1 to 8, and `ZOOM_X` and `ZOOM_Y` to 0 to 100.
3. **Sizes** the crop: the active area divided by the zoom, rounded down to even numbers.
4. **Places** it: `ZOOM_X` percent of the room left across, and `ZOOM_Y` percent down, again even.
5. **Sets** `android.scaler.cropRegion` to that box with `SetCameraParam`.

Both video streams are scaled from the crop, so they show the same view. The change takes effect
within a frame or two, without restarting a stream or dropping a frame. The program logs the first
view it applies after starting, and any error, for example
`zoom: 2.00x at 75% across, 25% down (crop 1448 272 1932 1090)`; with `CAMD_DEBUG` it logs every
change.

## On-screen text

With `OVERLAY` set, the program adds qmmf overlays to the running video tracks, which
`qmmf-server` draws into every frame:

- **Date and time** (`kDateType`, `YYYY/MM/DD` over `HH:MM:SS`, 24-hour). `qmmf-server` draws
  them at 12% by 12% of the frame and fills in the time itself, from its own clock and time zone
  (`TZ` in its environment; see [device/camera/README.md](../device/camera/README.md#time-zone)).
- **Camera name** (`kUserText`), drawn at 30% by 10% of the frame.
- **Labels:** a translucent black rectangle (`kPrivacyMask`, colour `0x00000090`) under each item,
  added first, because qmmf's thin white text is hard to read on bright scenes.
- **Placement:** each item goes at a fixed position (`kRandom` with `dst_rect.start_x` and
  `start_y`) inside qmmf's own 0.5% margins. The date and time take the corner in
  `OVERLAY_POSITION`; the name takes the other edge of the same side, right-aligned on the right.
- **Streams:** the main stream, and the sub stream too with `OVERLAY_STREAMS=both`.

## Talk-back

With `CAMD_TALK` set, the program binds that Unix datagram socket (`/run/vaidk/talk.sock`, mode
`0600`) and adds `talk=<path>` to its description, so the RTSP server offers its backchannel. Each
datagram is one RTP payload from the backchannel:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | The RTP payload type: `0` G.711 µ-law (PCMU), `8` G.711 A-law (PCMA), both 8 kHz mono |
| 1 | rest | The payload |

On the way to the speaker:

1. **Decode** G.711 to 16-bit samples (the standard tables; checked against ffmpeg's for all 256
   codes).
2. **High-pass** at 250 Hz (second-order Butterworth). The small speaker can't reproduce bass, which
   would only use up headroom.
3. **Gain and limiter:** +12 dB, then a peak limiter that holds the 8 kHz samples at -1 dBFS and
   recovers over about 80 ms. Speech from a browser microphone is quiet next to what the speaker
   can play.
4. **Upsample** six times to 48 kHz with a 144-tap Kaiser-windowed sinc filter (images about 57 dB
   down). 48 kHz is the rate the speaker path is known to play.
5. **Play** with qmmf's player (`libqmmf_player_client.so`): a PCM track on the built-in speaker,
   fed 80 ms buffers. Playback starts once 160 ms of audio are queued (or when a shorter burst
   ends); after a 100 ms pause the rest is sent padded with silence, and after a second without audio
   an end-of-stream buffer lets the queue play out and the track is deleted. At most one second of
   audio waits; anything older is dropped.

**Volume:** `SPEAKER_VOLUME` (0 to 100) is squared before it goes to the player, whose own volume is
linear: 80 is about -4 dB, 50 about -12 dB and 10 about -40 dB.

**Microphone muting:** with `TALKBACK_MUTE_MIC=1`, the program saves the codec's `DEC7 Volume` and
`DEC8 Volume` (the decimators that carry the two microphones), sets them to 0 (-84 dB) just before
the speaker starts, and restores them 400 ms after it stops, unless something else changed them
meanwhile. If the program dies while they are muted, `mic.sh` sets the gain again when it restarts.

**Test chime:** `SIGUSR1` queues two bell-like notes (A5, then E5) through the same path.

## Live settings

`camd.sh` writes `CAMD_LIVE` (`/run/vaidk/camd.conf`), one `KEY=value` per line: `ANTIFLICKER`,
`EXPOSURE_EV`, `WHITE_BALANCE`, `SATURATION`, `SHARPNESS`, `SPEAKER_VOLUME` and
`TALKBACK_MUTE_MIC`. The program reads it at start and on every `SIGHUP`; `camd.sh reload` rewrites
it and sends the signal. The view has its own file and signal, `CAMD_PTZ` and `SIGUSR2`
([digital pan, tilt and zoom](#digital-pan-tilt-and-zoom)), because the ONVIF service changes it ten
times a second during a move.

## Options

`camd.sh` passes the add-on's settings as environment variables; see
[device/camera/README.md](../device/camera/README.md#settings-it-uses). The program's own fallbacks
match [defaults.conf](../device/defaults.conf).

| Variable | Meaning |
|---|---|
| `MAIN_WIDTH`, `MAIN_HEIGHT`, `MAIN_FPS`, `MAIN_BITRATE`, `MAIN_CODEC` | Main video; codec `1` H.264, `0` H.265 |
| `SUB_ENABLED`, `SUB_WIDTH`, `SUB_HEIGHT`, `SUB_FPS`, `SUB_BITRATE` | Sub video, always H.264 |
| `AUDIO_ENABLED`, `AUDIO_BITRATE` | Microphone track and its AAC bitrate |
| `AUDIO_RATE`, `AUDIO_CHANNELS` | Sample rate and channels; not settings, the program uses 48000 and 1 |
| `CAMERA_FPS` | The camera's own frame rate; not a setting, the program uses 30 |
| `KEYFRAME_SECONDS` | Seconds between IDR frames |
| `NAME`, `OVERLAY`, `OVERLAY_POSITION`, `OVERLAY_STREAMS` | On-screen text: `off`, `time`, `name` or `time-name`; the corner for the date and time; `main` or `both` |
| `CAMD_SOCKET` | The media socket |
| `CAMD_TALK` | The talk-back socket; unset (talk-back off) means no socket and no backchannel |
| `CAMD_LIVE` | The live settings file (default `/run/vaidk/camd.conf`) |
| `CAMD_PTZ` | The view file (default `/run/vaidk/ptz.conf`) |
| `CAMD_ON_START` | A shell command run once the streams have started |
| `CAMD_DEBUG` | `N`: log the first `N` buffers of each stream (size, flags, timestamps) and the totals every 5 s |
| `CAMD_METADATA` | `1`: log the camera's vendor tags and every entry of its request settings at start (for exploring) |
| `CAMD_SET` | `section.name=value;...`: set extra request-setting tags at start and on every reload (numbers only; for experiments) |

To watch it work, stop the service and run it by hand on the camera:

```sh
systemctl stop vaidk-camera
CAMD_DEBUG=5 /opt/vaidk/camera/vaidk-camd     # Ctrl+C stops it cleanly
systemctl start vaidk-camera
```

## Build

`device/camera/vaidk-camd` is committed, built from the sources here. To rebuild it on Windows,
connect the camera over USB and run:

```powershell
.\camd\build.ps1
```

1. **Compiler.** Downloads Linaro GCC 6.5-2018.12 for Windows (`arm-linux-gnueabihf`, 320 MB) from
   Arm's archive of legacy Linaro toolchains, checks its published MD5, and unpacks it.
2. **Libraries.** Copies four of the camera's libraries from `/usr/lib` with `adb`, only to link
   against: `libqmmf_recorder_client.so`, `libqmmf_player_client.so`, `libcamera_client.so.0` and
   `libcamera_metadata.so.0`. They are kept with the compiler in `%LOCALAPPDATA%\vaidk-build`, never in
   this repository.
3. **Compile and strip.** Writes `device/camera/vaidk-camd`, about 64 KB.

| Flag | Why |
|---|---|
| GCC 6 | The camera's C++ runtime is `libstdc++.so.6.0.22` (GCC 6). Newer compilers emit symbols it lacks |
| `-D_GLIBCXX_USE_CXX11_ABI=0` | The camera's libraries use the older `std::string` and `std::list` layout, and the qmmf API passes `std::string`, `std::vector` and `std::function` |
| `-mcpu=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard` | The camera runs 32-bit ARMv7 hard-float Linux |
| `-l:libqmmf_recorder_client.so -l:libqmmf_player_client.so -l:libcamera_client.so.0 -l:libcamera_metadata.so.0` | Links against the camera's own libraries |
| `-Wl,--allow-shlib-undefined` | Those libraries' own dependencies (Binder and others) are found on the camera at run time |

The build is reproducible: the same compiler and sources produce a byte-identical binary
([PROVENANCE.md](../PROVENANCE.md#verify-it-yourself)). `build.ps1` is for Windows; on Linux the same
flags with Linaro's `x86_64` build of the same compiler should work, but that isn't scripted or
tested.

## Things learned about qmmf

| Behaviour | What the program does |
|---|---|
| Adding a track while another runs stalls the running one | Creates every track before starting any session |
| A 320x180 video track made `qmmf-server` crash | The setup page offers 640x360 and up only |
| Audio timestamps advance 16 times too slowly after the first frame | Sends them unchanged; the RTSP server times audio by its sample count |
| Capture timestamps match `CLOCK_MONOTONIC` when the camera starts, then run at the hardware clock's rate, so they drift from `CLOCK_MONOTONIC` whenever NTP slews it (by 353 ms in the first minutes after one boot) | Stamps arrivals with `CLOCK_MONOTONIC_RAW`, which runs at the same rate, and reports the offset between the two clocks at start (`clock=`) |
| The first audio buffer is the AudioSpecificConfig, flagged as codec configuration | Passed on with flag `2` |
| The vendor media server holds the microphone during its start-up calibration | `camd.sh` waits for it before starting the program |
| The qmmf headers use `memcpy` without including `<cstring>`, and include two Android headers | Each source file includes `<cstring>` first; `android/` provides the two headers |
| Overlays can only be added to running tracks, and must be removed before the session stops | Adds them after the sessions start; removes and deletes them first when stopping |
| An overlay's `dst_rect.width` and `height` resize qmmf's drawing surface, which shrinks the text | Sets only the position and leaves the size at 0 |
| `qmmf-server` draws the overlay clock with `localtime()`, and the camera has no time zone database | `camd.sh` puts a POSIX `TZ` in `qmmf-server`'s environment |
| CamX ignores the stream rotation parameter (`QMMF_VIDEO_ROTATE`) at 90 and 180 degrees, portrait sizes such as 1080x1920 make `qmmf-server` abort (`CheckValidStreamConfig`), and there are no flip or mirror tags | No rotation setting |
| `org.codeaurora.qcamera3.contrast.level` is accepted but changes nothing | No contrast setting |
| `android.scaler.croppingType` is 0 (centre only), yet off-centre crop regions work: frames from both streams match the requested part of the whole picture | Pans by moving the crop region |
| Still captures (`CaptureImage`) reconfigure the camera: each one stalled the video for 140 to 550 ms, and four in a row left the camera driver stuck until a forced restart. A JPEG video track made `qmmf-server` abort (`CreateDeviceStream`), and zero-shutter-lag mode at 1080p wouldn't start the camera (`-61`) | No snapshot URL; Frigate and Home Assistant take stills from the stream |
| The audio HAL's echo cancellation (`FX_IID_AEC`) can only be switched on through the effects API of the input stream, which `qmmf-server` owns; qmmf's audio track parameters don't reach it | Mutes the microphones while the speaker plays |
| The microphones' noise suppression removes steady sounds, such as a test tone from the speaker | Echo and level tests use speech |
| The player's `DequeueInputBuffer` waits for a free buffer in one-second steps and can miss the wakeup, so an early call blocks for a second | Counts free buffers from the `kInputBufferNotify` events and only asks for one it knows is free |
| Every `Player::Connect` opens `/dev/ion`, and nothing closes it | Connects once and reuses the connection; creates and deletes a track for each burst |
| PCM always goes through the offload path: four 80 ms buffers at 48 kHz, about 250 ms to the speaker | Queues full buffers; 160 ms head start |
| The player's volume is linear (`volume / 100`) | Squares `SPEAKER_VOLUME` first |
| `DEC7 Volume` and `DEC8 Volume` are signed controls: a value below 84 (0 dB) reads back 256 higher | Saves and restores the values as read, and compares against the value read back after muting |
