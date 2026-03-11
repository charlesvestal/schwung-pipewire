#!/bin/sh
# mount-chroot.sh — Mount system filesystems into the chroot
# Run as root on Move: sh mount-chroot.sh
CHROOT="/data/UserData/pw-chroot"

if [ ! -d "$CHROOT/usr" ]; then
    echo "ERROR: Chroot not found at $CHROOT" >&2
    exit 1
fi

for fs in proc sys dev dev/pts tmp; do
    TARGET="$CHROOT/$fs"
    mkdir -p "$TARGET"
    if mountpoint -q "$TARGET" 2>/dev/null; then
        echo "$fs: already mounted"
        continue
    fi
    case "$fs" in
        proc)    mount -t proc proc "$TARGET" ;;
        sys)     mount -t sysfs sys "$TARGET" ;;
        dev)     mount --bind /dev "$TARGET" ;;
        dev/pts) mount --bind /dev/pts "$TARGET" ;;
        tmp)     mount --bind /tmp "$TARGET" ;;
    esac
    echo "$fs: mounted"
done

echo ""
echo "Chroot ready. Enter with:"
echo "  chroot $CHROOT bash -l"
echo "  su - move   (for non-root desktop user)"
