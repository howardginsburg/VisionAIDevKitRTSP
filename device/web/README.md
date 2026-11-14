# Setup page

`vaidk-web.service` serves the camera's setup page on port 80 with BusyBox `httpd`; the pages come
from `ui.sh`, a shell CGI script. The same script is the command-line tool for the admin account and
the installers' status check.

| File | What it is |
|---|---|
| [ui.sh](ui.sh) | Every page and form, and the commands below |
| [www/](www/) | Document root: `cgi-bin/index.cgi` (`/`), `cgi-bin/admin.cgi` (signed in), `style.css`, and the captive-portal answers |
| [vaidk-web.service](vaidk-web.service) | systemd unit. Before starting `httpd`, writes its sign-in rule (`/run/vaidk/httpd.conf`) |

## Who gets which page

| You are on | You open | Sign-in | You get |
|---|---|---|---|
| The camera's setup network (`192.168.143.x`) | `http://192.168.143.1/` (any address, through the captive portal) | None | First-time setup when no Wi-Fi network is saved, otherwise the settings |
| Your network | `http://<camera-ip>/` | None | A redirect to `/cgi-bin/admin.cgi`, or, before an admin account exists, how to reach setup mode |
| Your network | `http://<camera-ip>/cgi-bin/admin.cgi` | The admin account (HTTP Basic) | The settings |

- **The setup network is trusted.** Joining it needs the WPA2 password on the camera's sticker, and it
  only opens at first setup, after a reset, when Wi-Fi is unavailable, or when you hold the power
  button. The [RTSP server's](../rtsp/README.md#network-settings-netsh) firewall rule drops that subnet
  arriving over the camera's Wi-Fi client, and `ui.sh` checks the client address again.
- **On your network, `httpd` checks the sign-in** against the admin account's Linux password
  (`/etc/shadow`); `ui.sh` then checks that the signed-in user is the admin account. Before an admin
  account exists, the rule names a user that can't sign in.

## The pages

**First-time setup** (setup network, no saved Wi-Fi network):
1. **Your Wi-Fi.** A list of nearby networks, or a name typed in, and the password.
2. **Admin account.** Signs in to this page from your network, and over SSH, which saving it turns
   on.
3. **Camera.** The name, the stream profile (1080p main + 640x360 sub, or 4K main + 720p sub) and
   whether to include the microphone.

**Save and connect** saves the account and settings and joins the network
([`wifi.sh try`](../wifi/README.md#joining-a-network-wifish-try-file-yes)). A progress page shows the
camera's new address, then the camera restarts.

**Settings:**

| Section | What it shows or changes |
|---|---|
| Status | Wi-Fi network and signal, address, stream health, the stream URLs, microphone, talk-back, pan, tilt and zoom |
| System | The camera's health, measured as the page loads ([what each line shows](#the-system-section)). **Refresh** measures again |
| Camera streams | Main: resolution, frame rate, bitrate, codec. Sub: on or off, resolution, frame rate, bitrate. Microphone: on or off, gain. Saving restarts the camera service |
| Picture | Light flicker, exposure, white balance, colour and sharpness. Saving applies them at once (`camd.sh reload`) |
| On-screen text | Date and time, camera name or both; the corner; main stream or both; the time zone (a list, or a POSIX string). Saving updates `qmmf-server`'s time zone if it changed (`camd.sh tz`) and restarts the camera service |
| Talk-back | On or off, speaker volume, muting the microphones while the speaker plays. Volume and muting apply at once; turning talk-back on or off restarts the camera service. **Test speaker** plays a chime (`camd.sh chime`) |
| Pan, tilt and zoom | The [ONVIF service](../onvif/README.md) on or off (saving restarts it), the current zoom, **Show the whole picture**, and the presets: go to, delete, or save the current view under a name. It asks the service over its local address ([the setup page](../onvif/README.md#the-setup-page)) |
| Wi-Fi | Join another network |
| Camera name and admin account | The name (page title, Frigate name, on-screen name, DHCP host name), the admin user and password |
| Frigate | Frigate configuration built from the current settings: go2rtc streams (with a separate two-way stream when talk-back is on) and the camera entry, with its `onvif` part when pan, tilt and zoom is on |
| Maintenance | Restart the streams; restart the camera (on the setup network: leave setup mode); reset the camera |

**Reset camera** forgets the Wi-Fi network, the settings, the pan, tilt and zoom presets and the admin
account, then restarts in setup mode.

### The System section

`ui.sh` reads the kernel's counters twice, one second apart, and works out the rates from the
difference, so the settings page takes about a second longer to load.

| Line | What it shows | Read from |
|---|---|---|
| Processor | How busy the processor was, overall and per core; whether its top speed is held back, for example by heat | `/proc/stat`; each cluster's `scaling_max_freq` against its `cpuinfo_max_freq` |
| Busiest programs | The five programs that used the most processor time, in % of one core. The add-on's Python services are named by their script | `/proc/<pid>/stat` (user and system time) and, for Python, `/proc/<pid>/cmdline` |
| Memory | Memory in use: the total minus what is available | `/proc/meminfo` |
| Temperatures | The hottest processor core, the camera and the Wi-Fi chip. The battery's sensor reads 40.0 °C at every reading on this camera, so it isn't shown | The thermal zones `cpu*-usr`, `camera-usr` and `wlan-usr` |
| Data storage, System storage | Space used on `/data` (settings, Docker's images) and on the read-only root | `df` |
| Logs and temporary files | Space used in RAM by `/run` and `/var/volatile`, and the system log's limit | `df`; `RuntimeMaxUse` in `/etc/systemd/journald.conf` |
| Flash writes | What has been written to the flash since the camera started, and the average per day | `/sys/block/mmcblk0/stat` |
| Flash wear | The flash chip's own estimate of its rated life used, and a warning if its spare blocks run low | `life_time` and `pre_eol_info` in `/sys/block/mmcblk0/device` |
| Battery, Power | Charge, state and voltage; the power source, with a warning on a computer's USB port, where the battery can run down while streaming | `/sys/class/power_supply`: `battery`, `usb`, `pc_port`, `dc` |
| Wi-Fi link | Band, channel and transmit rate | `iw dev wlan0 link` |
| Wi-Fi traffic | Sent and received during that second, and since the camera started | `wlan0`'s byte counters |
| Stream viewers | The address of each player connected to the main and sub streams | Established connections to ports 8900 and 8901 in `/proc/net/tcp` and `tcp6` |
| Crashes since start | How many programs crashed since the camera started, and the latest | `/run/vaidk/crashes`, kept by [storage upkeep](../storage/README.md#crashes) |
| Running for, Firmware | Time since the camera started; the firmware version | `/proc/uptime`, `/etc/version` |

## The admin account

The admin account is a Linux user: it signs in to this page and over SSH, and can use `sudo`.
- **New user.** Created with a home directory and the groups `sudo`, `inet` and `sdcard`. (The vendor
  setup's accounts also join `docker` and `iotedge`, which the add-on doesn't use.) Home directories
  are on the read-only root file system, so `ui.sh` remounts it read-write (`with_rw_root` in
  `common.sh`) for the moment it takes to create or delete one. If `sshd` only admits listed users
  (an `AllowUsers` line), it is added there.
- **Existing user.** An existing member of `sudo`, such as an account from the vendor setup, is
  adopted rather than created.
- **SSH.** Creating, changing or adopting the account also turns SSH on, now and at every boot
  (`systemctl enable` and `start` for `sshd.socket`), as the vendor setup did when its
  **SSH enabled** box was ticked; unticked, that setup turned SSH off. If SSH still isn't running
  afterwards, `ui.sh` says so on standard error and carries on. The add-on never turns SSH off.
- **Changing the account.** Choosing another user deletes an account the add-on created, but never
  an adopted one.
- **Record.** The account is recorded in `/data/misc/vaidk/admin` as `<user> created` or
  `<user> adopted`.

## Safeguards

- Every form carries a token, new at each boot (`/run/vaidk/csrf`), so another site can't submit it.
- Every field is checked: camera settings must be one of the offered choices (or the value already
  saved, so a setting changed by hand survives saving the page); names, user names and passwords
  have length and character limits; control characters are refused.
- Settings are read back by the shell (`load_settings`), so a typed time zone may only use letters,
  digits and `+ : , . / -`, which need no quoting.
- Preset names may only use letters, digits, spaces, `.`, `_` and `-` (up to 32, starting with a
  letter or digit), and preset tokens only digits, before they go into a request to the ONVIF
  service.
- Output is HTML-escaped by `ui.sh` itself: BusyBox's own escaping breaks UTF-8 network names.
- Passwords go to `chpasswd` on its standard input, never on a command line. The Wi-Fi password is
  stored only as its WPA2 key hash.
- Responses that aren't `200 OK` (redirects, `403`) write their full status line: this BusyBox turns a
  CGI `Status:` header into `HTTP/1.0  303` with two spaces, which strict HTTP clients reject.

## Captive portal

Phones and computers test the network when they join it. The setup network's DNS sends those tests to
the camera, and these files answer them with a page that opens the setup page:

| File | Answers |
|---|---|
| `hotspot-detect.html` | Apple devices (`/hotspot-detect.html`) |
| `generate_204/index.html` | Android and Chrome (`/generate_204`) |
| `connecttest.txt` | Windows (`/connecttest.txt`) |
| `redirect/index.html` | Windows (`/redirect`) |

## Commands

Run on the camera as root (`adb shell`, or SSH with `sudo`):

```sh
sh /opt/vaidk/web/ui.sh info               # state, address, setup network, streaming, microphone, admin
sh /opt/vaidk/web/ui.sh set-admin <user>   # create or update the admin account; reads the password
sh /opt/vaidk/web/ui.sh adopt-admin <user> # make an existing sudo account the admin
sh /opt/vaidk/web/ui.sh forget             # forget Wi-Fi, settings, presets and the admin account
sh /opt/vaidk/web/ui.sh reset              # forget everything, then restart into setup mode
```

`info` prints `key=value` lines: `state` (`starting`, `setup` or `configured`), `ip`, `setup_ap`,
`setup_ssid`, `streaming`, `audio` and `admin`. The installers use it to follow the camera's restart.
