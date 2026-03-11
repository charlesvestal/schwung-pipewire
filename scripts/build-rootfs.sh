#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Parse arguments
VARIANT="minimal"
if [ "${1:-}" = "--desktop" ] || [ "${1:-}" = "-d" ]; then
    VARIANT="desktop"
fi

if [ "$VARIANT" = "desktop" ]; then
    OUTPUT="$REPO_ROOT/dist/pw-chroot-desktop.tar.gz"
    DOCKERFILE="$SCRIPT_DIR/Dockerfile.rootfs-desktop"
    IMAGE_NAME="pw-chroot-desktop-builder"
    echo "=== Building Debian sid arm64 DESKTOP rootfs ==="
    echo "    Includes: XFCE, VNC server, PipeWire, user move/everything"
else
    OUTPUT="$REPO_ROOT/dist/pw-chroot.tar.gz"
    DOCKERFILE="$SCRIPT_DIR/Dockerfile.rootfs"
    IMAGE_NAME="pw-chroot-builder"
    echo "=== Building Debian sid arm64 rootfs with PipeWire ==="
fi

echo "NOTE: Requires Docker with QEMU binfmt_misc for arm64 emulation."
echo "      Run: docker run --rm --privileged multiarch/qemu-user-static --reset -p yes"
echo ""

mkdir -p "$REPO_ROOT/dist"

docker build --platform linux/arm64 \
    -t "$IMAGE_NAME" \
    -f "$DOCKERFILE" \
    "$REPO_ROOT"

echo "=== Exporting rootfs to tarball ==="
CONTAINER_ID=$(docker create --platform linux/arm64 "$IMAGE_NAME" /bin/true)
docker export "$CONTAINER_ID" | gzip > "$OUTPUT"
docker rm "$CONTAINER_ID" >/dev/null

echo ""
echo "=== Rootfs build complete ==="
echo "Output: $OUTPUT"
echo "Size: $(du -h "$OUTPUT" | cut -f1)"
echo ""
echo "Deploy with: ./scripts/install.sh"
