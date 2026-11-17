# Architecture: how the add-on fits together

This document shows how the pieces work together: the layers, how video, audio, talk-back, pan, tilt
and zoom, object detection and status flow between the parts, how settings reach them, how the camera
boots, and how the add-on is installed, set up and removed.
- What the project is for, and how to use it: [README.md](README.md).
- The camera as it came: [ASSESSMENT.md](ASSESSMENT.md).
- How each feature was made to work without Azure, and where every piece comes from:
  [PROVENANCE.md](PROVENANCE.md).
- Each component in detail: its own README, linked from [Components](#components).

## Contents

1. [The layers](#the-layers)
2. [Components](#components)
3. [How data flows](#how-data-flows)
4. [Settings: one file, two ways to change it](#settings-one-file-two-ways-to-change-it)
5. [Boot](#boot)
6. [Install, setup and reset](#install-setup-and-reset)
7. [Network ports](#network-ports)
8. [Repository layout](#repository-layout)

## The layers

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 420}}}%%
flowchart TB
    you["You<br/>Frigate, Home Assistant, VLC or another RTSP player · a browser<br/>the installers over USB · SSH, optional"]
    addon["The add-on, in /opt/vaidk<br/>camera program · RTSP server · ONVIF service · object detector<br/>MQTT client · Wi-Fi watchdog · setup page · boot script<br/>status-light stand-in · crash recovery · storage upkeep"]
    vendor["The camera's own software, kept<br/>qmmf-server with the camera and audio HALs<br/>video analytics and SNPE · weston · altekflow · Wi-Fi tools · sshd · adbd"]
    fw["Qualcomm firmware and Linux 4.9, unchanged<br/>32-bit, read-only root file system"]
    hw["Vision AI DevKit<br/>Qualcomm QCS603 · 8 MP Sony IMX334 sensor<br/>microphones · speaker · Wi-Fi · HDMI port · three lights · power button"]
    you --> addon
    you --> vendor
    addon --> vendor
    vendor --> fw
    fw --> hw
    classDef use fill:#d5e8d4,stroke:#82b366,color:#1a1a1a
    classDef mod fill:#dae8fc,stroke:#6c8ebf,color:#1a1a1a
    classDef os fill:#fff2cc,stroke:#d6b656,color:#1a1a1a
    classDef locked fill:#f8cecc,stroke:#b85450,color:#1a1a1a
    classDef hard fill:#f5f5f5,stroke:#666666,color:#1a1a1a
    class you use
    class addon mod
    class vendor os
    class fw locked
    class hw hard
```

- **Hardware.** The camera board, its sensor, microphones, speaker, Wi-Fi, HDMI port, lights and power
  button. [ASSESSMENT.md](ASSESSMENT.md) lists it all.
- **Firmware and kernel.** Qualcomm's boot chain, Linux 4.9, and the firmware of the image
  processor, the video encoder and the DSPs, as the camera shipped them. The add-on never touches
  them.
- **The camera's own software.** `qmmf-server` runs the sensor, the image processor, the video
  encoders, the microphones and the speaker; Qualcomm's video analytics libraries run the object
  detector's model on the DSP; weston drives the HDMI output; `altekflow` drives the lights and the
  power button; the vendor's Wi-Fi tools run the Wi-Fi client and the setup network. The add-on uses
  them as they are, and changes a few things around them: its own copy of the boot script runs instead
  of the vendor's, the vendor preview server is disabled, `qmmf-server` gets a time zone, the
  detector's configuration takes the vendor's place while detection is on, weston runs only for HDMI
  live view, and the admin account is an ordinary Linux user.
- **The add-on.** Nine systemd services and the boot script, in `/opt/vaidk`. Your settings are in
  `/data/misc/vaidk`.
- **You.** RTSP players and NVRs, a browser for the setup page, the installers over USB, and SSH if
  you want it.

## Components

| Component | Runs as | What it does | Details |
|---|---|---|---|
| Boot script | `InitCamx.service`, through a drop-in | The vendor's boot sequence without its IoT Hub step: joins the saved Wi-Fi network, or opens the setup network | [device/boot](device/boot/README.md) |
| Camera program | `vaidk-camera.service` | `vaidk-camd` drives the camera, the encoders, the microphone and the speaker through `qmmf-server`, applies the picture settings and on-screen text, and with HDMI live view on shows the main stream on a monitor | [device/camera](device/camera/README.md), [camd](camd/README.md) |
| RTSP server | `vaidk-rtsp.service` | `rtspd.py`: the main stream with audio and the talk-back channel on port 8900, the sub stream on port 8901 | [device/rtsp](device/rtsp/README.md) |
| Pan, tilt and zoom | `vaidk-onvif.service` | `onvifd.py`: the ONVIF service on port 8080, through which Frigate and Home Assistant find the streams and move the digital view; keeps the view and presets | [device/onvif](device/onvif/README.md) |
| Object detection | `vaidk-detect.service` | `vaidk-detect` runs the camera's own detector (Qualcomm's video analytics manager and the vendor's model, on the DSP) on frames from `vaidk-camd`, sends back boxes for the main stream, and reports what it sees. Off by default | [device/detect](device/detect/README.md), [camd](camd/README.md#object-detection) |
| MQTT | `vaidk-mqtt.service` | `mqttd.py` publishes what the detector sees to your MQTT broker, and announces sensors to Home Assistant if you want. Off by default | [device/mqtt](device/mqtt/README.md) |
| Wi-Fi | `vaidk-wifi.service` | Keeps Wi-Fi connected, opens the setup network when it can't, joins new networks | [device/wifi](device/wifi/README.md) |
| Setup page | `vaidk-web.service` | First-time setup and settings, on port 80 | [device/web](device/web/README.md) |
| Crash recovery | `vaidk-recovery.service` | `recovery.sh`, once at boot: turns off Qualcomm's crash-dump mode and has the kernel restart the camera after a crash | [device/recovery](device/recovery/README.md) |
| Storage upkeep | `vaidk-storage.service` | `storage.sh`: keeps the vendor's properties file in RAM and saves it to flash only when it changes, records crashes without crash dumps, and trims logs in RAM every 10 minutes | [device/storage](device/storage/README.md) |
| Status lights | The vendor's `altekflow` | A stand-in for `docker` makes the "IoT Hub connected" light mean "streaming" | [device/lights](device/lights/README.md) |

The vendor software the add-on relies on, and what it does now:

| Vendor software | Role |
|---|---|
| `qmmf-server` | The camera service: sensor, image processing, H.264 and H.265 encoders, overlays, microphones and AAC, and the player that drives the speaker. `vaidk-camd` uses it through Qualcomm's client libraries. A drop-in gives it the on-screen clock's time zone; for HDMI live view, `camd.sh` has it keep its frames uncompressed (`persist.qmmf.ubwcstream.enable=0`) |
| `weston` (`init_display.service`) | The display server for the HDMI port. The vendor ran it all the time, an empty desktop costing about 0.8 W; a drop-in now lets it start only for HDMI live view, and `vaidk-camd` shows the main stream through it with Qualcomm's display client (`libqmmf_display_client`) |
| Video analytics: `libvam_interface`, VAM, `libEngine_ML`, SNPE | The object detector. `vaidk-detect` loads them into its own process: the video analytics manager (VAM) hands each frame to the ML engine, which runs the model with SNPE on the Hexagon DSP |
| The vision sample's Docker image | Unused as a container. The object detector's model is copied from it once, or from the copy of the image the firmware keeps on its system partition |
| `qmmf-webserver` | The vendor media server. Unused and blocked from the network, but left running: its start-up includes an audio calibration step, which the camera service waits for |
| `ipc-webserver` | The vendor preview server. Disabled: it would compete for the camera |
| `altekflow` | The lights, the power button (hold it 5 s for the setup network) and the battery's over-temperature shutdown |
| `wifimonitor` | Reports the Wi-Fi connection to `altekflow` |
| `leprop-service` | The property service: rewrites the saved properties file, `/systemrw/build.prop`, whenever a program sets a `persist.` property. `altekflow` sets two of them about twice a second, so while the add-on runs, the file it rewrites is a copy in RAM ([storage upkeep](device/storage/README.md)) |
| `startvirtualsoftap`, `hostapd`, `dnsmasq` | The setup network |
| `wpa_supplicant`, `udhcpc` | The Wi-Fi client |
| BusyBox `httpd` | Serves the setup page |
| `tinymix` | Sets the microphone gain (`mic.sh`). `vaidk-camd` mutes and restores the same controls itself, through the sound card's control device |
| `sshd`, `adbd` | SSH, which `ui.sh` turns on whenever it saves the admin account, and ADB (the installers) |

## How data flows

### Video and audio

```mermaid
flowchart LR
    sensor["IMX334 sensor"] --> qmmf["qmmf-server<br/>image processing · H.264/H.265 encoders<br/>audio DSP · AAC encoder"]
    mics["Built-in microphones"] --> qmmf
    qmmf -- "Binder, shared buffers" --> camd["vaidk-camd"]
    camd -- "/run/vaidk/media.sock" --> rtspd["rtspd.py"]
    rtspd -- "RTSP :8900, main + audio" --> players["Frigate · VLC · NVRs"]
    rtspd -- "RTSP :8901, sub" --> players
    classDef hard fill:#f5f5f5,stroke:#666666,color:#1a1a1a
    classDef os fill:#fff2cc,stroke:#d6b656,color:#1a1a1a
    classDef mod fill:#dae8fc,stroke:#6c8ebf,color:#1a1a1a
    classDef use fill:#d5e8d4,stroke:#82b366,color:#1a1a1a
    class sensor,mics hard
    class qmmf os
    class camd,rtspd mod
    class players use
```

- **`qmmf-server` does the heavy work**, in the camera's hardware: image processing, video encoding,
  and the microphones' noise suppression on the audio DSP.
- **`vaidk-camd`** copies each encoded frame out of `qmmf-server`'s buffer and hands the buffer back
  at once, then sends the frame, with its capture time, to the RTSP server from its own thread
  ([the media socket](camd/README.md#output-the-media-socket)).
- **`rtspd.py`** packs the frames into RTP inside each player's RTSP connection (TCP only), for up to
  8 players ([how it works](device/rtsp/README.md#how-it-works)).
- **Each side restarts on its own.** If the camera pipeline stalls, `vaidk-camd` exits and systemd
  starts a fresh camera session; `rtspd.py` keeps the players connected meanwhile, and they carry on
  at the next keyframe. If `rtspd.py` restarts, the players reconnect.
- **Timing.** Video is stamped with the camera's capture time. Audio is timed by its sample count
  from its first frame, because the camera's audio timestamps run slow, and is kept in line with
  the video clock ([timing](device/rtsp/README.md#timing)). Arrival times are measured on the
  hardware clock, which NTP never adjusts, so a clock correction after boot can't pull the two
  apart. Measured delays and audio-video alignment are in
  [PROVENANCE.md](PROVENANCE.md#how-it-was-tested).

### Talk-back

```mermaid
flowchart LR
    browser["Browser microphone<br/>Frigate or Home Assistant, on HTTPS"] -- "WebRTC, G.711" --> go2rtc["Frigate's go2rtc"]
    go2rtc -- "RTSP :8900 backchannel<br/>RTP inside the connection" --> rtspd["rtspd.py"]
    rtspd -- "/run/vaidk/talk.sock<br/>one datagram per packet" --> camd["vaidk-camd<br/>decode · high-pass · gain · 48 kHz"]
    camd -- "Binder, shared buffers" --> qmmf["qmmf-server player<br/>audio DSP, offload"]
    qmmf --> speaker["Speaker"]
    camd -- "mute while playing" --> mixer["Codec mixer<br/>DEC7 and DEC8 Volume"]
    classDef use fill:#d5e8d4,stroke:#82b366,color:#1a1a1a
    classDef os fill:#fff2cc,stroke:#d6b656,color:#1a1a1a
    classDef mod fill:#dae8fc,stroke:#6c8ebf,color:#1a1a1a
    classDef hard fill:#f5f5f5,stroke:#666666,color:#1a1a1a
    class browser,go2rtc use
    class qmmf os
    class rtspd,camd mod
    class speaker,mixer hard
```

- **Only on request.** `vaidk-camd` announces its talk socket in the stream description when
  talk-back is on; `rtspd.py` then offers the backchannel to clients that ask for it
  ([talk-back](device/rtsp/README.md#talk-back)).
- **One talker at a time.** `rtspd.py` passes on packets from the first client that sends, until it
  has been quiet for a second.
- **The speaker track lives only while someone talks.** `vaidk-camd` opens a player track when audio
  arrives, mutes the microphones, and closes the track and restores them after a second of quiet
  ([talk-back](camd/README.md#talk-back)).
- **The recording stream doesn't change.** The microphone's AAC track keeps running, silent while the
  speaker plays, and Frigate records from a stream that doesn't take the backchannel.

### Pan, tilt and zoom

```mermaid
flowchart LR
    clients["Frigate · Home Assistant · NVRs"] -- "ONVIF, SOAP over HTTP :8080" --> onvifd["onvifd.py<br/>position · home · presets"]
    page["Setup page"] -- "127.0.0.1:8080/local/ptz" --> onvifd
    onvifd -- "kept" --> state["/data/misc/vaidk/ptz"]
    onvifd -- "/run/vaidk/ptz.conf<br/>then SIGUSR2" --> camd["vaidk-camd"]
    camd -- "crop region<br/>SetCameraParam" --> qmmf["qmmf-server<br/>image processor"]
    qmmf -- "both streams<br/>scaled from the crop" --> rtspd["rtspd.py"]
    classDef use fill:#d5e8d4,stroke:#82b366,color:#1a1a1a
    classDef data fill:#e1d5e7,stroke:#9673a6,color:#1a1a1a
    classDef mod fill:#dae8fc,stroke:#6c8ebf,color:#1a1a1a
    classDef os fill:#fff2cc,stroke:#d6b656,color:#1a1a1a
    class clients,page use
    class state data
    class onvifd,camd,rtspd mod
    class qmmf os
```

- **Digital.** The camera crops its 3840x2160 sensor picture and scales both streams from the crop,
  up to 4x. Nothing restarts and no frame is lost while the view moves
  ([how a move reaches the picture](device/onvif/README.md#how-a-move-reaches-the-picture)).
- **One owner.** `onvifd.py` keeps the position, home position and presets, for ONVIF clients and the
  setup page alike. During a continuous move it updates the view ten times a second.
- **Kept across restarts.** `vaidk-camd` applies `/run/vaidk/ptz.conf` when it starts; after a reboot
  `onvifd.py` writes it again from `/data/misc/vaidk/ptz`.
- **What Frigate sees.** Both streams show the view, so Frigate records and detects the view, not the
  whole picture.

### Object detection

```mermaid
flowchart LR
    qmmf["qmmf-server<br/>sub stream at 640x360"] -- "copies of its frames, NV12" --> camd["vaidk-camd"]
    camd -- "a frame when one is due and asked for<br/>/run/vaidk/detect.sock" --> detect["vaidk-detect"]
    detect -- "frames" --> vam["VAM · ML engine · SNPE<br/>the camera's own libraries"]
    vam -- "the model" --> dsp["Hexagon DSP"]
    vam -- "objects, as JSON" --> detect
    detect -- "boxes" --> camd
    camd -- "bounding-box overlays<br/>on the main stream" --> qmmf
    detect -- "detect.state, detect.recent" --> page["Setup page"]
    detect -- "what changes<br/>/run/vaidk/events.sock" --> mqttd["mqttd.py"]
    mqttd -- "MQTT 3.1.1" --> broker["Your MQTT broker<br/>Home Assistant"]
    classDef use fill:#d5e8d4,stroke:#82b366,color:#1a1a1a
    classDef mod fill:#dae8fc,stroke:#6c8ebf,color:#1a1a1a
    classDef os fill:#fff2cc,stroke:#d6b656,color:#1a1a1a
    classDef hard fill:#f5f5f5,stroke:#666666,color:#1a1a1a
    class page,broker use
    class camd,detect,mqttd mod
    class qmmf,vam os
    class dsp hard
```

- **Two programs.** `vaidk-camd` owns the camera; `vaidk-detect` loads Qualcomm's video analytics
  manager (VAM) into a process of its own. If it, SNPE or the DSP crashes or hangs, the streams carry
  on: systemd restarts the detector, and `vaidk-camd` hides the boxes and connects again.
- **Frames from the sub stream.** A copy of the sub stream's frames shows exactly what the main stream
  shows, zoomed or not, and is plain NV12 only at 640x360. `vaidk-camd` hands a frame over only when
  the detector has asked for one and one is due (`DETECT_FPS`), and gives qmmf its buffer back at once.
- **Boxes on the main stream.** qmmf's bounding-box overlays, as Qualcomm's own media server drew
  VAM's results; at most 10 overlays on a stream, the on-screen text included
  ([boxes](camd/README.md#object-detection)).
- **The model** is the vendor's: copied once from its vision sample to `/data/misc/vaidk`. While
  detection is on, VAM finds it, and the add-on's engine configuration, through links in the vendor's
  `/data/misc/camera` ([how detection starts](device/detect/README.md)).
- **Nothing written to flash** while it runs: VAM's database and the engine configuration are in RAM.
- **MQTT.** The detector sends what changes, and each result while something is in view, as
  datagrams to `mqttd.py`, which publishes them; it never waits for it. When the detector starts again
  or stops, `mqttd.py` publishes what was in view as gone ([topics](device/mqtt/README.md#topics)).

### HDMI live view

```mermaid
flowchart LR
    qmmf["qmmf-server<br/>main stream, with its text and boxes"] -- "copies of its frames, NV12" --> camd["vaidk-camd"]
    camd -- "Qualcomm's display client<br/>Wayland, a buffer per frame" --> weston["weston<br/>the vendor's display server"]
    weston -- "a display plane" --> bridge["DSI · LT9611 bridge"]
    bridge -- "HDMI, 1920x1080 at 60 Hz" --> monitor["Monitor"]
    classDef use fill:#d5e8d4,stroke:#82b366,color:#1a1a1a
    classDef mod fill:#dae8fc,stroke:#6c8ebf,color:#1a1a1a
    classDef os fill:#fff2cc,stroke:#d6b656,color:#1a1a1a
    classDef hard fill:#f5f5f5,stroke:#666666,color:#1a1a1a
    class monitor use
    class camd mod
    class qmmf,weston os
    class bridge hard
```

- **Only while it is on.** Before `vaidk-camd` starts, `camd.sh` starts weston (the vendor's
  `init_display.service`, which a drop-in otherwise keeps from starting) and has `qmmf-server` keep
  its frames uncompressed; with live view off, it stops weston, which turns the output off and saves
  about 0.8 W ([HDMI live view](device/camera/README.md#hdmi-live-view)).
- **The main stream's picture.** The copies carry the main stream's zoom, on-screen text and detection
  boxes; a 4K stream is scaled to 1920x1080.
- **No hot-plug.** The bridge can't tell whether a monitor is plugged in, so the output runs whenever
  live view is on.
- **If weston stops,** `vaidk-camd` stops too; systemd starts it again, and `camd.sh` starts weston
  first.

### Status and lights

```mermaid
flowchart LR
    rtspd["rtspd.py"] -- "/run/vaidk/streaming" --> stand["lights/docker<br/>stand-in"]
    wpa["wpa_supplicant"] -- "connected" --> stand
    stand -- "answers its docker ps" --> altek["altekflow"]
    wifimon["wifimonitor"] -- "Wi-Fi state" --> altek
    boot["Boot script"] -- "setup network or Wi-Fi client" --> altek
    altek --> leds["Three lights"]
    classDef mod fill:#dae8fc,stroke:#6c8ebf,color:#1a1a1a
    classDef os fill:#fff2cc,stroke:#d6b656,color:#1a1a1a
    classDef hard fill:#f5f5f5,stroke:#666666,color:#1a1a1a
    class rtspd,stand,boot mod
    class wpa,altek,wifimon os
    class leds hard
```

- `altekflow` sets the lights from three inputs, and checks the "IoT Hub" one by running `docker ps`
  every so often. The add-on only changes what that check sees
  ([how altekflow decides](device/lights/README.md#how-altekflow-decides)). What each light means is
  in the [README](README.md#status-lights).
- The setup page and `ui.sh info` (which the installers read) report from the same sources: the
  RTSP server's files and the Wi-Fi client's state. The setup page's **System** section adds the
  kernel's own counters and the crash records that storage upkeep keeps
  ([what each line shows](device/web/README.md#the-system-section)).

### Run-time files

`/run/vaidk` is on a RAM file system, so it starts empty at every boot.

| File | Written by | Read by |
|---|---|---|
| `media.sock` | `rtspd.py`, which listens on it | `vaidk-camd` connects and sends the streams |
| `talk.sock` | `vaidk-camd`, which binds it when talk-back is on | `rtspd.py` sends it the talk-back audio |
| `camd.conf` | `camd.sh`, at start and on `camd.sh reload` | `vaidk-camd`, at start and on `SIGHUP` ([live settings](camd/README.md#live-settings)) |
| `ptz.conf` | `onvifd.py`, whenever the view moves; `onvif.sh` deletes it when pan, tilt and zoom is off | `vaidk-camd`, at start and on `SIGUSR2` ([digital pan, tilt and zoom](camd/README.md#digital-pan-tilt-and-zoom)) |
| `detect.sock` | `vaidk-detect`, which listens on it | `vaidk-camd` connects, sends frames and receives boxes ([object detection](camd/README.md#object-detection)) |
| `detect.state`, `detect.recent` | `vaidk-detect`, every second and on each change; `detect.sh`, while it prepares or when detection can't start | The setup page ([fields](device/detect/README.md#status)) |
| `detect/` (a folder) | `detect.sh`: the engine configuration, and `vam/`, a 4 MB RAM file system for VAM's database | VAM, in `vaidk-detect`, through links in `/data/misc/camera` and `/data/misc/vam` |
| `events.sock` | `mqttd.py`, which binds it | `vaidk-detect` sends it what it sees ([events](device/mqtt/README.md#how-events-arrive)) |
| `mqtt.state` | `mqttd.py`, when its state changes and every 10 s | The setup page |
| `hdmi-on` | `camd.sh`, while HDMI live view is on | `init_display.service`, which starts only while it exists ([HDMI live view](device/camera/README.md#hdmi-live-view)) |
| `rtsp.status` | `rtspd.py`, every second | The setup page; you ([fields](device/rtsp/README.md#status)) |
| `streaming` | `rtspd.py`, while every enabled stream flows | The light stand-in, the setup page, `ui.sh info` |
| `boot-wifi-done` | The boot script, after its Wi-Fi step | The Wi-Fi watchdog, which waits for it; `ui.sh info` |
| `fallback-ap` | The Wi-Fi watchdog, when it opened the setup network itself | The Wi-Fi watchdog |
| `wifi.lock` (a folder) | `wifi.sh try`, while it joins a network | The Wi-Fi watchdog, which leaves the Wi-Fi alone meanwhile |
| `candidate.conf`, `wifi-try`, `wifi-try-ssid`, `wifi-try.log` | The setup page and `wifi.sh try` | The setup page's progress view |
| `scan`, `scan.conf` | The setup page (cached scan results) and `wifi.sh scan` | The setup page |
| `csrf` | The setup page, once per boot | The setup page (form tokens) |
| `httpd.conf` | `ui.sh write-httpd-conf` | BusyBox `httpd` (the sign-in rule) |
| `build.prop` | `storage.sh`, which copies it from `/systemrw` at boot and binds it over `/systemrw/build.prop` and `/etc/build.prop`; then `leprop-service` | Every program that reads or sets a vendor property; `storage.sh`, which saves it to flash when it changed |
| `crashes` | `storage.sh crash`, which the kernel runs when a program crashes; the cleanup, for crash dumps from before the service started | The setup page's **System** section; you |
| `flash.<pid>` (a folder) | `storage.sh`, for the moment it takes to save `build.prop`: a private bind of `/systemrw` | `storage.sh` |

## Settings: one file, two ways to change it

```mermaid
flowchart LR
    defaults["/opt/vaidk/defaults.conf<br/>every setting and its default"] --> load["load_settings<br/>in common.sh"]
    conf["/data/misc/vaidk/vaidk.conf<br/>your settings"] --> load
    page["Setup page"] -- "set_setting" --> conf
    hand["You, over adb or SSH"] -- "a line from defaults.conf" --> conf
    load --> camd["camd.sh and mic.sh"]
    load --> wifi["wifi.sh"]
    load --> net["net.sh"]
    load --> ui["ui.sh"]
    load --> onvif["onvif.sh"]
    load --> detsh["detect.sh"]
    load --> mqttsh["mqtt.sh"]
    camd -- "settings at start<br/>live ones on SIGHUP" --> prog["vaidk-camd"]
    camd -- "camd.sh tz: drop-in" --> qmmf["qmmf-server<br/>time zone"]
    camd -- "HDMI: start or stop" --> weston["weston<br/>display server"]
    detsh -- "settings at start" --> det["vaidk-detect"]
    mqttsh -- "settings at start" --> mq["mqttd.py"]
    classDef use fill:#d5e8d4,stroke:#82b366,color:#1a1a1a
    classDef data fill:#e1d5e7,stroke:#9673a6,color:#1a1a1a
    classDef mod fill:#dae8fc,stroke:#6c8ebf,color:#1a1a1a
    classDef os fill:#fff2cc,stroke:#d6b656,color:#1a1a1a
    class page,hand use
    class defaults,conf data
    class load,camd,wifi,net,ui,onvif,detsh,mqttsh,prog,det,mq mod
    class qmmf,weston os
```

- **Defined once.** Every setting, its default and what it means is in
  [device/defaults.conf](device/defaults.conf), and nowhere else.
- **One file of your settings.** `/data/misc/vaidk/vaidk.conf` holds the values saved on the setup
  page, or added by hand; they override the defaults.
- **Two ways to change it.** The setup page writes it with `set_setting`, accepting only the choices
  it offers. For a setting the page doesn't show, add its line from `defaults.conf` to `vaidk.conf`
  with a new value.
- **Read at start.** Each script runs `load_settings` when it starts: the defaults first, then
  `vaidk.conf`. A change applies when the part that reads it starts again, except for the live ones.
  `onvifd.py` reads the two files itself, and again whenever either changes, to describe the streams
  to ONVIF clients.
- **Live settings.** For the picture, the speaker, and how often frames go to the object detector and
  whether its boxes show, `camd.sh reload` writes the resolved values to `/run/vaidk/camd.conf` and
  signals `vaidk-camd`, which applies them to the running streams.

| Settings | Read by | Applied |
|---|---|---|
| `MAIN_*`, `SUB_*`, `AUDIO_ENABLED`, `AUDIO_BITRATE`, `KEYFRAME_SECONDS` | `camd.sh`, which passes them to `vaidk-camd` | When the camera service restarts. Saving **Camera streams** on the setup page restarts it |
| `OVERLAY`, `OVERLAY_POSITION`, `OVERLAY_STREAMS`, `TALKBACK` | `camd.sh`, which passes them to `vaidk-camd` | When the camera service restarts. Saving **On-screen text**, or turning talk-back on or off, restarts it |
| `ANTIFLICKER`, `EXPOSURE_EV`, `WHITE_BALANCE`, `SATURATION`, `SHARPNESS`, `SPEAKER_VOLUME`, `TALKBACK_MUTE_MIC` | `camd.sh`, which writes them to `/run/vaidk/camd.conf` for `vaidk-camd` | At once: saving **Picture** or **Talk-back** runs `camd.sh reload` |
| `TIME_ZONE` | `camd.sh tz`, which writes it into `qmmf-server`'s drop-in | When `qmmf-server` restarts; `camd.sh tz` restarts it if the value changed |
| `STOP_IPC_WEBSERVER` | `camd.sh` | When the camera service starts |
| `AUDIO_GAIN_DB` | `mic.sh` | Each time the streams start |
| `NAME` | `ui.sh` (page title, Frigate entry), `camd.sh` (on-screen text), `wifi.sh` (DHCP host name) | On the page at once; on the video when the camera service restarts; as the host name the next time DHCP starts, at the latest at the next boot |
| `FALLBACK_AFTER`, `AP_MIN_UP`, `AP_IDLE_EXIT` | The Wi-Fi watchdog | When `vaidk-wifi` restarts, or at the next boot |
| `WIFI_COUNTRY` | `ui.sh`, which writes it into each Wi-Fi network it saves; `wifi.sh scan` | For the next network saved |
| `LOCK_CONTROL_API` | `net.sh` | When `vaidk-rtsp` starts. Rules already in place stay until the next boot |
| `ONVIF`, `ONVIF_PORT` | `onvif.sh`; `ui.sh` (the page and the Frigate entry) | When `vaidk-onvif` restarts. Turning pan, tilt and zoom on or off restarts it |
| `DETECT` | `camd.sh`, which passes it to `vaidk-camd`; `detect.sh` | When the camera service and the detector restart. Turning detection on or off on the setup page restarts both |
| `DETECT_OBJECTS`, `DETECT_CONFIDENCE` | `detect.sh`, which passes them to `vaidk-detect` and writes the confidence into VAM's configuration | When `vaidk-detect` restarts. Saving **Object detection** restarts it when they changed |
| `DETECT_FPS`, `DETECT_BOXES` | `camd.sh`, which writes them to `/run/vaidk/camd.conf` for `vaidk-camd` | At once: saving **Object detection** runs `camd.sh reload` |
| `MQTT`, `MQTT_HOST`, `MQTT_PORT`, `MQTT_USER`, `MQTT_TOPIC`, `MQTT_DISCOVERY` | `mqtt.sh`, which passes them to `mqttd.py` | When `vaidk-mqtt` restarts. Saving **MQTT**, turning detection on or off, changing its objects or renaming the camera restarts it |
| `HDMI` | `camd.sh`, which starts or stops the vendor's display server and passes it to `vaidk-camd` | When the camera service restarts. Saving **HDMI output** restarts it |
| `RESTART_ON_CRASH` | `recovery.sh` | At the next boot, or when `vaidk-recovery` restarts |

Besides the settings, the add-on keeps:

| Where | What | Written by |
|---|---|---|
| `/data/misc/vaidk/wpa_supplicant.conf` | The saved Wi-Fi network, with the password's WPA2 key hash | `wifi.sh try`, once it has joined the network |
| `/data/misc/vaidk/admin` | Which user is the admin account, and whether the add-on created or adopted it | `ui.sh` |
| `/data/misc/vaidk/ptz` | The pan, tilt and zoom position, home position and presets | `onvifd.py` |
| `/data/misc/vaidk/models/builtin` | The object detector's model and labels (27 MB), copied from the vendor's vision sample the first time detection starts | `detect.sh` |
| `/data/misc/vaidk/mqtt-password`, `/data/misc/vaidk/mqtt-discovery` | The MQTT broker's password, readable only by root; what was announced to Home Assistant, so it can be removed | `ui.sh`; `mqttd.py`, only when that changes |
| `/data/misc/camera`, `/data/misc/vam` (the vendor's) | While detection is on: the vendor's engine configuration set aside as `va-snpe-engine-library_config.json.vendor`, and links to the add-on's configuration, model, labels and VAM database folder. Put back when detection is turned off, and at uninstall | `detect.sh` |
| `/etc/passwd`, `/etc/shadow`, `/etc/ssh/sshd_config` | The admin account itself, and its `AllowUsers` entry if `sshd` has that list. `/etc` is the vendor's overlay on `/data` | `useradd` and `chpasswd`, run by `ui.sh` |
| `/etc/systemd/system/sockets.target.wants/sshd.socket` | SSH at boot. The image has this link already; it is written again only if SSH had been turned off, for example by the vendor setup | `systemctl enable`, run by `ui.sh` |
| `/systemrw/build.prop` | The vendor's saved properties. While the add-on runs, programs use a copy in RAM ([run-time files](#run-time-files)). `camd.sh` sets one of them, `persist.qmmf.ubwcstream.enable`, for HDMI live view | `storage.sh`, which writes the copy back when it has changed: every 10 minutes, and when it stops |

`ui.sh forget` deletes all of `/data/misc/vaidk`, and the admin account if the add-on created it,
then restarts the ONVIF service so it forgets the presets it holds, and the object detector and the
MQTT service, which find detection off: the detector puts the vendor's files back.
**Reset camera** on the setup page, a new install and an uninstall all run it.

## Boot

```mermaid
flowchart TB
    power["Power on"] --> init["InitCamx.service runs InitCamx.vaidk<br/>the vendor's set-up steps"]
    init --> saved{"Wi-Fi network saved?"}
    saved -- "yes" --> join["wifi.sh boot<br/>Wi-Fi client, DHCP, wifimonitor"]
    saved -- "no" --> ap["The vendor's setup network<br/>MSIoT_XXXXXX at 192.168.143.1"]
    join --> done["/run/vaidk/boot-wifi-done"]
    ap --> done
    done --> rest["The vendor's remaining steps<br/>the /etc overlay, Docker"]
    rest --> altek["altekflow<br/>lights and power button"]
    power --> svc["systemd starts the services"]
    svc --> qmmf["qmmf-server and qmmf-webserver"]
    svc --> rtsp["vaidk-rtsp<br/>net.sh, then rtspd.py"]
    svc --> web["vaidk-web<br/>the setup page"]
    svc --> watch["vaidk-wifi<br/>waits for boot-wifi-done"]
    svc --> recovery["vaidk-recovery<br/>restart after a crash"]
    svc --> storage["vaidk-storage<br/>records crashes at once"]
    svc --> det["vaidk-detect<br/>once /data is mounted; exits unless detection is on"]
    svc --> mqtt["vaidk-mqtt<br/>exits unless MQTT and detection are on"]
    rest -- "/etc overlay, build.prop bound again" --> storage
    storage --> ram["build.prop in RAM<br/>cleanup every 10 minutes"]
    qmmf --> cam["vaidk-camera<br/>waits for the audio calibration, then vaidk-camd"]
    rtsp --> cam
    cam --> streaming["Streaming"]
    cam --> onvif["vaidk-onvif<br/>applies the kept view"]
    cam -. "frames, when detecting" .-> det
    cam -. "starts it for HDMI live view,<br/>stops it otherwise" .-> display["init_display: weston<br/>the vendor's display server"]
    classDef mod fill:#dae8fc,stroke:#6c8ebf,color:#1a1a1a
    classDef os fill:#fff2cc,stroke:#d6b656,color:#1a1a1a
    classDef use fill:#d5e8d4,stroke:#82b366,color:#1a1a1a
    class init,join,done,rtsp,web,watch,recovery,storage,ram,cam,onvif,det,mqtt mod
    class ap,rest,altek,svc,qmmf,display os
    class power,saved,streaming use
```

- **The boot script** is the vendor's own, with five changes
  ([what changes](device/boot/README.md#what-changes)). The vendor file stays untouched; a systemd
  drop-in points `InitCamx.service` at the copy.
- **The services start alongside it.** Three of them wait: the Wi-Fi watchdog waits for the boot
  script's Wi-Fi step; the camera service waits for the vendor media server's audio calibration
  ([start-up](device/camera/README.md#start-up)); and storage upkeep, which starts with the boot
  script and records crashes from then on, waits for the boot script to mount its `/etc` overlay and
  bind the properties file onto it again before it moves that file to RAM
  ([storage upkeep](device/storage/README.md#the-properties-file)). The ONVIF service starts after
  the camera service, crash recovery runs once, as soon as `/data` is mounted, and the object
  detector, also after `/data`, waits for frames whenever the camera service starts.
- **The vendor's display server** no longer starts at boot: a drop-in lets it start only while HDMI
  live view is on, and the camera service starts it then
  ([HDMI live view](device/camera/README.md#hdmi-live-view)).
- **At shutdown** the boot script does nothing. The vendor's ran its whole boot sequence again.
  Storage upkeep stops before the file systems are unmounted: it saves the properties file if it
  changed, and gives the vendor its file back.

Where the add-on lives:

| Location | File system | What |
|---|---|---|
| `/opt/vaidk` | The root, read-only (`mmcblk0p14`) | The add-on. It is on the root because `/data` is mounted `noexec`, so `vaidk-camd` couldn't run from there |
| `/lib/systemd/system` | The root | The nine units, the boot script's drop-in in `InitCamx.service.d/`, the time zone drop-in in `qmmf-server.service.d/`, and the display server's drop-in in `init_display.service.d/` |
| `/home/<admin>` | The root | The admin account's home directory, when the add-on created the account |
| `/data/misc/vaidk` | `/data`, read-write | Your settings, Wi-Fi network, admin account record, the pan, tilt and zoom presets, and the object detector's model |
| `/run/vaidk` | RAM | [Run-time files](#run-time-files) |

Three things write to the root, each remounting it read-write only for as long as it takes: the
installer, `ui.sh` when it creates or deletes the admin account's home directory, and `camd.sh tz`
when the time zone changes.

## Install, setup and reset

### Device states

```mermaid
stateDiagram-v2
    [*] --> vendor
    vendor --> setup: install
    setup --> configured: Save and connect
    configured --> fallback: Wi-Fi lost
    fallback --> configured: Wi-Fi back
    configured --> button: power button
    button --> configured: restart
    configured --> setup: reset
    setup --> vendor: uninstall
    configured --> vendor: uninstall
    vendor: vendor - the camera's original software
    setup: setup - no Wi-Fi network saved
    configured: configured - on your Wi-Fi, streaming
    fallback: fallback - setup network open as well
    button: setup mode - setup network open on request
```

| State | Begins | Ends | `ui.sh info` |
|---|---|---|---|
| vendor | Before the install, and after an uninstall | When the add-on is installed | No `/opt/vaidk` |
| setup | After a new install, **Reset camera**, or the vendor's factory reset | **Save and connect** joins your network, and the camera restarts | `state=setup`, `setup_ap=on` |
| configured | When the camera starts with a saved network | When Wi-Fi is lost, the power button is held, or the camera is reset | `state=configured`, `setup_ap=off` |
| fallback | When the saved network has been unavailable for `FALLBACK_AFTER` | When it is back and the setup network is unused, or after you choose another network on it | `state=configured`, `setup_ap=on` |
| setup mode | When the power button is held for 5 s | **Leave setup mode**, or when the setup network is unused, by restarting the camera | `state=configured`, `setup_ap=on` |

Early in every boot, until the boot script's Wi-Fi step is done, `ui.sh info` reports
`state=starting`.

- **On the setup network** the setup page needs no sign-in, and with no saved network it shows
  first-time setup ([who gets which page](device/web/README.md#who-gets-which-page)).
- **When the setup network opens and closes** in the fallback and setup-mode states is the Wi-Fi
  watchdog's job ([the watchdog](device/wifi/README.md#the-watchdog-wifish-watch)); the timings are
  settings.
- **Reinstalling** with `--keep-settings` keeps the configured state; a new install starts from setup.

### Install

```mermaid
sequenceDiagram
    participant PC as install.ps1 or install.sh on your PC
    participant ADB as adbd on the camera, as root
    participant Dev as install-device.sh on the camera
    PC->>ADB: check the firmware version and the vendor boot script
    PC->>ADB: push device/ to /tmp/vaidk-install, text files with LF endings
    PC->>Dev: install, or install --keep-settings, or uninstall
    Note over Dev: check, build the boot script, check every file, replace /opt/vaidk, install the units
    Dev-->>PC: VAIDK-OK
    PC->>ADB: reboot, then wait for the camera
    loop every 3 s, for up to 4 minutes
        PC->>ADB: sh /opt/vaidk/web/ui.sh info
    end
    Note over PC: print the setup network's name, or the stream URLs
```

- **No network needed.** ADB over USB gives a root shell without authorization on this camera, so the
  installers need neither Wi-Fi nor SSH.
- **What `install-device.sh` does**, step by step: [device/README.md](device/README.md#install-devicesh).
  It builds the new copy in `/opt/vaidk.new` and checks it before replacing `/opt/vaidk`, so a failed
  install leaves the previous one in place, to start again at the next restart. The installers then
  stop without restarting the camera.
- **Uninstall** removes the add-on, its units and settings, puts back the vendor's object-detector
  files, re-enables the vendor preview server, and starts the vendor's display server again, so after
  the restart the camera runs its original software and setup.

## Network ports

| Port | Served by | Who can use it |
|---|---|---|
| 8900/tcp | `rtspd.py`: the main stream, audio and the talk-back channel | Anyone on the network: no sign-in |
| 8901/tcp | `rtspd.py`: the sub stream | Anyone on the network: no sign-in |
| 8080/tcp | `onvifd.py`: ONVIF device, media and PTZ services | Anyone on the network: no sign-in. Its `/local/ptz` address answers only the camera itself |
| 80/tcp | BusyBox `httpd`: the setup page | On the setup network, without sign-in. On your network, the admin account (HTTP Basic) |
| 22/tcp | `sshd`, started on connection | Linux accounts, including the admin account |
| 53, 67/udp | The vendor's `dnsmasq` | Devices on the setup network: addresses, and the captive portal's DNS. Another vendor instance serves an internal bridge, `bridge0` (192.168.225.1), with nothing attached |
| 4000/tcp | `qmmf-webserver` | Rejected from the network (`LOCK_CONTROL_API`) |
| 1080/tcp | `ipc-webserver`, disabled | Rejected from the network (`LOCK_CONTROL_API`) |

Other vendor services listen only on the camera itself (127.0.0.1). ADB is USB only. With MQTT on, the
camera also connects out to your broker (port 1883 by default); it listens for nothing more. The
security trade-offs are in the [README](README.md#security-notes).

## Repository layout

```
README.md                    what it is; install, set up and use it
ARCHITECTURE.md              this document
ASSESSMENT.md                the camera as found
PROVENANCE.md                how each feature works without Azure; where every piece comes from
LICENSE                      MIT, and the third-party licences
install.ps1, install.sh      the installers, run on your PC (Windows; macOS or Linux)
.gitattributes               LF line endings for everything that goes to the camera
.gitignore                   files that must never be committed: from a camera, private, or not ours to share
camd/                        the camera programs' source; camd/README.md
  camd.cpp                   the camera program: camera, tracks, on-screen text, boxes, media socket, main loop
  image.cpp, image.h         picture settings and the digital zoom's crop
  talkback.cpp, talkback.h   talk-back: the talk socket, decoding, the speaker, microphone muting
  liveview.cpp, liveview.h   HDMI live view: the main stream's frames on the vendor's display server
  detect.cpp                 the object detector: VAM, results, boxes, status
  detect_link.h              the messages between the two programs on detect.sock
  common.h                   helpers the source files share
  build.ps1                  cross-compiles them on Windows into device/camera/vaidk-camd and device/detect/vaidk-detect
  android/                   the two Android headers the qmmf headers include (camera metadata ABI, log stub)
  third_party/qmmf-sdk/      Qualcomm's qmmf-sdk headers and NOTICE (BSD-3-Clause)
  third_party/qmmf-webserver/  Qualcomm's video analytics interface header and NOTICE (BSD-3-Clause)
device/                      everything copied to /opt/vaidk on the camera; device/README.md
  defaults.conf              every setting and its default
  common.sh                  paths and helpers the scripts share
  install-device.sh          installs, reinstalls or removes the add-on, on the camera
  boot/                      the boot script's builder and its systemd drop-in
  camera/                    camd.sh, mic.sh, vaidk-camd (built from camd/), the unit, and the display server's drop-in and weston.ini
  rtsp/                      rtspd.py, net.sh and the unit
  onvif/                     onvifd.py, onvif.sh and the unit
  detect/                    detect.sh, objects.txt, vaidk-detect (built from camd/) and the unit
  mqtt/                      mqttd.py, mqtt.sh and the unit
  wifi/                      wifi.sh and the unit
  web/                       ui.sh, www/ (the setup page's files) and the unit
  recovery/                  recovery.sh and the unit
  storage/                   storage.sh and the unit
  lights/                    the docker stand-in for altekflow
```
