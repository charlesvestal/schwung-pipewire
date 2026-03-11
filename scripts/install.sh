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

# ── Install rootfs (only if tarball exists and chroot doesn't) ──
if [ -f "$ROOTFS_TAR" ]; then
    echo ""
    echo "--- Deploying rootfs to $REMOTE_CHROOT ---"

    # Check if chroot already exists
    if ssh "root@$DEVICE_HOST" "[ -d $REMOTE_CHROOT/usr ]" 2>/dev/null; then
        echo "Chroot already exists at $REMOTE_CHROOT. Skipping rootfs deploy."
        echo "To force redeploy: ssh root@$DEVICE_HOST 'rm -rf $REMOTE_CHROOT'"
    else
        echo "Uploading rootfs..."
        # Upload to /data (not /tmp — root filesystem may be full)
        scp "$ROOTFS_TAR" "root@$DEVICE_HOST:/data/pw-chroot.tar.gz"
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
    echo "NOTE: No rootfs tarball found at $ROOTFS_TAR"
    echo "Run ./scripts/build-rootfs.sh to build the Debian chroot."
fi

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
echo "Then SSH in and enter the chroot:"
echo "  ssh root@$DEVICE_HOST"
echo "  chroot $REMOTE_CHROOT bash -l"
echo "  mpg321 -s song.mp3 | aplay -f S16_LE -r 44100 -c 2 -D pipewire"
