#!/usr/bin/env bash
set -euo pipefail

DEVICE_HOST="${DEVICE_HOST:-move.local}"
REMOTE_MODULE="/data/UserData/move-anything/modules/sound_generators/pipewire"
REMOTE_CHROOT="/data/UserData/pw-chroot"
REMOTE_BIN="/data/UserData/move-anything/bin/pw-helper"

USER_SSH="ableton@$DEVICE_HOST"
ROOT_SSH="root@$DEVICE_HOST"

echo "=== Uninstalling PipeWire Module ==="
echo "Device: $DEVICE_HOST"
echo ""

# ── Stop any running PipeWire processes ──
echo "--- Stopping PipeWire processes ---"
ssh "$ROOT_SSH" "pkill -x pipewire 2>/dev/null; pkill -x wireplumber 2>/dev/null; pkill -x midi-bridge 2>/dev/null; true"

# ── Unmount chroot bind mounts if active ──
echo "--- Cleaning up chroot mounts ---"
ssh "$ROOT_SSH" "
    for mp in $REMOTE_CHROOT/proc $REMOTE_CHROOT/sys $REMOTE_CHROOT/dev/pts $REMOTE_CHROOT/dev $REMOTE_CHROOT/tmp; do
        mountpoint -q \"\$mp\" 2>/dev/null && umount \"\$mp\" 2>/dev/null || true
    done
"

# ── Remove chroot (root-owned) ──
echo "--- Removing chroot ($REMOTE_CHROOT) ---"
ssh "$ROOT_SSH" "rm -rf $REMOTE_CHROOT"

# ── Remove module ──
echo "--- Removing module ($REMOTE_MODULE) ---"
ssh "$USER_SSH" "rm -rf $REMOTE_MODULE"

# ── Remove pw-helper ──
echo "--- Removing pw-helper ---"
ssh "$ROOT_SSH" "rm -f $REMOTE_BIN"

# ── Remove convenience scripts ──
echo "--- Removing convenience scripts ---"
ssh "$USER_SSH" "rm -f /data/UserData/mount-chroot.sh /data/UserData/start-vnc.sh"

echo ""
echo "=== Uninstall Complete ==="
echo "All PipeWire files have been removed from $DEVICE_HOST."
