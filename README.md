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

# One-time: register QEMU binfmt for arm64 emulation
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# Build minimal rootfs (PipeWire only, ~120MB)
./scripts/build-rootfs.sh

# Build desktop rootfs (XFCE + VNC + PipeWire, ~500MB)
./scripts/build-rootfs.sh --desktop

# Clean build artifacts
./scripts/clean.sh
```

## Install

```bash
# Deploy to Move (module + rootfs + convenience scripts)
DEVICE_HOST=192.168.1.199 ./scripts/install.sh
```

The installer deploys whichever rootfs was built (prefers desktop if both exist).

## Usage

1. Load **PipeWire** as a sound generator in a Move Everything shadow chain slot
2. PipeWire starts automatically in the chroot
3. SSH into Move and enter the chroot:

```bash
ssh root@move.local
chroot /data/UserData/pw-chroot bash -l
```

4. Play audio (environment is auto-configured):

```bash
# Play an MP3
mpg321 -s song.mp3 | aplay -f S16_LE -r 44100 -c 2 -D pipewire

# Install and run apps
apt install guitarix
guitarix --jack
```

## Desktop Mode (VNC)

The desktop rootfs includes XFCE and a VNC server, giving you a full Linux desktop on the Move accessible from any VNC client.

### Building the Desktop Image

```bash
# Register QEMU binfmt (one-time)
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# Build desktop rootfs
./scripts/build-rootfs.sh --desktop
```

This creates a Debian sid arm64 rootfs with:
- XFCE4 desktop environment
- TigerVNC server
- PipeWire + ALSA + JACK
- User `move` with password `everything` (has passwordless sudo)
- pavucontrol, mpg321, alsa-utils, curl, nano

### Starting the VNC Server

```bash
ssh root@move.local

# Start VNC at 1080p (default)
sh /data/UserData/start-vnc.sh

# Or specify a resolution
sh /data/UserData/start-vnc.sh 2560x1440
sh /data/UserData/start-vnc.sh 1280x720
sh /data/UserData/start-vnc.sh 1024x768
```

Connect with any VNC client:
- **Address:** `move.local:5901`
- **Password:** `everything`

Most VNC clients (RealVNC, TigerVNC viewer, macOS Screen Sharing) also support dynamic resize — drag the window and the desktop will adapt.

### Stopping the VNC Server

```bash
ssh root@move.local
sh /data/UserData/start-vnc.sh stop
```

### Mounting the Chroot Manually

```bash
ssh root@move.local
sh /data/UserData/mount-chroot.sh

# Enter as root
chroot /data/UserData/pw-chroot bash -l

# Or as the desktop user
chroot /data/UserData/pw-chroot su - move
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
| Setuid helper | `src/pw-helper.c` |
| Chroot launcher | `src/start-pw.sh` |
| Chroot teardown | `src/stop-pw.sh` |
| Mount helper | `src/mount-chroot.sh` |
| VNC launcher | `src/start-vnc.sh` |
| Module UI | `src/ui.js` |
| Module metadata | `src/module.json` |
| Minimal rootfs | `scripts/Dockerfile.rootfs` |
| Desktop rootfs | `scripts/Dockerfile.rootfs-desktop` |

## Audio Specs

44100 Hz, stereo interleaved int16 (S16LE), 128-frame blocks (~2.9ms). Ring buffer provides 4 seconds of buffering. FIFO kernel buffer is set to 1MB to minimize dropouts.
