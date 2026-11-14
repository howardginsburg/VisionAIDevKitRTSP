#!/bin/sh
# Vision AI DevKit RTSP add-on: keeps the camera's storage from filling up or wearing out.
#   storage.sh run             the service: records crashes, moves the vendor's properties file to
#                              RAM once the boot script has bound it, then cleans up every 10 minutes
#   storage.sh stop            saves the properties file to flash and gives the vendor its file back
#   storage.sh cleanup         saves the properties file if it changed, deletes crash dumps, trims logs
#   storage.sh crash SIG NAME  run by the kernel when a program crashes (kernel.core_pattern)
PATH=/usr/sbin:/usr/bin:/sbin:/bin # the kernel runs "crash" with an empty environment
. /opt/vaidk/common.sh

PROPS=/systemrw/build.prop    # the vendor's saved properties, on flash
PROPS_BIND=/etc/build.prop    # the boot script binds the same file here, over the /etc overlay
PROPS_RAM=$RUN_DIR/build.prop # the copy in use while the add-on runs
CRASHES=$RUN_DIR/crashes      # one line per crash: TIME NAME SIGNAL
VENDOR_CORE_PATTERN=/var/tmp/core.%e.%p.%s.%t
CORE_PATTERN="|/bin/sh $VAIDK_DIR/storage/storage.sh crash %s %e"

mounted() { grep -q " $1 " /proc/mounts; }
same_file() { # same_file A B: both paths show the same file (a bind mount shows the file it binds)
    a=$(stat -c %d:%i "$1" 2>/dev/null) && [ "$a" = "$(stat -c %d:%i "$2" 2>/dev/null)" ]
}
keep_last() { # keep_last FILE LINES, in place, so that whatever appends to the file carries on
    if [ -f "$1" ] && [ "$(wc -l < "$1")" -gt "$2" ]; then
        tail -n "$2" "$1" > "$1.tmp" && cat "$1.tmp" > "$1"
        rm -f "$1.tmp"
    fi
}
record_crash() { # record_crash TIME SIGNAL NAME
    mkdir -p "$RUN_DIR"
    name=$(printf '%s' "$3" | tr -c 'A-Za-z0-9_.-' _)
    printf '%s %s %s\n' "$1" "${name:-unknown}" "$2" >> "$CRASHES"
    keep_last "$CRASHES" 50
}

# The vendor's LED controller (altekflow) sets the same two properties about twice a second, and each
# time the vendor's property service (leprop-service) rewrites this file on flash: gigabytes of
# writes a day (ASSESSMENT.md). In RAM they cost nothing; save_props writes the file to flash only
# when it changed.
save_props() {
    [ -f "$PROPS_RAM" ] || return 0
    # A private bind of the partition shows the file on flash, without the binds that cover it.
    view=$RUN_DIR/flash.$$
    mkdir -p "$view"
    if mount --bind /systemrw "$view" && mount --make-private "$view" && [ -f "$view/build.prop" ]; then
        if ! cmp -s "$PROPS_RAM" "$view/build.prop"; then
            # In place, as the vendor writes it: the vendor's binds hold on to this very file.
            cat "$PROPS_RAM" > "$view/build.prop" && sync && echo "Saved the vendor's properties file to flash"
        fi
    else
        echo "Couldn't reach the vendor's properties file on flash to save it"
    fi
    if mounted "$view"; then umount "$view"; fi
    rmdir "$view"
}
props_to_ram() {
    same_file "$PROPS" "$PROPS_RAM" && return 0
    [ -f "$PROPS" ] && cp -p "$PROPS" "$PROPS_RAM" || return 1
    # The owner and mode came along; the SELinux label is the one the property service expects.
    chcon --reference="$PROPS" "$PROPS_RAM" 2>/dev/null
    mount --bind "$PROPS_RAM" "$PROPS" || return 1
    # Mount propagation carries the bind to /etc/build.prop as well; cover it if it didn't.
    if ! same_file "$PROPS_BIND" "$PROPS_RAM"; then mount --bind "$PROPS_RAM" "$PROPS_BIND" || return 1; fi
}
props_back() { # saves the file, then removes the add-on's binds; the vendor's binds stay as they were
    save_props
    for p in "$PROPS" "$PROPS_BIND"; do
        n=0
        while [ $n -lt 5 ] && same_file "$p" "$PROPS_RAM"; do
            umount "$p" 2>/dev/null || umount -l "$p" || break
            n=$((n + 1))
        done
    done
    if ! same_file "$PROPS" "$PROPS_RAM" && ! same_file "$PROPS_BIND" "$PROPS_RAM"; then rm -f "$PROPS_RAM"; fi
}

cleanup() {
    save_props
    # Crash dumps from before the service started: the vendor's core_pattern writes them to RAM.
    for f in /var/tmp/core.*; do
        [ -f "$f" ] || continue
        rest=${f#/var/tmp/core.} # NAME.PID.SIGNAL.TIME
        t=${rest##*.}; rest=${rest%.*}
        sig=${rest##*.}; rest=${rest%.*}
        case "$t$sig" in ''|*[!0-9]*) t=$(stat -c %Y "$f"); sig=0 ;; esac
        mb=$(( $(stat -c %s "$f") / 1048576 ))
        rm -f "$f"
        record_crash "$t" "$sig" "${rest%.*}"
        echo "Deleted the crash dump of ${rest%.*} ($mb MB, signal $sig)"
    done
    # Login records, also in RAM, grow with every SSH sign-in and every failed attempt.
    for f in /var/log/wtmp /var/log/btmp; do
        if [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" -gt 1048576 ]; then : > "$f"; echo "Emptied $f, which was over 1 MB"; fi
    done
    keep_last "$RUN_DIR/wifi-try.log" 200
}

run() {
    echo "$CORE_PATTERN" > /proc/sys/kernel/core_pattern
    echo "Crashes are recorded in $CRASHES, without crash dumps"
    # The boot script mounts an overlay on /etc, then binds the properties file onto it again. The
    # file moves to RAM after that, so that "stop" leaves the vendor's binds as they were.
    n=0
    until { grep -q '^overlay /etc ' /proc/mounts && same_file "$PROPS_BIND" "$PROPS"; } || [ $n -ge 150 ]; do
        sleep 2
        n=$((n + 1))
    done
    if props_to_ram; then
        echo "The vendor's properties file is in RAM; changes are saved to flash every 10 minutes"
    else
        props_back
        echo "Couldn't move the vendor's properties file to RAM; it stays on flash"
    fi
    while :; do
        cleanup
        sleep 600
    done
}

case "$1" in
    run) run ;;
    stop)
        props_back
        if [ "$(cat /proc/sys/kernel/core_pattern)" = "$CORE_PATTERN" ]; then
            echo "$VENDOR_CORE_PATTERN" > /proc/sys/kernel/core_pattern
        fi ;;
    cleanup) cleanup ;;
    crash)
        exec 0<&- # closing the pipe stops the kernel writing the crash dump
        sig=$2
        shift 2
        record_crash "$(date +%s)" "$sig" "$*"
        # Through the kernel log: messages that logger sent from here reached syslog but not the journal.
        printf '<12>vaidk-storage: %s crashed (signal %s); no crash dump was kept\n' "$*" "$sig" > /dev/kmsg ;;
    *) sed -n '2,7p' "$0" >&2; exit 2 ;;
esac
exit 0
