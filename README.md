# move-everything-pipewire

A [Move Everything](https://github.com/charlesvestal/move-anything) sound generator module that bridges PipeWire audio to the Ableton Move. Run any ALSA or JACK app inside a Debian chroot and hear it through Move's speakers.

## How It Works

```
PipeWire app (in chroot) → pipe-tunnel sink → FIFO → ring buffer → render_block() → Move audio out
```

The DSP plugin creates a named pipe. PipeWire's `module-pipe-tunnel` writes audio to it. The plugin reads from the pipe into a ring buffer and outputs it through Move's SPI mailbox. The whole thing runs alongside stock Move in a shadow chain slot.

## Prerequisites

- Docker (with BuildKit)
- QEMU binfmt for arm64 emulation (rootfs build only)
- SSH access to Move (`root@move.local` or IP)
- [Move Everything](https://github.com/charlesvestal/move-anything) installed on Move

## Build

```bash
# Cross-compile DSP plugin + package module
./scripts/build.sh

# Build Debian sid arm64 rootfs with PipeWire (~120MB)
# One-time: register QEMU binfmt
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
./scripts/build-rootfs.sh
```

## Install

```bash
# Deploy to Move (module + rootfs)
DEVICE_HOST=192.168.1.199 ./scripts/install.sh
```

## Usage

1. Load **PipeWire** as a sound generator in a Move Everything shadow chain slot
2. PipeWire starts automatically in the chroot
3. SSH into Move and enter the chroot:

```bash
ssh root@move.local
chroot /data/UserData/pw-chroot bash
```

4. Install and run apps:

```bash
apt install guitarix
guitarix --jack
# Audio routes through Move's speakers/headphones
```

## Controls

| Control | Action |
|---------|--------|
| Knob 1 | Gain (0.0 - 2.0) |
| Pad 1 | Restart PipeWire |

## Architecture

| Component | File |
|-----------|------|
| DSP plugin | `src/dsp/pipewire_plugin.c` |
| Chroot launcher | `src/start-pw.sh` |
| Chroot teardown | `src/stop-pw.sh` |
| Module UI | `src/ui.js` |
| Module metadata | `src/module.json` |
| PipeWire config | Written dynamically by `start-pw.sh` |

## Audio Specs

44100 Hz, stereo interleaved int16 (S16LE), 128-frame blocks (~2.9ms). Ring buffer adds ~6-12ms latency.

