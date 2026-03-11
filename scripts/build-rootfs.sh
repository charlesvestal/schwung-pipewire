#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT="$REPO_ROOT/dist/pw-chroot.tar.gz"

echo "=== Building Debian sid arm64 rootfs with PipeWire ==="
echo "NOTE: Requires Docker with QEMU binfmt_misc for arm64 emulation."
echo "      Run: docker run --rm --privileged multiarch/qemu-user-static --reset -p yes"
echo ""

IMAGE_NAME="pw-chroot-builder"

docker build --platform linux/arm64 \
    -t "$IMAGE_NAME" \
    -f "$SCRIPT_DIR/Dockerfile.rootfs" \
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
