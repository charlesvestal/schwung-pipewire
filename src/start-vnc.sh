#!/bin/sh
# start-vnc.sh — Start VNC server in the chroot for XFCE desktop access
# Run as root on Move:
#   sh start-vnc.sh              # 1920x1080 (default)
#   sh start-vnc.sh 1280x720    # custom resolution
#   sh start-vnc.sh stop

CHROOT="/data/UserData/pw-chroot"
DISPLAY_NUM=":1"
PID_FILE="/tmp/vnc-desktop.pid"
GEOMETRY="${1:-1920x1080}"

if [ "$GEOMETRY" = "stop" ]; then
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    chroot "$CHROOT" su - move -c "vncserver -kill $DISPLAY_NUM 2>/dev/null" || true
    echo "VNC server stopped"
    exit 0
fi

# Ensure chroot is mounted
if ! mountpoint -q "$CHROOT/proc" 2>/dev/null; then
    echo "Mounting chroot filesystems..."
    sh "$(dirname "$0")/mount-chroot.sh"
fi

# Set up VNC runtime dir (separate from PipeWire's /tmp/pw-runtime-1)
RUNTIME_DIR="/run/user/1000"
mkdir -p "$CHROOT/$RUNTIME_DIR"
chown 1000:1000 "$CHROOT/$RUNTIME_DIR"
chmod 700 "$CHROOT/$RUNTIME_DIR"

# Start dbus if needed
chroot "$CHROOT" sh -c "
    if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
        mkdir -p /run/dbus
        dbus-daemon --system --fork 2>/dev/null || true
    fi
"

# Ensure hostname resolution works in chroot
if [ ! -f "$CHROOT/etc/hostname" ] || ! grep -q move "$CHROOT/etc/hostname" 2>/dev/null; then
    echo "move" > "$CHROOT/etc/hostname"
    echo "127.0.0.1 localhost move" > "$CHROOT/etc/hosts"
fi

# Set VNC password on first run
if [ ! -f "$CHROOT/home/move/.vnc/passwd" ]; then
    echo "Setting VNC password..."
    chroot "$CHROOT" su - move -c "
        mkdir -p /home/move/.vnc /home/move/.config/tigervnc
        echo 'everything' | vncpasswd -f > /home/move/.vnc/passwd
        chmod 600 /home/move/.vnc/passwd
        cp /home/move/.vnc/passwd /home/move/.config/tigervnc/passwd
    "
fi

# Start VNC as the move user
# XDG_RUNTIME_DIR=/tmp/pw-runtime-1 matches where PipeWire runs (as move user)
chroot "$CHROOT" su - move -c "
    export XDG_RUNTIME_DIR=/tmp/pw-runtime-1
    vncserver $DISPLAY_NUM -geometry $GEOMETRY -depth 24 -localhost no 2>&1
" &
echo $! > "$PID_FILE"

# Get Move's IP for the connection info
MOVE_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
[ -z "$MOVE_IP" ] && MOVE_IP=$(ip -4 addr show eth0 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
[ -z "$MOVE_IP" ] && MOVE_IP="move.local"

echo ""
echo "=== VNC Server Started ==="
echo "Connect to: $MOVE_IP:5901"
echo "Resolution: $GEOMETRY"
echo "Password:   everything"
echo ""
echo "Stop with: sh $(dirname "$0")/start-vnc.sh stop"
