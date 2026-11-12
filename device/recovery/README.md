# Crash recovery

`vaidk-recovery.service` runs [recovery.sh](recovery.sh) once at boot. It changes how the kernel
handles a crash, so that a crashed camera restarts itself instead of waiting for someone to hold its
power button.

| File | What it is |
|---|---|
| [recovery.sh](recovery.sh) | Applies `RESTART_ON_CRASH` to the kernel |
| [vaidk-recovery.service](vaidk-recovery.service) | systemd unit: runs it once at boot, after `/data` (where the settings are) is mounted |

## What it changes

| Kernel setting | Vendor | `RESTART_ON_CRASH=1` | What it does |
|---|---|---|---|
| `msm_poweroff` `download_mode` | `1` | `0` | Qualcomm's crash-dump mode. On, a panic or a reset by the kernel's watchdog makes the camera wait, dark, for a PC to collect a memory dump (Qualcomm's design; not tried on this camera). Off, the camera starts again |
| `kernel.panic_on_oops` | `0` | `1` | A kernel error panics, instead of leaving the camera running on a damaged kernel |
| `kernel.hung_task_panic` | `0` | `1` | A task stuck for `kernel.hung_task_timeout_secs` (120 s) panics, as when the internal storage stops responding. The kernel notices it 2 to 4 minutes after the task got stuck |
| `kernel.panic` | `5` | `5` | The kernel restarts 5 s after a panic |

- **Order.** `recovery.sh` turns crash-dump mode off before it lets a kernel error panic. With
  `RESTART_ON_CRASH=0` it puts the vendor's values back in the opposite order. Either way, an error
  never ends up in crash-dump mode on the way.
- **Until the next boot.** The values live in the running kernel; nothing is written to the firmware.
  Stopping the service leaves them as they are, so they also hold while the camera shuts down. Once
  the add-on is uninstalled, the next boot has the vendor's values.
- **A repeating error** would restart the camera over and over. In more than four hours of streaming
  with these settings, the kernel reported no error, warning or stuck task. `RESTART_ON_CRASH=0`
  turns restarting off.

## When the camera restarts, and when it is off

| Event | What happens |
|---|---|
| A kernel error | The camera restarts by itself. In the test it was back on the network about 40 s after the crash, and streaming within 2 minutes |
| A stuck task | The same, once the kernel has noticed it |
| A shutdown (`systemctl poweroff`) | The camera restarts about 2 minutes later, with or without a charger: on this firmware a shutdown ends in a restart (the power chip records a hard reset). It can't be switched off from software |
| The power button held for about 12 s | The power chip restarts the camera |
| The battery runs flat | The camera stops. The power chip is set to start it again when a charger is plugged in; this hasn't been tested |

How each was found, and tested, is in [PROVENANCE.md](../../PROVENANCE.md#restart-after-a-crash).

## Settings it uses

| Setting | Default | Meaning |
|---|---|---|
| `RESTART_ON_CRASH` | `1` | `1`: restart after a crash. `0`: the vendor's settings |

It applies at the next boot, or at once with `systemctl restart vaidk-recovery`. The setup page
doesn't show it ([how to change it](../README.md#settings)).

## Logs and checks

```sh
journalctl -u vaidk-recovery --no-pager      # "Restart after a crash: on (...)", once per boot
cat /sys/module/msm_poweroff/parameters/download_mode /proc/sys/kernel/panic_on_oops /proc/sys/kernel/hung_task_panic
```

The kernel's account of a crash doesn't survive the restart: the camera keeps its journal and kernel
log in memory only.
