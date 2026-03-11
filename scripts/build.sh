#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
IMAGE_NAME="move-anything-pipewire-builder"
OUTPUT_BASENAME="${OUTPUT_BASENAME:-pipewire-module}"

# ── If running outside Docker, re-exec inside container ──
if [ ! -f /.dockerenv ]; then
    echo "=== Building Docker image ==="
    docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile" "$REPO_ROOT"

    echo "=== Running build inside container ==="
    docker run --rm \
        -v "$REPO_ROOT:/build" \
        -u "$(id -u):$(id -g)" \
        -w /build \
        -e OUTPUT_BASENAME="$OUTPUT_BASENAME" \
        "$IMAGE_NAME" ./scripts/build.sh
    exit $?
fi

# ── Inside Docker: cross-compile DSP plugin ──
echo "=== Cross-compiling dsp.so ==="
mkdir -p build/module

"${CROSS_PREFIX}gcc" -O3 -g -shared -fPIC \
    src/dsp/pipewire_plugin.c \
    -o build/module/dsp.so \
    -Isrc/dsp \
    -lpthread -lm

echo "=== Cross-compiling pw-helper ==="
"${CROSS_PREFIX}gcc" -O2 -static \
    src/pw-helper.c \
    -o build/pw-helper

echo "=== Assembling module package ==="
cp src/module.json  build/module/
cp src/ui.js        build/module/
cp src/start-pw.sh     build/module/
cp src/stop-pw.sh      build/module/
cp src/mount-chroot.sh build/module/
cp src/start-vnc.sh    build/module/
chmod +x build/module/start-pw.sh build/module/stop-pw.sh \
         build/module/mount-chroot.sh build/module/start-vnc.sh

# ── Package ──
mkdir -p dist
rm -rf dist/pipewire
cp -r build/module dist/pipewire

(cd dist && tar -czvf "${OUTPUT_BASENAME}.tar.gz" pipewire/)

echo ""
echo "=== Build complete ==="
echo "Module: dist/${OUTPUT_BASENAME}.tar.gz"
echo "Files:  dist/pipewire/"
