#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MODULE_ID="pipewire"
DEVICE_HOST="${DEVICE_HOST:-move.local}"
REMOTE_MODULE="/data/UserData/move-anything/modules/sound_generators/$MODULE_ID"
REMOTE_CHROOT="/data/UserData/pw-chroot"
DIST_DIR="$REPO_ROOT/dist/$MODULE_ID"
ROOTFS_TAR="$REPO_ROOT/dist/pw-chroot.tar.gz"
ROOTFS_DESKTOP_TAR="$REPO_ROOT/dist/pw-chroot-desktop.tar.gz"

echo "=== Installing PipeWire Module ==="
echo "Device: $DEVICE_HOST"
echo ""

# ── Install module files ──
if [ ! -d "$DIST_DIR" ]; then
    echo "Error: $DIST_DIR not found. Run ./scripts/build.sh first."
    exit 1
fi

echo "--- Deploying module to $REMOTE_MODULE ---"
ssh "root@$DEVICE_HOST" "mkdir -p $REMOTE_MODULE"
scp -r "$DIST_DIR/"* "root@$DEVICE_HOST:$REMOTE_MODULE/"
ssh "root@$DEVICE_HOST" "chmod +x $REMOTE_MODULE/start-pw.sh $REMOTE_MODULE/stop-pw.sh && chown -R ableton:users $REMOTE_MODULE"

# ── Install pw-helper (setuid root helper for chroot management) ──
PW_HELPER="$REPO_ROOT/build/pw-helper"
if [ -f "$PW_HELPER" ]; then
    echo ""
    echo "--- Installing pw-helper (setuid root) ---"
    scp "$PW_HELPER" "root@$DEVICE_HOST:/usr/local/bin/pw-helper"
    ssh "root@$DEVICE_HOST" "chown root:root /usr/local/bin/pw-helper && chmod 4755 /usr/local/bin/pw-helper"
    echo "pw-helper installed at /usr/local/bin/pw-helper"
else
    echo ""
    echo "NOTE: pw-helper not found. PipeWire must be started manually as root."
    echo "  ssh root@$DEVICE_HOST"
    echo "  sh $REMOTE_MODULE/start-pw.sh /tmp/pw-to-move-<slot> <slot>"
fi

# ── Install rootfs (prefer desktop if available, fall back to minimal) ──
CHOSEN_TAR=""
if [ -f "$ROOTFS_DESKTOP_TAR" ]; then
    CHOSEN_TAR="$ROOTFS_DESKTOP_TAR"
    echo ""
    echo "--- Deploying DESKTOP rootfs to $REMOTE_CHROOT ---"
elif [ -f "$ROOTFS_TAR" ]; then
    CHOSEN_TAR="$ROOTFS_TAR"
    echo ""
    echo "--- Deploying rootfs to $REMOTE_CHROOT ---"
fi

if [ -n "$CHOSEN_TAR" ]; then
    if ssh "root@$DEVICE_HOST" "[ -d $REMOTE_CHROOT/usr ]" 2>/dev/null; then
        echo "Chroot already exists at $REMOTE_CHROOT. Skipping rootfs deploy."
        echo "To force redeploy: ssh root@$DEVICE_HOST 'rm -rf $REMOTE_CHROOT'"
    else
        echo "Uploading rootfs ($(du -h "$CHOSEN_TAR" | cut -f1))..."
        scp "$CHOSEN_TAR" "root@$DEVICE_HOST:/data/pw-chroot.tar.gz"
        ssh "root@$DEVICE_HOST" "
            mkdir -p $REMOTE_CHROOT
            cd $REMOTE_CHROOT
            tar -xzf /data/pw-chroot.tar.gz
            rm /data/pw-chroot.tar.gz
        "
        echo "Rootfs deployed."
    fi
else
    echo ""
    echo "NOTE: No rootfs tarball found."
    echo "  Minimal: ./scripts/build-rootfs.sh"
    echo "  Desktop: ./scripts/build-rootfs.sh --desktop"
fi

# ── Install convenience scripts to /data/UserData ──
REMOTE_SCRIPTS="/data/UserData"
echo ""
echo "--- Installing convenience scripts ---"
scp "$REPO_ROOT/src/mount-chroot.sh" "$REPO_ROOT/src/start-vnc.sh" \
    "root@$DEVICE_HOST:$REMOTE_SCRIPTS/"
ssh "root@$DEVICE_HOST" "chmod +x $REMOTE_SCRIPTS/mount-chroot.sh $REMOTE_SCRIPTS/start-vnc.sh"
echo "Scripts installed to $REMOTE_SCRIPTS/"

# ── Install chroot profile (auto-sets XDG_RUNTIME_DIR) ──
echo ""
echo "--- Installing chroot profile ---"
ssh "root@$DEVICE_HOST" "mkdir -p $REMOTE_CHROOT/etc/profile.d && cat > $REMOTE_CHROOT/etc/profile.d/pipewire.sh << 'PROFEOF'
# Auto-set PipeWire environment for Move bridge
export XDG_RUNTIME_DIR=/tmp/pw-runtime-1
export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/pw-runtime-1/dbus-pw
PROFEOF
chmod 644 $REMOTE_CHROOT/etc/profile.d/pipewire.sh"

echo ""
echo "=== Install Complete ==="
echo "Module: $REMOTE_MODULE"
echo "Chroot: $REMOTE_CHROOT"
echo ""
echo "Load 'PipeWire' as a sound generator in Move Everything."
echo ""
echo "Enter the chroot:"
echo "  ssh root@$DEVICE_HOST"
echo "  chroot $REMOTE_CHROOT bash -l"
echo "  mpg321 -s song.mp3 | aplay -f S16_LE -r 44100 -c 2 -D pipewire"
echo ""
echo "Desktop (if installed):"
echo "  ssh root@$DEVICE_HOST"
echo "  sh /data/UserData/start-vnc.sh"
echo "  # Connect VNC client to move.local:5901 (password: everything)"
