# Boot script

At every boot, `InitCamx.service` runs the vendor script `/vendor/etc/camera/InitCamx`. It prepares
the camera libraries, sets up Wi-Fi, mounts the `/etc` overlay, starts the vendor setup site and
starts the LED and power-button controller. Its Wi-Fi step only works once the vendor's setup has
finished, which needs the retired Azure IoT Hub step. The add-on runs a modified copy instead,
`InitCamx.vaidk`, and leaves the vendor file untouched.

| File | Installed to | What it is |
|---|---|---|
| [make-initcamx.py](make-initcamx.py) | `/opt/vaidk/boot/` | Builds `InitCamx.vaidk` from the camera's own vendor script |
| [InitCamx-vaidk.conf](InitCamx-vaidk.conf) | `/lib/systemd/system/InitCamx.service.d/vaidk.conf` | systemd drop-in: `InitCamx.service` runs `InitCamx.vaidk` instead of the vendor script |
| `InitCamx.vaidk` | `/opt/vaidk/boot/` | Built on the camera during install; not in this repository |

## What changes

| Vendor script | `InitCamx.vaidk` |
|---|---|
| Joins Wi-Fi only after the vendor setup has written `/data/misc/websettings/setting.conf`, which needs IoT Hub. Its `connectap` helper writes a configuration `wpa_supplicant` can't parse | With a saved network (`/data/misc/vaidk/wpa_supplicant.conf`), runs [`wifi.sh boot`](../wifi/README.md). Without one, opens the vendor setup network exactly as the vendor script does |
| A vendor factory reset deletes `/data/misc/etc` (the `/etc` overlay) | When that happens, also deletes the add-on's saved settings, so the camera starts in setup mode |
| Starts the vendor setup site (`websettings`) on port 80 | Leaves port 80 to the [setup page](../web/README.md) |
| `InitCamx stop` runs the whole boot sequence again at shutdown | `stop` does nothing |
| Starts `altekflow`, the LED and power-button controller | Starts it with `/opt/vaidk/lights` first on its `PATH` ([status lights](../lights/README.md)) |

Everything else runs exactly as the vendor wrote it. When the Wi-Fi step is done, the script creates
`/run/vaidk/boot-wifi-done`, which the [Wi-Fi watchdog](../wifi/README.md) waits for. Its lines in the
vendor's boot log, `/data/misc/wifi/docker_boot`, start with `vaidk:`.

## How it is built

The vendor script has no licence, so this repository doesn't contain a copy of it. During install,
[install-device.sh](../install-device.sh) runs:

```sh
python3 /opt/vaidk.new/boot/make-initcamx.py /vendor/etc/camera/InitCamx /opt/vaidk.new/boot/InitCamx.vaidk
```

`make-initcamx.py`:
1. Checks the input's MD5 against the vendor script of firmware v0.5370_Perf (`KNOWN_IN`).
2. Finds each place it changes (`timestampLog "WiFi setup"`, the vendor setup-network block, the
   `websettings&` line, `altekflow &`), each of which must appear exactly once.
3. Replaces the Wi-Fi section, keeping the vendor's setup-network block as it is, removes
   `websettings`, prefixes `altekflow` with the new `PATH`, and adds a header describing the
   changes.
4. Checks the result's MD5 against the script tested on that firmware (`KNOWN_OUT`), then writes it.

On other firmware the installer stops at step 1. `FORCE=1` skips both MD5 checks; every change point
must still be found exactly once. `make-initcamx.py --check FILE` only checks the input.

## Check it

On the camera:

```sh
diff /vendor/etc/camera/InitCamx /opt/vaidk/boot/InitCamx.vaidk          # every change
python3 /opt/vaidk/boot/make-initcamx.py /vendor/etc/camera/InitCamx /tmp/InitCamx.check \
  && cmp /tmp/InitCamx.check /opt/vaidk/boot/InitCamx.vaidk && echo identical
systemctl cat InitCamx.service | grep ExecStart                            # the drop-in is active
cat /data/misc/wifi/docker_boot                                            # this boot's log
```

Uninstalling removes the drop-in, so the vendor script runs again from the next boot.
