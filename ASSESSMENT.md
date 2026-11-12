# Vision AI DevKit – Device Assessment

The camera as it came, read over ADB and SSH on firmware v0.5370_Perf: what's in it, why it no longer
works out of the box, and what it can still be. How the add-on builds on this is in
[ARCHITECTURE.md](ARCHITECTURE.md) and [PROVENANCE.md](PROVENANCE.md).

The published specifications come from Arrow's
[product page](https://connect.globalservices.arrow.com/vision-ai-kit) and eInfochips' datasheet.
Everything else was read from the camera itself.

## Hardware

| Item | Finding |
|---|---|
| Board | Vision AI DevKit. The device tree names Qualcomm's "QC605 LC Groot + PM8005 IPC" (IP camera) reference design |
| SoC | Qualcomm QCS603 in the specifications. The kernel and firmware identify it as QCS605 (`soc_id` 347), the same family, and the firmware is a QCS605 build. Its four CPU cores fit the QCS603: the QCS605 has eight |
| CPU | 4 cores of Qualcomm's Kryo 300 series (CPU parts `0x802` ×2 and `0x803` ×2), up to 1.71 GHz (cpu0–1) and 1.59 GHz (cpu2–3). 64-bit cores, running a 32-bit ARMv7 kernel and userland |
| GPU and DSPs | Adreno 615 GPU and Hexagon 685 DSP (specifications). The audio DSP processes the microphones. Qualcomm's SNPE neural-network libraries are installed but unused |
| RAM | Linux sees 1.8 GB (`MemTotal` 1,872,296 kB, including 68 MB reserved for CMA). The specifications say 4 GB LPDDR4x |
| Storage | 16 GB eMMC (`mmcblk0`, 15,388,672 kB) with 66 partitions in A/B slots; slot `_a` active. The datasheet lists a microSD slot; no card was inserted |
| Camera | Sony IMX334, 8 MP (4K). `qmmf-server` loads its driver, `com.qti.sensor.imx334.so`. Drivers for the IMX290, IMX318, IMX362, IMX386 and IMX577 are also installed |
| Audio | Qualcomm WCD934x ("Tavil") audio codec, ALSA card `qcs605-ipc-tavil-snd-card`. The specifications list 4 microphones and a speaker. The vendor's built-in-microphone path (`dmic-endfire`) uses two digital microphones, with the audio DSP's echo and noise processing. One speaker, on a WSA881x smart amplifier (`wsa881x.20170211`; the device tree has four amplifier positions, and the others don't answer). Line-in, line-out and headset jacks |
| Wi-Fi | Qualcomm WCN3980, 802.11ac 1×1 (`wlan` driver): `wlan0` (client), `p2p0`, and `softap0` while the setup network is open |
| Bluetooth | Bluetooth 5 (BLE) in the specifications. Unused |
| Lights | Three, each red and green (`/sys/class/leds/led1` to `led3`) |
| Buttons | The power button (`qpnp_pon`) and `gpio-keys` |
| Power | USB-C power, and PoE in the specifications. A 1,372 mAh Li-ion battery (44 % and charging when first read) |
| Display | HDMI through a USB-C adapter in the specifications: a Lontium LT9611 DSI-to-HDMI bridge on the board, behind the DSI output (`card0-DSI-1`, 1920x1080 and 3840x2160 modes). Linux runs `weston`. Unused |
| Thermal | 47 thermal zones. The vendor's `altekflow` powers the camera off when the battery overheats |

## Software

| Item | Finding |
|---|---|
| Firmware | `v0.5370_Perf` (`/etc/version`; `/etc/os-release` names the product `concam`). Qualcomm meta build `QCS605.LE.1.0-00037-STD.PROD-1`, apps `LE.UM.2.3.3.r1-04300-QCS605.0-1`; DSP firmware built for the SDM710 family. **No updates**: the product is retired |
| Kernel | Linux 4.9.123-perf, built 7 February 2020, 32-bit (`armv7l`). No initramfs. The root file system, `mmcblk0p14`, is mounted read-only but isn't verified (no dm-verity on it), so it can be remounted read-write. SELinux is permissive |
| Userland | Yocto-based: systemd 234, BusyBox 1.24.1, glibc 2.26, libstdc++ 6.0.22 (GCC 6), Python 3.5.3 with part of the standard library, OpenSSH 7.5p1, OpenSSL 1.0.2o (March 2018) |
| Camera stack | Qualcomm's `qmmf-server`: the camera, the image processor, the H.264/H.265 encoders and the microphones, through the CamX camera HAL and the audio HAL. Two vendor front ends: `qmmf-webserver` (RTSP and an HTTP API on port 4000) and `ipc-webserver` (a preview page on port 1080, user `admin`, password `admin`) |
| Azure | IoT Edge 1.0.8.3 (installed, not running) and Docker 3.0.5 (running). The vendor's boot script loads Microsoft's vision sample and IoT Edge containers into Docker |
| Vendor services | `altekflow` (lights, power button, battery protection), `wifimonitor` (Wi-Fi state for the lights), `websettings` (the setup site), `startvirtualsoftap`, `hostapd` and `dnsmasq` (the setup network) |
| Access | ADB over USB: a root shell, with no authorization (`ro.adb.secure` unset). SSH on port 22, socket-activated, for accounts the vendor setup created |
| Disk usage | `/` 2.0 GB used of 3.0 GB (934 MB free); `/data` 1.4 GB used of 4.6 GB |

### Storage layout

| Mount | Partition | Size | Use |
|---|---|---|---|
| `/` | `mmcblk0p14`, `system_a` | 3.0 GB | ext4, read-only: the operating system |
| `/data` | `mmcblk0p66`, `userdata` | 4.6 GB | ext4, `noexec`, `nosuid`: Docker, settings, the `/etc` overlay |
| `/etc` | Overlay | | Upper directory `/data/misc/etc/upper`: changes to `/etc` (accounts, SSH) live on `/data` |
| `/persist` | `mmcblk0p50`, `persist` | 2.2 MB | Per-device data, including the setup network's password (`/persist/data/wifi.bin`) |
| `/firmware` | `mmcblk0p25`, `modem_a` | 110 MB | Firmware images |
| `/systemrw` | `mmcblk0p65`, `systemrw` | 3.9 MB | Persistent system properties |
| `/cache` | `mmcblk0p16`, `cache` | 58 MB | |
| `/run`, `/var/volatile` | tmpfs | 897 MB | Cleared at every boot |

## How the stock camera worked

1. **Setup network.** Out of the box, the camera opened a Wi-Fi network named `MSIoT_` and six
   hexadecimal characters, with the password on the sticker underneath.
2. **Setup site.** `websettings` on `http://192.168.143.1/` asked for a Wi-Fi network and an SSH
   account, then for an Azure IoT Hub.
3. **Azure.** IoT Edge then deployed Microsoft's vision samples as containers, and the camera
   reported to IoT Hub. The "IoT Hub connected" light (solid green) meant IoT Edge's agent container
   was running.

The boot script, `/vendor/etc/camera/InitCamx`, joins the Wi-Fi network only once the setup site has
written `/data/misc/websettings/setting.conf`, which happens after the IoT Hub step. Until then, every
boot opens the setup network again.

## Why it no longer works out of the box

- **Retired.** Microsoft's two Vision AI DevKit repositories are archived:
  [Azure/Vision-AI-DevKit-Pages](https://github.com/Azure/Vision-AI-DevKit-Pages) (2023-04-12) and
  [microsoft/vision-ai-developer-kit](https://github.com/microsoft/vision-ai-developer-kit)
  (2023-06-02).
- **Setup stops before the IoT Hub step.** On this camera the setup site accepted the Wi-Fi network
  and the SSH account, but never showed the IoT Hub page. `setting.conf` was never written, so the
  camera never joined the Wi-Fi network on its own.
- **The vendor's Wi-Fi helper is broken.** Even with `setting.conf`, its `connectap` writes a
  configuration that `wpa_supplicant` can't parse.

## What still works offline

- **The camera stack.** `qmmf-server` captures and encodes without any cloud service. Through it, the
  sensor, the hardware encoders (H.264 and H.265, up to 4K at 30 fps) and the microphones all work.
- **The vendor media server**, `qmmf-webserver`, serves video over RTSP, but its audio can't be played
  by ffmpeg or Frigate, it truncates large keyframes, and it crashes on some client connections
  ([PROVENANCE.md](PROVENANCE.md#camera-and-microphone)).
- **The Wi-Fi tools**: `wpa_supplicant`, `udhcpc`, and the setup network
  (`startvirtualsoftap`, `hostapd`, `dnsmasq`).
- **The lights and the power button** (`altekflow`), the battery protection, SSH and ADB.

## Features beyond the streams

Once streaming worked, the rest of the hardware and the camera service were surveyed for features
worth adding. What was found, and what the add-on does with it:

| Feature | Finding | In the add-on |
|---|---|---|
| Speaker | One speaker on a WSA881x amplifier. `qmmf-server` includes a player (`libqmmf_player_client.so`) that plays PCM, AAC or MP3 on it while the camera records | **Used:** talk-back |
| Echo cancellation | The audio HAL has it (`FX_IID_AEC`, a `speaker-dmic-aec-ns` input), but it can only be switched on through the effects API of the input stream, which `qmmf-server` owns; qmmf's audio track parameters don't reach it | Not reachable; the microphones are muted while the speaker plays instead |
| On-screen text | qmmf overlays: date and time, text, images, boxes and masks, drawn into the encoded video | **Used:** date, time and camera name |
| Image controls | The camera's request settings: 147 entries and 198 vendor tags. Anti-flicker, exposure compensation, white balance, saturation and sharpness work on running streams; `contrast.level` is accepted but changes nothing | **Used:** the **Picture** settings, without contrast |
| Digital zoom | A crop region on the sensor (`android.scaler.cropRegion`), up to 8x of the 3864x2180 active area, set on running streams; both streams follow, centred or not | **Used:** pan, tilt and zoom over ONVIF, up to 4x |
| Still pictures | `CaptureImage` reconfigures the camera: each capture stalled the video for 140 to 550 ms, and four in a row left the camera driver stuck until a forced restart. A JPEG video track made `qmmf-server` abort, and zero-shutter-lag mode at 1080p wouldn't start | Not possible alongside the streams; Frigate and Home Assistant take stills from the stream |
| Rotation and mirroring | qmmf has a rotation parameter, but CamX ignores it at 90 and 180 degrees, portrait sizes make `qmmf-server` abort, and there are no flip or mirror tags | Not possible on this firmware |
| On-device analytics | Qualcomm's SNPE and video analytics libraries (`libSNPE.so`, `libVAManager.so`, `/usr/lib/vam_engines`), and a MobileNet-SSD model in the vendor's Docker image | Unused: Frigate does detection |
| HDMI | The LT9611 bridge and `weston` | Unused |
| USB camera | The USB gadget defines UVC (webcam) and UAC2 (USB audio) functions, not enabled | Unused |
| microSD | A slot, no card | Unused |
| Bluetooth | Bluetooth LE, reachable only through the vendor's `btapp` | Unused |
| Battery | 1,372 mAh. On a computer's USB port it ran down while streaming (13 % to 9 % over a few hours) even though it reported Charging | Shown on the setup page. Use the camera's power supply |

## Conclusion: what can it be?

**A Wi-Fi RTSP camera, on its own firmware.** The options considered:

| Option | Outcome |
|---|---|
| A different operating system | Not pursued. The camera, the encoders and the microphones work only through Qualcomm's closed user-space stack and DSP firmware, built for this kernel and userland. Without them the board would be a Wi-Fi computer without a usable camera |
| The vendor media server, as it is | Rejected: no audio that Frigate can play, corrupted keyframes at 1080p and above, and crashes |
| Containers on the camera's Docker | Not used. A container would still depend on the host's `qmmf-server`, Binder and Qualcomm's client library, so it would isolate little and add a layer to install and debug |
| **A native client of `qmmf-server`**, with an RTSP server, the camera's own Wi-Fi tools and a new setup page | **Chosen.** Keeps the vendor firmware and drivers, needs no cloud, installs over USB, and uninstalls cleanly |

Trade-offs:
- The firmware stays at v0.5370_Perf: no kernel, OpenSSL or OpenSSH updates.
- Everything the add-on runs on the camera is a shell script, Python 3.5 (with what is left of its
  standard library), or a small C++ program built with a GCC 6 toolchain against Qualcomm's qmmf
  client libraries on this firmware.
- The camera keeps its vendor quirks: an audio calibration step at boot, slow audio timestamps, and a
  camera service that stalls when a stream is added to a running camera. The add-on works around
  each ([PROVENANCE.md](PROVENANCE.md#camera-and-microphone)).

## Risks

- **USB means root.** Anyone with the camera and a USB cable has a root shell, as on the stock camera.
- **Open streams and plain HTTP.** RTSP has no password, and the setup page's sign-in isn't encrypted.
  The talk-back channel has no password either, so anything on the network can play sound on the
  speaker while it is on, and neither has the ONVIF service, so anything on the network can move the
  view. With the kernel from 2020 and OpenSSL and OpenSSH from 2018, keep the camera on a trusted
  network or VLAN, never exposed to the internet.
- **Writes to the read-only root.** The installer, the setup page when it creates or deletes the
  admin account's home directory, and `camd.sh tz` when the time zone changes, remount the root file
  system read-write for a moment. A power cut at that moment could damage it, and a damaged root
  means reflashing.
- **The vendor's factory reset** deletes every Docker container and image, and the `/etc` overlay.
  The add-on survives it and starts again in setup mode.
- **Heat.** `altekflow` powers the camera off when its battery overheats. Keep the camera out of
  direct sun and ventilated.
- **One firmware, one camera.** Everything was tested on one camera, on v0.5370_Perf. The installer
  refuses other firmware unless forced.
- **Recovery.** Uninstalling restores the vendor software and setup. Reflashing the firmware restores
  the whole camera.
