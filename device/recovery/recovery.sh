#!/bin/sh
# Vision AI DevKit RTSP add-on: has the camera restart itself after a crash. Out of the box, nothing
# restarts a camera that a kernel error has left unresponsive, and a kernel panic goes to Qualcomm's
# crash-dump mode, which waits for a PC. RESTART_ON_CRASH=1 turns the crash-dump mode off, then has
# the kernel restart the camera 5 s after a kernel error, or after a task has been stuck for 2
# minutes. RESTART_ON_CRASH=0 puts the vendor's settings back.
. /opt/vaidk/common.sh
load_settings
DUMP_MODE=/sys/module/msm_poweroff/parameters/download_mode

if [ "$RESTART_ON_CRASH" = 1 ]; then
    # Crash-dump mode goes off first, so that a kernel error never ends up in it.
    if [ -e "$DUMP_MODE" ]; then echo 0 > "$DUMP_MODE"; fi
    if [ -e "$DUMP_MODE" ] && [ "$(cat "$DUMP_MODE")" != 0 ]; then
        echo "Restart after a crash: off, because crash-dump mode couldn't be turned off"
        exit 0
    fi
    echo 5 > /proc/sys/kernel/panic
    echo 1 > /proc/sys/kernel/panic_on_oops
    echo 1 > /proc/sys/kernel/hung_task_panic
    echo "Restart after a crash: on (kernel errors, and tasks stuck for $(cat /proc/sys/kernel/hung_task_timeout_secs) s)"
else
    echo 0 > /proc/sys/kernel/panic_on_oops
    echo 0 > /proc/sys/kernel/hung_task_panic
    if [ -e "$DUMP_MODE" ]; then echo 1 > "$DUMP_MODE"; fi
    echo "Restart after a crash: off (the vendor's settings)"
fi
