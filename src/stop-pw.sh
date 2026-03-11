#!/bin/sh
# stop-pw.sh — Stop PipeWire and clean up chroot mounts
# Called by DSP plugin: stop-pw.sh <slot>
SLOT="${1:-1}"
CHROOT="/data/UserData/pw-chroot"
PID_DIR="/tmp/pw-pids-${SLOT}"

# Kill PipeWire processes
if [ -f "$PID_DIR/wireplumber.pid" ]; then
    kill "$(cat "$PID_DIR/wireplumber.pid")" 2>/dev/null || true
fi
if [ -f "$PID_DIR/pipewire.pid" ]; then
    kill "$(cat "$PID_DIR/pipewire.pid")" 2>/dev/null || true
fi

# Fallback: kill by name inside chroot
chroot "$CHROOT" killall wireplumber 2>/dev/null || true
chroot "$CHROOT" killall pipewire 2>/dev/null || true

# Clean up PID files and runtime dir
rm -rf "$PID_DIR"
rm -rf "$CHROOT/tmp/pw-runtime-${SLOT}"

# Remove slot-specific PipeWire config
rm -f "$CHROOT/etc/pipewire/pipewire.conf.d/move-bridge-${SLOT}.conf"

# Unmount bind mounts (only if no other slots are using the chroot)
# Check if any other pw-pids-* directories exist
if ! ls /tmp/pw-pids-* >/dev/null 2>&1; then
    umount "$CHROOT/tmp"  2>/dev/null || true
    umount "$CHROOT/dev"  2>/dev/null || true
    umount "$CHROOT/sys"  2>/dev/null || true
    umount "$CHROOT/proc" 2>/dev/null || true
    echo "Chroot unmounted (last slot)"
fi

echo "PipeWire stopped (slot $SLOT)"
