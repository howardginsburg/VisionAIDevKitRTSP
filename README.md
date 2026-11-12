# Vision AI DevKit RTSP camera

Turns a retired Microsoft [Vision AI DevKit](https://azure.github.io/Vision-AI-DevKit-Pages/) into a
Wi-Fi RTSP camera for [Frigate](https://frigate.video/), Home Assistant, VLC or any NVR. No Azure
account, IoT Hub or SSH is needed: you install it over USB and finish setup from a phone.

- **Two RTSP streams:** a main stream for recording (up to 4K at 30 fps) and a low-resolution sub
  stream for detection.
- **Microphone audio:** the main stream carries the camera's built-in microphones as AAC, ready for
  recordings and Frigate's audio detection. You can turn it off.
- **Talk-back:** the camera's speaker plays what you say from Frigate's live view or Home
  Assistant's Advanced Camera Card, through a standard two-way audio channel on the main stream. The
  microphones mute while it plays, so you don't hear yourself.
- **Pan, tilt and zoom:** Frigate's and Home Assistant's PTZ controls move a digital view of the
  camera's 4K picture, up to 4x, over ONVIF. Presets are saved on the setup page.
- **Picture and on-screen text:** anti-flicker, exposure, white balance, colour and sharpness
  change on the fly; the date, time and camera name can be burned into the video.
- **Setup page:** first-time setup happens on the camera's own Wi-Fi network. Afterwards, open
  `http://<camera-ip>/` to change the streams, audio, picture, on-screen text, talk-back, pan, tilt
  and zoom presets, Wi-Fi network, camera name or admin account.
- **Recovers by itself:** if a stream stalls, the camera restarts its camera pipeline while players
  stay connected, and if the camera can't reach its Wi-Fi network for 5 minutes it opens its setup
  network so you can pick another one.
- **Status lights:** solid green means the camera is on Wi-Fi and streaming.
- **SSH (optional):** the admin account also signs in over SSH.

## What you need

- A Vision AI DevKit on firmware **v0.5370_Perf** (the installer checks this).
- A USB-C cable to install the add-on from your computer, and the camera's power supply (or another
  USB wall charger) to run it.
- [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools) (`adb`)
  on your computer. Connect the camera and check that `adb devices` lists it.
- A phone or computer with Wi-Fi to finish setup.

## Install

Download this repository (**Code > Download ZIP** on
[its GitHub page](https://github.com/howardginsburg/VisionAIDevKitRTSP), then unzip it) or clone it
with Git:

```sh
git clone https://github.com/howardginsburg/VisionAIDevKitRTSP.git
```

Connect the camera over USB, then run the installer from the repository's folder.

| Computer | Command |
|---|---|
| Windows (PowerShell) | `.\install.ps1` |
| macOS or Linux | `bash install.sh` |

If Windows won't run the script, because running scripts is disabled or the file isn't digitally
signed, run `powershell -ExecutionPolicy Bypass -File .\install.ps1` instead, with any options at
the end. The bypass applies to that run only.

The installer copies the add-on to the camera, installs it and restarts the camera. After about two
minutes the camera opens its setup Wi-Fi network and the installer prints its name.

> [!WARNING]
> Once the installer has finished, move the camera from your computer to its power supply. A
> computer's USB port gives it 500 mA, less than it uses while streaming: the battery runs down even
> though the setup page shows it as charging, and once it is flat the camera stops and has to be
> started again with its power button ([Troubleshooting](#troubleshooting)).

## Set up the camera

1. On a phone or computer, join the Wi-Fi network named `MSIoT_XXXXXX` (the installer shows the
   exact name). The password is on the sticker under the camera; you can also read it with
   `adb shell cat /persist/data/wifi.bin`.
2. A sign-in page opens automatically. If it doesn't, browse to `http://192.168.143.1/`.
3. Choose your Wi-Fi network and enter its password, create the admin account, name the camera,
   pick a stream profile and choose whether to include microphone audio, then select
   **Save and connect**.
4. The page shows the camera's new address. The camera restarts, and its lights turn solid green
   once it is streaming (about two minutes). Switch back to your usual Wi-Fi and open
   `http://<camera-ip>/`, signing in with the admin account.

> [!TIP]
> Reserve the camera's address in your router (DHCP reservation) so the stream URLs never change.

## Streams

| Stream | URL | Default |
|---|---|---|
| Main (record) | `rtsp://<camera-ip>:8900/live` | 1920x1080, 30 fps, H.264, 4 Mbps, plus microphone audio and a talk-back channel |
| Sub (detect) | `rtsp://<camera-ip>:8901/live` | 640x360, 5 fps, H.264, 500 kbps |

- **Audio:** AAC-LC, 48 kHz mono, 64 kbps, on the main stream only.
- **Talk-back:** a send-only G.711 (PCMU or PCMA) audio track, the ONVIF backchannel. Only clients
  that ask for it get it, so players that don't know it, such as VLC, never see it.
- **Keyframes:** one per second on both streams.
- **Transport:** RTSP over TCP only. Players that try UDP first, such as VLC and ffmpeg, switch to TCP
  by themselves; Frigate and go2rtc use TCP already.
- **Other settings:** the setup page offers other resolutions, frame rates, bitrates and H.265 for the
  main stream. The combinations that were tested are listed in
  [device/camera/README.md](device/camera/README.md#settings-it-uses).

### Frigate

The setup page shows this snippet with your camera's address and settings:

```yaml
go2rtc:
  streams:
    vision-ai-devkit:
      - rtsp://192.168.1.50:8900/live#backchannel=0
    vision-ai-devkit_sub:
      - rtsp://192.168.1.50:8901/live
    vision-ai-devkit_twoway:
      - rtsp://192.168.1.50:8900/live
      - ffmpeg:vision-ai-devkit_twoway#audio=opus
cameras:
  vision-ai-devkit:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/vision-ai-devkit
          input_args: preset-rtsp-restream
          roles: [record, audio]
        - path: rtsp://127.0.0.1:8554/vision-ai-devkit_sub
          input_args: preset-rtsp-restream
          roles: [detect]
      output_args:
        record: preset-record-generic-audio-copy
    audio:
      enabled: true
    live:
      streams:
        Main: vision-ai-devkit_twoway
        Sub: vision-ai-devkit_sub
    onvif:
      host: 192.168.1.50
      port: 8080
      user: ""
      password: ""
    motion:
      enabled: true
    detect:
      width: 640
      height: 360
      fps: 5
```

- **`go2rtc`:** Frigate's built-in go2rtc connects to the camera once per stream and
  [restreams](https://docs.frigate.video/configuration/restream) it to Frigate's recorder and
  detector on `127.0.0.1:8554`.
- **`#backchannel=0`:** the recording stream doesn't take the talk-back channel, as Frigate
  [recommends](https://docs.frigate.video/configuration/restream#two-way-talk-restream). go2rtc
  reconnects a stream when someone starts talking, so this also keeps talking from interrupting
  recordings.
- **`_twoway`:** the stream for Frigate's live view, and so for its talk button. The `ffmpeg:` line
  adds an Opus copy of the microphone audio, because WebRTC can't carry AAC.
- `roles: [record, audio]` records the main stream with its sound and feeds it to Frigate's
  [audio detection](https://docs.frigate.video/configuration/audio_detectors).
- `preset-record-generic-audio-copy` keeps the camera's AAC audio as is (Frigate's default
  re-encodes it).
- `audio: enabled: true` turns on audio events (by default speech, yelling, barking and fire
  alarms). Check the audio levels in Frigate's **Debug** view. If they rarely pass Frigate's
  `min_volume`, raise the camera's microphone gain or lower `min_volume`.
- `motion: enabled: true` keeps motion detection on, as Frigate's default, even if you turn object
  detection off. Frigate's **All Cameras** dashboard shows a still image, refreshed once a minute,
  until it sees motion or objects, so without motion detection the camera never goes live there.
- `onvif` gives Frigate's live view its pan, tilt and zoom controls ([below](#pan-tilt-and-zoom)).
  Keep the empty `user` and `password`: without a user, Frigate's ONVIF library fails before it
  sends anything. Add the block in Frigate's configuration editor; Frigate's configuration API
  deletes a setting that is given an empty value.
- With audio off, the snippet leaves out `audio`, `output_args`, the `audio` role and the Opus
  copy. With talk-back off, it leaves out the `_twoway` stream and the `live` section. With pan,
  tilt and zoom off, it leaves out `onvif`.

## Talk-back

Speak through the camera's speaker from Frigate or Home Assistant. The main stream offers a
two-way audio channel (the ONVIF backchannel that go2rtc uses); the camera plays what arrives and
mutes its microphones meanwhile.

- **Frigate:** open the camera's live view and select the microphone button to start talking;
  select it again to stop. Frigate needs
  [WebRTC](https://docs.frigate.video/configuration/live#webrtc-extra-configuration) set up, and you
  must open Frigate over HTTPS: browsers only let a page use the microphone on HTTPS.
- **Home Assistant:** with the [Frigate integration](https://github.com/blakeblackshear/frigate-hass-integration)
  and the [Advanced Camera Card](https://github.com/dermotduffy/advanced-camera-card) (both from
  HACS), add a card like the one below and hold its microphone button to talk. Home Assistant must be
  on HTTPS (Nabu Casa, or your own certificate); Frigate can stay on plain HTTP inside your
  network, because the card reaches it through Home Assistant. The sound itself travels as
  encrypted WebRTC to Frigate's go2rtc (port 8555), which passes it to the camera.

  ```yaml
  type: custom:advanced-camera-card
  cameras:
    - camera_entity: camera.vision_ai_devkit
      live_provider: go2rtc
      go2rtc:
        stream: vision-ai-devkit_twoway
        modes:
          - webrtc
  menu:
    buttons:
      microphone:
        enabled: true
  ```

- **Setup page, Talk-back:** turn it on or off (on by default), set the speaker volume (default 80;
  the scale follows loudness, so 50 is about 12 dB quieter than 100) and choose whether to mute the
  microphones while the speaker plays (on by default). **Test speaker** plays a short chime.
- **One talker at a time:** whoever starts talking keeps the speaker until they pause for a second.
- **Latency:** roughly half a second. The camera buffers 160 ms against network jitter and its
  speaker path adds about 250 ms, on top of the network and go2rtc.
- **Half duplex:** with muting on, the far end doesn't hear the room while the speaker plays. The
  camera's echo cancellation isn't reachable through its camera service, and without muting the
  speaker comes back through the microphones about 50 dB above the room's noise.

## Pan, tilt and zoom

The camera has no motors, so it pans, tilts and zooms digitally: both streams show part of its
3840x2160 sensor picture, and Frigate and Home Assistant move that view with their PTZ controls, over
ONVIF (port 8080). Zoom in first: at the whole picture there is nothing to pan or tilt to, so the
arrows and clicks do nothing until the view is zoomed.

- **Frigate:** with the snippet's `onvif` part, the camera's live view gets arrows, zoom buttons and
  the presets, and you can click on the picture to centre the view there. Frigate reads the presets
  when it starts, so restart it after saving new ones.
- **Home Assistant:** add the camera with the
  [ONVIF integration](https://www.home-assistant.io/integrations/onvif/): the camera's address, port
  8080, and an empty username and password. Its `onvif.ptz` action then moves the view, for example
  (use your camera's entity):

  ```yaml
  action: onvif.ptz
  target:
    entity_id: camera.vision_ai_devkit_main_stream
  data:
    zoom: ZOOM_IN
    distance: 0.25
    move_mode: RelativeMove
  ```

- **Setup page, Pan, tilt and zoom:** turn it on or off (on by default; off shows the whole
  picture), show the whole picture, and save the current view as a preset, go to one or delete one.
  Up to 16 presets.
- **What the view changes:** both streams show only the view, so Frigate records and detects only
  what it shows, and zones and masks drawn on the whole picture don't follow a zoom. Save your usual
  view as a preset to return to it.
- **Detail:** up to 2x, the 1080p main stream keeps the sensor's full detail; beyond that, up to 4x,
  the picture gets softer.
- **Kept:** the view and the presets survive restarts.

How it works: [device/onvif/README.md](device/onvif/README.md).

## Picture and on-screen text

The setup page's **Picture** section changes the image while the streams keep running:

| Setting | Choices | Default |
|---|---|---|
| Light flicker | Automatic, 60 Hz, 50 Hz, off. Set it to your mains frequency if lights band or flicker | Automatic |
| Exposure | -2 to +2, in half steps | 0 |
| White balance | Automatic, daylight, cloudy, shade, twilight, incandescent, fluorescent, warm fluorescent | Automatic |
| Colour | 0 (black and white) to 10 | 5 |
| Sharpness | 0 to 6 | 2 |

**On-screen text** burns the date and time, the camera name, or both, into the video:

- **Position:** the date and time go in the corner you choose; the name goes on the other edge of
  the same side. Both sit on a translucent dark label so they read on any scene.
- **Streams:** the main stream only (default), or both. Frigate detects on the sub stream, where a
  ticking clock can count as motion.
- **Time zone:** pick one from the list or type a POSIX time zone, such as
  `EST5EDT,M3.2.0,M11.1.0`. The camera has no time zone database. It sets its clock from the
  internet, so the time is right once it has been online.
- Changing it restarts the streams (about 15 seconds).

Rotating or flipping the image isn't possible on this firmware; mount the camera the right way up.

## Microphone

The camera's two built-in microphones feed the main stream. The camera's audio processing removes
steady background noise, so a quiet room sounds nearly silent and voices come through clearly.

- **Turn audio on or off:** on the setup page under **Camera streams > Microphone**, or during
  first-time setup.
- **Gain:** 0 to +40 dB (default +24 dB). Raise it if speech is faint in recordings; lower it if
  loud sounds distort.
- **Privacy:** recording sound is regulated in many places, often more strictly than video. Let
  people know the camera records audio, and turn it off where you don't need it.

## Change settings

Open `http://<camera-ip>/` and sign in with the admin account. The page shows the camera's status
(Wi-Fi, address, stream health, microphone, talk-back, pan, tilt and zoom, temperature and battery)
and lets you:

- change the main and sub stream resolution, frame rate, bitrate and codec;
- turn the microphone on or off and set its gain;
- adjust the picture, and choose the on-screen text and its time zone;
- turn talk-back on or off, set the speaker volume and test the speaker;
- turn pan, tilt and zoom on or off, show the whole picture, and save, use or delete presets;
- move the camera to another Wi-Fi network;
- rename the camera and change the admin account;
- restart the streams or the camera, or reset it.

Picture, speaker volume, microphone muting and presets apply straight away; the other changes restart
the streams, except turning pan, tilt and zoom on or off, which restarts only that service. Settings
the page doesn't show, such as the keyframe interval and the Wi-Fi fallback timers, can be changed by
hand ([how](device/README.md#settings)).

## Status lights

| Lights | Meaning |
|---|---|
| Solid red | Starting or shutting down |
| Blinking red | Setup mode: join the camera's setup network |
| Amber | Not connected to Wi-Fi |
| Blinking green | On Wi-Fi; streams are starting or recovering |
| Solid green | On Wi-Fi and streaming |
| Off | Switched off. If it should be on, its battery may have run flat ([Troubleshooting](#troubleshooting)) |

## Change Wi-Fi networks or reset

- **Wi-Fi unavailable:** if the camera can't reach its saved network for 5 minutes, it opens its
  setup network (lights amber). Join it and choose a network as in first-time setup. When the saved
  network comes back and nobody is using the setup network, it closes again.
- **Setup mode on demand:** hold the power button for 5 seconds until the lights blink, then join the
  setup network and open `http://192.168.143.1/`. You don't need to sign in there, so this is also
  how you set a new admin password. The camera leaves setup mode once nobody has used it for a few
  minutes, or when you select **Leave setup mode**.
- **Reset:** on the setup page, tick the box under **Maintenance** and select **Reset camera**. The
  camera forgets its Wi-Fi network, settings and admin account, and restarts in setup mode.
- **Forgot the admin password:** use setup mode (above), or with the camera on USB run
  `adb shell sh /opt/vaidk/web/ui.sh set-admin <user>` and type a new password.

## SSH

SSH is optional. The admin account signs in as `ssh <user>@<camera-ip>` and can use `sudo`.

## Reinstall or uninstall

| Task | Windows | macOS or Linux |
|---|---|---|
| Reinstall, keeping the settings | `.\install.ps1 -KeepSettings` | `bash install.sh --keep-settings` |
| Remove the add-on | `.\install.ps1 -Uninstall` | `bash install.sh --uninstall` |

Uninstalling restores the camera's original software and setup experience. Reflashing the firmware
also removes everything.

## Troubleshooting

- **No camera found:** check the cable, then run `adb devices`. Restart the camera if it isn't
  listed.
- **Status from USB:** `adb shell sh /opt/vaidk/web/ui.sh info`, and for the streams
  `adb shell cat /run/vaidk/rtsp.status`.
- **Logs:** `adb shell journalctl -u vaidk-camera -u vaidk-rtsp -u vaidk-onvif -u vaidk-wifi -u vaidk-web --no-pager -n 50`
- **Boot log:** `adb shell cat /data/misc/wifi/docker_boot`
- **The camera stopped and its lights are off:** its battery may have run flat, for example on a
  computer's USB port. Plug it into its power supply and hold the power button until the lights turn
  red. If they're still off after 15 seconds, let go: holding it that long switches the camera fully
  off. Wait 5 seconds, then hold the button again until the lights turn red. If nothing lights up,
  let it charge for half an hour and try again. As a last resort, press the reset button in the
  pinhole on the right side with a paperclip.
- **No picture:** test the main stream with VLC (**Media > Open Network Stream**) and check that the
  lights are solid green.
- **No sound:** check that the setup page shows the microphone as on, then raise the gain. The
  camera's noise suppression mutes steady background noise, so test by speaking near the camera.
- **Talk-back is silent:** select **Test speaker** on the setup page. If the chime plays, check that
  Frigate's live view (or the Advanced Camera Card) uses the `_twoway` stream and that the page is
  on HTTPS, then look for `talk-back from` in the RTSP server's log and `speaker on` in the camera's.
- **No talk button in Frigate:** the live view must use a stream without any `#` option (the
  `_twoway` stream), and Frigate needs WebRTC and HTTPS.
- **No pan, tilt and zoom controls in Frigate:** check that the setup page shows pan, tilt and zoom
  as on, and that Frigate's configuration has the snippet's `onvif` part with the empty `user` and
  `password`; then look for ONVIF errors in Frigate's log. New presets appear after Frigate restarts.
- **The arrows don't move the view:** zoom in first ([why](#pan-tilt-and-zoom)).
- **Recordings show only part of the picture:** the view is zoomed. Select **Show the whole picture**
  on the setup page, or go to a preset.

## Security notes

- The RTSP streams have no password. Keep the camera on a trusted network or VLAN.
- The talk-back channel has no password either: anything that can reach the main stream can play
  sound on the camera's speaker. Turn talk-back off on the setup page if you don't use it.
- The ONVIF service (port 8080) has no password either: anything on your network can move the view
  and change the presets, which changes what Frigate records. Turn pan, tilt and zoom off on the
  setup page if you don't use it.
- On your network the setup page uses HTTP Basic sign-in, which is not encrypted.
- Anyone who joins the setup network can change settings without signing in. That network is
  protected by the password on the sticker, and normally opens only when you hold the power button,
  after a reset, or when Wi-Fi is unavailable.
- The vendor's own control interfaces (ports 1080 and 4000) are blocked from the network.

## How it works

The add-on keeps the camera's own firmware and its Qualcomm camera service, `qmmf-server`, and
replaces everything above it. A small native program, `vaidk-camd`, runs the camera, the microphone
and the speaker; a Python RTSP server serves the streams and the talk-back channel; a Python ONVIF
service moves the digital view; shell scripts run Wi-Fi, the setup page and the boot sequence,
without the retired IoT Hub step. Nothing needs Azure or any other cloud service.

## Documentation

| Document | What it covers |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the pieces fit together: layers, data flow, settings, boot, install and the camera's states |
| [ASSESSMENT.md](ASSESSMENT.md) | The camera as it came: hardware, software, and why it stopped working out of the box |
| [PROVENANCE.md](PROVENANCE.md) | How each feature was made to work without Azure, how it was tested, and where every piece comes from |
| [device/README.md](device/README.md) | The add-on on the camera, with a README for each component: boot script, camera, RTSP server, pan, tilt and zoom, Wi-Fi, setup page, status lights |
| [camd/README.md](camd/README.md) | The camera program, `vaidk-camd`, and how to rebuild it |

## License

[MIT](LICENSE). Qualcomm's `qmmf-sdk` headers in `camd/third_party/qmmf-sdk/` are BSD-3-Clause; see
their [NOTICE](camd/third_party/qmmf-sdk/NOTICE).
