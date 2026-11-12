# The add-on on the camera

Everything in this folder is copied to `/opt/vaidk` on the camera by the installers
([install.ps1](../install.ps1) and [install.sh](../install.sh) on your PC, which run
[install-device.sh](install-device.sh) on the camera). Each component has its own folder and README.

| Component | Folder | What it does | Runs as |
|---|---|---|---|
| [Boot script](boot/README.md) | `boot/` | Boots the camera without the vendor's IoT Hub setup: joins the saved Wi-Fi network or opens the setup network | `InitCamx.service`, through a drop-in |
| [Camera](camera/README.md) | `camera/` | Runs `vaidk-camd`, which drives the camera, microphone and speaker and hands the encoded streams to the RTSP server | `vaidk-camera.service` |
| [RTSP server](rtsp/README.md) | `rtsp/` | Serves the main stream (with audio and the talk-back channel) on port 8900 and the sub stream on port 8901 | `vaidk-rtsp.service` |
| [Pan, tilt and zoom](onvif/README.md) | `onvif/` | The ONVIF service on port 8080: Frigate and Home Assistant find the streams and move the digital view through it | `vaidk-onvif.service` |
| [Wi-Fi](wifi/README.md) | `wifi/` | Keeps Wi-Fi connected, opens the setup network when it can't, joins new networks | `vaidk-wifi.service` |
| [Setup page](web/README.md) | `web/` | First-time setup on the setup network, and settings at `http://<camera-ip>/` | `vaidk-web.service` |
| [Crash recovery](recovery/README.md) | `recovery/` | Has the kernel restart the camera after a crash, instead of leaving it unresponsive | `vaidk-recovery.service` |
| [Status lights](lights/README.md) | `lights/` | Makes the vendor's "IoT Hub connected" light mean "streaming" | The vendor LED controller, `altekflow` |

The camera program's source and build script are in [camd/](../camd/README.md); its build output is
`camera/vaidk-camd`. How the components work together is in [ARCHITECTURE.md](../ARCHITECTURE.md).

## Shared files

| File | What it is |
|---|---|
| [defaults.conf](defaults.conf) | Every setting and its default value, with comments. The one place defaults are defined |
| [common.sh](common.sh) | Paths and helpers the shell scripts share: `load_settings`, `set_setting`, `with_rw_root`, `wlan_ip`, `admin_user` |
| [install-device.sh](install-device.sh) | Installs, reinstalls or removes the add-on (run by the installers, as root) |

### Settings

`load_settings` reads `defaults.conf`, then `/data/misc/vaidk/vaidk.conf`, which holds whatever was
changed on the setup page and overrides the defaults. The setup page writes `vaidk.conf` through
`set_setting`, after checking each value against the choices it offers. To change a setting the page
doesn't show, add the line from `defaults.conf` to `vaidk.conf` with a new value, then restart the
camera. Which component reads which setting is in
[ARCHITECTURE.md](../ARCHITECTURE.md#settings-one-file-two-ways-to-change-it).

## install-device.sh

```sh
sh install-device.sh install                  # install; the camera then starts in setup mode
sh install-device.sh install --keep-settings  # reinstall, keeping Wi-Fi, admin account and settings
sh install-device.sh uninstall                # remove the add-on and its settings
```

The installers push this folder to `/tmp/vaidk-install`, run the script there and restart the camera.
It prints `VAIDK-OK` as its last line when everything worked. Running it by hand is the same:
`adb push device /tmp/vaidk-install`, then `adb shell sh /tmp/vaidk-install/install-device.sh install`,
then `adb reboot`. (The installers also make sure the text files have Unix line endings.)

**Install:**
1. **Checks** it is running as root on a Vision AI DevKit whose vendor boot script is the tested one
   (firmware v0.5370_Perf). `FORCE=1` installs on other firmware; that is untested.
2. **Stops** the add-on's services and remounts the read-only root file system read-write.
3. **Copies** the folder to `/opt/vaidk.new`, and builds `boot/InitCamx.vaidk` there from the
   camera's own vendor boot script ([boot/README.md](boot/README.md)).
4. **Checks** every shell script with `sh -n`, the boot script with `bash -n`, the RTSP and ONVIF
   servers with Python's compiler, and that `camera/vaidk-camd` is still an ARM executable. Only then
   does it replace `/opt/vaidk`.
5. **Installs** each component's unit in `/lib/systemd/system` (enabled for `multi-user.target`) and
   the boot drop-in `/lib/systemd/system/InitCamx.service.d/vaidk.conf`, then remounts the root
   read-only.
6. Without `--keep-settings`, **forgets** the saved Wi-Fi network, settings, presets and admin
   account, so the camera starts in setup mode.
7. **Sets the on-screen clock's time zone** in `qmmf-server`'s drop-in,
   `/lib/systemd/system/qmmf-server.service.d/vaidk.conf` (`camera/camd.sh tz`).
8. **Disables** the vendor preview server (`ipc-webserver`) and stops the vendor setup site.

**Uninstall** stops the services, forgets the settings and the admin account (if the add-on created
it), and removes `/opt/vaidk`, the units and both drop-ins. The vendor preview server is enabled
again, so after a restart the camera runs its original software and setup.
