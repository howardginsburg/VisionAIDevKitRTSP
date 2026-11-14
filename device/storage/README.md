# Storage upkeep

`vaidk-storage.service` runs [storage.sh](storage.sh) for as long as the camera runs. It keeps the
camera's flash from wearing out, and its RAM file systems from filling up:
- **The vendor's properties file lives in RAM.** The vendor's software rewrites it on flash about
  twice a second; the add-on saves it to flash only when it has changed.
- **Crashes are recorded without crash dumps.** The vendor's settings keep a full memory dump of
  every crashed program in RAM until the next boot.
- **Every 10 minutes it cleans up**, as listed under [Cleanup](#cleanup).

| File | What it is |
|---|---|
| [storage.sh](storage.sh) | The service (`run`), and the `stop`, `cleanup` and `crash` commands |
| [vaidk-storage.service](vaidk-storage.service) | systemd unit: starts once the boot script has started, and stops before the file systems are unmounted |

Why: [what the camera writes, as found](../../ASSESSMENT.md#writes-and-logs). How it was tested:
[PROVENANCE.md](../../PROVENANCE.md#storage-and-flash-wear).

## The properties file

The vendor keeps its saved (`persist.`) properties in `/systemrw/build.prop`, on the flash, and binds
the same file onto `/etc/build.prop`. Its property service, `leprop-service`, rewrites the whole file
in place whenever a program sets a property, and the LED controller, `altekflow`, sets two of them
about twice a second, to the values they already hold.

- **At boot**, the boot script mounts the vendor's overlay on `/etc`, then binds the file onto it
  again, about 25 s into the boot. Once it has, `storage.sh` copies the file to
  `/run/vaidk/build.prop`, with its owner, mode and SELinux label, and binds the copy over
  `/systemrw/build.prop`. Mount propagation carries that bind to both `/etc/build.prop` mounts too;
  `storage.sh` binds them itself if it didn't. From then on, every program that reads or sets a
  property uses the copy, in RAM.
- **Every 10 minutes**, and when the service stops, it compares the copy with the file on flash. If
  they differ, it writes the copy back in place: the vendor's binds hold on to that very file. It
  reaches the file on flash through a private bind of `/systemrw` in `/run/vaidk`, which the other
  binds don't cover, and removes that bind again straight away.
- **When the service stops**, at shutdown or with `systemctl stop vaidk-storage`, it saves the copy,
  then removes its own binds. The vendor's stay as they were.
- **A power cut** loses the property changes of the last 10 minutes at most. The ones the vendor
  makes while running (the Wi-Fi state, the lights' state) are set again at every boot.

## Crashes

The vendor's `kernel.core_pattern`, `/var/tmp/core.%e.%p.%s.%t`, writes a full memory dump of each
crashed program to `/var/tmp`, which is RAM. At start, `storage.sh` sets it to
`|/bin/sh /opt/vaidk/storage/storage.sh crash %s %e`, so the kernel runs `storage.sh crash` with the
signal and the program's name instead. That command:
1. closes the dump's pipe, so the kernel stops writing the dump;
2. adds `TIME NAME SIGNAL` to `/run/vaidk/crashes`, which keeps the last 50;
3. writes `<name> crashed (signal N); no crash dump was kept` to the kernel log, and so to the journal.

The setup page's **System** section counts the crashes since the camera started, and shows the
latest. A crash before the service started still leaves a dump in `/var/tmp`; the first cleanup
deletes it and records it the same way. Stopping the service puts the vendor's pattern back.

## Cleanup

Every 10 minutes, the first time as soon as the properties file is in RAM:

| What | Where | What happens |
|---|---|---|
| The properties file | `/run/vaidk/build.prop`, RAM | Saved to flash, only if it changed |
| Crash dumps | `/var/tmp/core.*`, RAM | Deleted, and recorded as crashes |
| Login records | `/var/log/wtmp` and `/var/log/btmp`, RAM | Emptied once over 1 MB. They grow with every SSH sign-in and every failed attempt |
| The Wi-Fi join log | `/run/vaidk/wifi-try.log`, RAM | Trimmed to its last 200 lines |

`storage.sh` writes to the journal only when one of these did something. The rest of what the camera
writes is already bounded, or stays put
([ASSESSMENT.md](../../ASSESSMENT.md#writes-and-logs)): the system log and syslog live in RAM with
size limits, and `/data` doesn't grow by itself.

## Logs and checks

```sh
journalctl -u vaidk-storage --no-pager       # the file moved to RAM; saves; deleted crash dumps
journalctl -t vaidk-storage --no-pager       # crashes, while the journal still holds them
cat /run/vaidk/crashes                       # every crash since the camera started: TIME NAME SIGNAL
stat -c '%n %d:%i' /systemrw/build.prop /etc/build.prop /run/vaidk/build.prop   # one file, three names
cat /proc/sys/kernel/core_pattern
sh /opt/vaidk/storage/storage.sh cleanup     # save and clean up now
```

It has no settings. Uninstalling stops it, which gives the vendor its file and crash dumps back.
