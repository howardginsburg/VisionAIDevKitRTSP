# Wi-Fi

`wifi.sh` joins the saved Wi-Fi network at boot, keeps the connection healthy, opens the camera's
setup network when the saved network is unavailable, and joins new networks chosen on the
[setup page](../web/README.md).

| File | What it is |
|---|---|
| [wifi.sh](wifi.sh) | `boot`, `watch`, `scan` and `try` (below) |
| [vaidk-wifi.service](vaidk-wifi.service) | systemd unit for the watchdog (`wifi.sh watch`). `KillMode=process`, so the Wi-Fi client and the setup network keep running when the watchdog restarts |

The saved network is `/data/misc/vaidk/wpa_supplicant.conf` (owner-only): the network name in hex,
and the WPA2 key as the hash `wpa_passphrase` derives from the password, which is never stored.
WPA2-Personal and open networks are supported. A hidden network can be typed in by name, and the
Wi-Fi client probes for it (`scan_ssid=1`), but that hasn't been tested.

## At boot: `wifi.sh boot`

The [boot script](../boot/README.md) runs it when a network is saved. It waits for `wlan0`, stops the
vendor's own Wi-Fi helpers, starts `wpa_supplicant` with the saved network and `udhcpc` (sending the
camera's `NAME` as its host name), and restarts the vendor's `wifimonitor`, which reports the Wi-Fi
state to the status lights. It waits up to 60 s for an address; if there's none yet, the watchdog
carries on.

Without a saved network, the boot script opens the setup network instead (setup mode).

## The watchdog: `wifi.sh watch`

Once the boot script's Wi-Fi step is done, it checks every 10 s:

| Situation | What it does |
|---|---|
| The Wi-Fi client isn't running with the saved network | Restarts it, and DHCP |
| Associated, but no address for 30 s | Renews DHCP |
| The saved network unavailable for `FALLBACK_AFTER` seconds | Opens the setup network, alongside the Wi-Fi client, which keeps trying |
| Setup network open, the saved network back, the setup network open for at least `AP_MIN_UP` seconds and unused for `AP_IDLE_EXIT` seconds | Closes it. When it was opened with the power button, restarts the camera instead, to leave setup mode cleanly |
| A network change is in progress (`/run/vaidk/wifi.lock`) | Waits |

## The setup network

It is the vendor's own: `startvirtualsoftap` adds a second interface, `softap0`, at `192.168.143.1`.
- **Name and password.** The name is `MSIoT_` and six hexadecimal characters. The WPA2 password is on
  the sticker under the camera, and in `/persist/data/wifi.bin`.
- **Captive portal.** The vendor's `dnsmasq` hands out addresses and answers every name with
  `192.168.143.1`, so phones open the setup page as a sign-in page.
- **Who is using it.** The watchdog counts the stations on `softap0`, leaving out the camera's own
  `wlan0`, which the driver lists there too.

It opens:
- at boot, without a saved network;
- after the saved network has been unavailable for `FALLBACK_AFTER` seconds (lights amber);
- when the power button is held for 5 s: the vendor controller (`altekflow`) runs
  `/etc/wlanstart con-softap` (lights blink red).

## Joining a network: `wifi.sh try FILE [yes]`

The setup page writes the chosen network to `/run/vaidk/candidate.conf` and runs `try` in the
background, then shows its progress from `/run/vaidk/wifi-try`:
1. Restarts the Wi-Fi client with the new network and waits up to 45 s for an address.
2. **Success:** saves it as the network (`ok <address>`). With `yes` (from setup mode), restarts the
   camera 20 s later, long enough for the page to show the new address.
3. **Failure:** reports why (`failed wrong-password`, `failed not-found` or `failed no-address`) and
   goes back to the saved network, or to scanning when there is none.

From your own network, the page warns that it will stop responding: the camera moves to the new
network straight away, and comes back if it can't join within a minute.

## Scanning: `wifi.sh scan`

Prints nearby networks as `signal<TAB>name`, strongest first, each name once. In setup mode, with no
Wi-Fi client running, it starts a scan-only one. Results arrive band by band, so it collects them for
4 to 10 s.

## Settings it uses

`FALLBACK_AFTER`, `AP_MIN_UP`, `AP_IDLE_EXIT` (seconds), `WIFI_COUNTRY` (regulatory domain) and
`NAME` (DHCP host name). Defaults and meanings are in [defaults.conf](../defaults.conf).

## Logs and checks

```sh
journalctl -u vaidk-wifi --no-pager -n 30
wpa_cli -p /var/run/wpa_supplicant -i wlan0 status
grep vaidk /data/misc/wifi/docker_boot               # the boot script's Wi-Fi step
sh /opt/vaidk/wifi/wifi.sh scan
```
