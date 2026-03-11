#!/bin/sh
# start-pw.sh — Start PipeWire inside the Debian chroot
# Called by pw-helper: start-pw.sh <fifo_playback_path> <slot>
#
# This script must return quickly — it's called from the DSP plugin's
# create_instance via fork+exec. Long-running work is backgrounded.
set -e

FIFO_PLAYBACK="$1"
SLOT="${2:-1}"
CHROOT="/data/UserData/pw-chroot"
PW_CONF_DIR="$CHROOT/etc/pipewire/pipewire.conf.d"
PID_DIR="/tmp/pw-pids-${SLOT}"

if [ ! -d "$CHROOT/usr" ]; then
    echo "ERROR: Chroot not found at $CHROOT" >&2
    exit 1
fi

# Create PID tracking directory (writable by move user who runs PipeWire)
mkdir -p "$PID_DIR"
chmod 777 "$PID_DIR"

# Bind-mount system filesystems (skip if already mounted)
for fs in proc sys dev dev/pts tmp; do
    case "$fs" in
        proc)    mountpoint -q "$CHROOT/proc"    2>/dev/null || mount -t proc proc "$CHROOT/proc" ;;
        sys)     mountpoint -q "$CHROOT/sys"     2>/dev/null || mount -t sysfs sys "$CHROOT/sys" ;;
        dev)     mountpoint -q "$CHROOT/dev"     2>/dev/null || mount --bind /dev "$CHROOT/dev" ;;
        dev/pts) mountpoint -q "$CHROOT/dev/pts" 2>/dev/null || mount --bind /dev/pts "$CHROOT/dev/pts" ;;
        tmp)     mountpoint -q "$CHROOT/tmp"     2>/dev/null || mount --bind /tmp "$CHROOT/tmp" ;;
    esac
done

# Write PipeWire pipe-tunnel config for this slot's FIFO
mkdir -p "$PW_CONF_DIR"
cat > "$PW_CONF_DIR/move-bridge-${SLOT}.conf" << PWEOF
context.modules = [
    { name = libpipewire-module-pipe-tunnel
      args = {
          tunnel.mode = sink
          pipe.filename = ${FIFO_PLAYBACK}
          audio.format = S16LE
          audio.rate = 44100
          audio.channels = 2
          stream.props = { node.name = "move-playback" }
      }
    }
]
PWEOF

# Set up XDG_RUNTIME_DIR owned by move user (uid 1000)
# PipeWire runs as move so VNC desktop apps can connect natively
RUNTIME_DIR="/tmp/pw-runtime-${SLOT}"
mkdir -p "$CHROOT/$RUNTIME_DIR"
chown 1000:1000 "$CHROOT/$RUNTIME_DIR"
chmod 700 "$CHROOT/$RUNTIME_DIR"

# Make FIFO writable by move user
chmod 666 "$FIFO_PLAYBACK" 2>/dev/null

# Launch everything in a single backgrounded subshell so we return immediately
(
    # Start dbus session bus
    chroot "$CHROOT" sh -c "
        export XDG_RUNTIME_DIR=$RUNTIME_DIR
        if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
            mkdir -p /run/dbus
            dbus-daemon --system --fork 2>/dev/null || true
            dbus-daemon --session --fork --address=unix:path=${RUNTIME_DIR}/dbus-pw 2>/dev/null || true
        fi
    "

    # Start PipeWire as move user (uid 1000) so VNC desktop apps can connect
    chroot "$CHROOT" su - move -c "
        export XDG_RUNTIME_DIR=$RUNTIME_DIR
        export DBUS_SESSION_BUS_ADDRESS=unix:path=${RUNTIME_DIR}/dbus-pw
        nohup /usr/bin/pipewire >/dev/null 2>&1 &
        echo \$! > /tmp/pw-pids-${SLOT}/pipewire.pid
    "

    # Brief pause for PipeWire to initialize
    sleep 2

    # Start WirePlumber as move user
    chroot "$CHROOT" su - move -c "
        export XDG_RUNTIME_DIR=$RUNTIME_DIR
        export DBUS_SESSION_BUS_ADDRESS=unix:path=${RUNTIME_DIR}/dbus-pw
        nohup /usr/bin/wireplumber >/dev/null 2>&1 &
        echo \$! > /tmp/pw-pids-${SLOT}/wireplumber.pid
    "

    echo "PipeWire started in chroot (slot $SLOT)"
) &

# Return immediately — PipeWire starts in background
echo "PipeWire launch backgrounded (slot $SLOT)"
