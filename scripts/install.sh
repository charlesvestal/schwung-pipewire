#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MODULE_ID="pipewire"
# Replace move.local with your device's IP address if mDNS is not available
DEVICE_HOST="${DEVICE_HOST:-move.local}"
REMOTE_MODULE="/data/UserData/schwung/modules/sound_generators/$MODULE_ID"
REMOTE_CHROOT="/data/UserData/pw-chroot"
MODULE_TAR="$REPO_ROOT/dist/pipewire-module.tar.gz"
ROOTFS_TAR="$REPO_ROOT/dist/pw-chroot.tar.gz"
ROOTFS_DESKTOP_TAR="$REPO_ROOT/dist/pw-chroot-desktop.tar.gz"

USER_SSH="ableton@$DEVICE_HOST"
ROOT_SSH="root@$DEVICE_HOST"

echo "=== Installing PipeWire Module ==="
echo "Device: $DEVICE_HOST"
echo ""

# ── Install module files (ableton owns /data/UserData) ──
if [ ! -f "$MODULE_TAR" ]; then
    echo "Error: $MODULE_TAR not found. Run ./scripts/build.sh first."
    exit 1
fi

echo "--- Deploying module to $REMOTE_MODULE ---"
ssh "$USER_SSH" "mkdir -p $REMOTE_MODULE"
scp "$MODULE_TAR" "$USER_SSH:/tmp/pipewire-module.tar.gz"
ssh "$USER_SSH" "tar -xzf /tmp/pipewire-module.tar.gz -C $REMOTE_MODULE --strip-components=1 && rm /tmp/pipewire-module.tar.gz"
ssh "$USER_SSH" "chmod +x $REMOTE_MODULE/start-pw.sh $REMOTE_MODULE/stop-pw.sh"

# ── Install pw-helper (setuid root — requires root) ──
if ssh "$USER_SSH" "[ -f $REMOTE_MODULE/bin/pw-helper ]" 2>/dev/null; then
    echo ""
    echo "--- Installing pw-helper (setuid root) ---"
    ssh "$ROOT_SSH" "mkdir -p /data/UserData/schwung/bin"
    ssh "$ROOT_SSH" "cp $REMOTE_MODULE/bin/pw-helper /data/UserData/schwung/bin/pw-helper"
    ssh "$ROOT_SSH" "chown root:root /data/UserData/schwung/bin/pw-helper && chmod 4755 /data/UserData/schwung/bin/pw-helper"
    echo "pw-helper installed at /data/UserData/schwung/bin/pw-helper"
fi

# ── Install rootfs (prefer desktop if available, fall back to minimal) ──
# Done before chroot file installs so the directory structure exists
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
    if ssh "$ROOT_SSH" "[ -d $REMOTE_CHROOT/usr ]" 2>/dev/null; then
        echo "Chroot already exists at $REMOTE_CHROOT. Skipping rootfs deploy."
        echo "To force redeploy: ssh $ROOT_SSH 'rm -rf $REMOTE_CHROOT'"
    else
        echo "Uploading rootfs ($(du -h "$CHOSEN_TAR" | cut -f1))..."
        # Root required to preserve file ownership from tarball
        scp "$CHOSEN_TAR" "$ROOT_SSH:/data/pw-chroot.tar.gz"
        ssh "$ROOT_SSH" "
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

# ── Install files into chroot (root-owned paths) ──
if ssh "$USER_SSH" "[ -f $REMOTE_MODULE/chroot-lib/jack-physical-shim.so ]" 2>/dev/null; then
    echo ""
    echo "--- Installing jack-physical-shim to chroot ---"
    ssh "$ROOT_SSH" "mkdir -p $REMOTE_CHROOT/usr/local/lib"
    ssh "$ROOT_SSH" "cp $REMOTE_MODULE/chroot-lib/jack-physical-shim.so $REMOTE_CHROOT/usr/local/lib/jack-physical-shim.so"
    ssh "$ROOT_SSH" "chmod 644 $REMOTE_CHROOT/usr/local/lib/jack-physical-shim.so"
    echo "jack-physical-shim installed at $REMOTE_CHROOT/usr/local/lib/jack-physical-shim.so"
fi

if ssh "$USER_SSH" "[ -f $REMOTE_MODULE/chroot-lib/pw-jack-physical ]" 2>/dev/null; then
    ssh "$ROOT_SSH" "mkdir -p $REMOTE_CHROOT/usr/local/bin"
    ssh "$ROOT_SSH" "cp $REMOTE_MODULE/chroot-lib/pw-jack-physical $REMOTE_CHROOT/usr/local/bin/pw-jack-physical"
    ssh "$ROOT_SSH" "chmod +x $REMOTE_CHROOT/usr/local/bin/pw-jack-physical"
fi

if ssh "$USER_SSH" "[ -f $REMOTE_MODULE/bin/midi-bridge ]" 2>/dev/null; then
    echo ""
    echo "--- Installing midi-bridge to chroot ---"
    ssh "$ROOT_SSH" "mkdir -p $REMOTE_CHROOT/usr/local/bin"
    ssh "$ROOT_SSH" "cp $REMOTE_MODULE/bin/midi-bridge $REMOTE_CHROOT/usr/local/bin/midi-bridge"
    ssh "$ROOT_SSH" "chmod +x $REMOTE_CHROOT/usr/local/bin/midi-bridge"
    echo "midi-bridge installed at $REMOTE_CHROOT/usr/local/bin/midi-bridge"
fi

if ! ssh "$USER_SSH" "[ -f $REMOTE_MODULE/bin/pw-helper ]" 2>/dev/null; then
    echo ""
    echo "NOTE: pw-helper not found. PipeWire must be started manually as root."
    echo "  ssh $ROOT_SSH"
    echo "  sh $REMOTE_MODULE/start-pw.sh /tmp/pw-to-move-<slot> <slot>"
fi

# ── Install convenience scripts (ableton owns /data/UserData) ──
REMOTE_SCRIPTS="/data/UserData"
echo ""
echo "--- Installing convenience scripts ---"
ssh "$USER_SSH" "cp $REMOTE_MODULE/mount-chroot.sh $REMOTE_MODULE/start-vnc.sh $REMOTE_SCRIPTS/ 2>/dev/null || true"
ssh "$USER_SSH" "chmod +x $REMOTE_SCRIPTS/mount-chroot.sh $REMOTE_SCRIPTS/start-vnc.sh 2>/dev/null || true"
echo "Scripts installed to $REMOTE_SCRIPTS/"

# ── Install chroot profile (root-owned path) ──
echo ""
echo "--- Installing chroot profile ---"
ssh "$ROOT_SSH" "mkdir -p $REMOTE_CHROOT/etc/profile.d && cat > $REMOTE_CHROOT/etc/profile.d/pipewire.sh << 'PROFEOF'
# Auto-set PipeWire environment for Move bridge
export XDG_RUNTIME_DIR=/tmp/pw-runtime-1
export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/pw-runtime-1/dbus-pw
PROFEOF
chmod 644 $REMOTE_CHROOT/etc/profile.d/pipewire.sh"

# ── Disable PipeWire RT scheduling (prevents SIGKILL from kernel RT throttling) ──
echo ""
echo "--- Installing PipeWire no-RT config ---"
ssh "$ROOT_SSH" "mkdir -p $REMOTE_CHROOT/etc/pipewire/pipewire.conf.d && cat > $REMOTE_CHROOT/etc/pipewire/pipewire.conf.d/no-rt.conf << 'RTEOF'
context.properties = {
    module.rt = false
}
RTEOF
chmod 644 $REMOTE_CHROOT/etc/pipewire/pipewire.conf.d/no-rt.conf
mkdir -p $REMOTE_CHROOT/etc/wireplumber/wireplumber.conf.d
cp $REMOTE_CHROOT/etc/pipewire/pipewire.conf.d/no-rt.conf $REMOTE_CHROOT/etc/wireplumber/wireplumber.conf.d/no-rt.conf
mkdir -p $REMOTE_CHROOT/etc/security/limits.d
echo '# Disabled - RT scheduling conflicts with Move audio engine' > $REMOTE_CHROOT/etc/security/limits.d/25-pw-rlimits.conf"

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
echo "MIDI:"
echo "  JACK MIDI ports 'Move MIDI In' and 'Move MIDI Out' appear in chroot."
echo "  Example: pw-jack fluidsynth --midi-driver=jack --audio-driver=jack -r 48000 /usr/share/sounds/sf2/FluidR3_GM.sf2"
echo ""
echo "Desktop (if installed):"
echo "  ssh root@$DEVICE_HOST"
echo "  sh /data/UserData/start-vnc.sh"
echo "  # Connect VNC client to move.local:5901 (password: everything)"
