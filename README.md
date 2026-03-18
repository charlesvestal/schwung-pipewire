# move-everything-pipewire

A [Move Everything](https://github.com/charlesvestal/move-everything) sound generator module that bridges PipeWire audio and MIDI to the Ableton Move. Run any ALSA, JACK, or PipeWire app inside a Debian chroot and hear it through Move's speakers — with full bidirectional MIDI.

- **PipeWire** — audio bridge with bidirectional MIDI between Move and the chroot

## How It Works

### Audio

```
PipeWire app (in chroot) → pipe-tunnel sink → FIFO → ring buffer → render_block() → Move audio out
```

The DSP plugin creates a named pipe. PipeWire's `module-pipe-tunnel` writes audio to it. The plugin reads from the pipe into a ring buffer and outputs it through Move's SPI mailbox. The whole thing runs alongside stock Move in a shadow chain slot.

### MIDI (PipeWire + MIDI module)

```
Move pads/keys → on_midi() → FIFO → midi-bridge → PipeWire MIDI → JACK apps in chroot
JACK apps in chroot → PipeWire MIDI → midi-bridge → FIFO → send_midi_internal() → Move
```

A compiled C bridge (`midi-bridge`) runs inside the chroot as a PipeWire filter, creating two JACK MIDI ports:
- **Move MIDI In** — receives MIDI from Move (pads, knobs, sequences)
- **Move MIDI Out** — sends MIDI back to Move

MIDI is transported over FIFOs using a 2-byte little-endian length-prefixed framing protocol, supporting all MIDI messages including SysEx.

## Prerequisites

- Docker (with BuildKit)
- QEMU binfmt for arm64 emulation (rootfs build on x86 hosts only — Apple Silicon builds arm64 natively)
- SSH access to Move (`root@move.local` and `ableton@move.local`)
- [Move Everything](https://github.com/charlesvestal/move-everything) installed on Move

## Build

```bash
# Cross-compile DSP plugin + package module
# (automatically cleans previous build artifacts)
./scripts/build.sh

# One-time on x86 hosts: register QEMU binfmt for arm64 emulation
# (skip this on Apple Silicon — Docker runs arm64 natively)
# docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# Build minimal rootfs (PipeWire only, ~120MB)
./scripts/build-rootfs.sh

# Build desktop rootfs (XFCE + VNC + PipeWire, ~500MB)
./scripts/build-rootfs.sh --desktop
```

## Install

```bash
# Deploy to Move (module + rootfs + convenience scripts)
# Replace move.local with your device's IP address if mDNS is not available
./scripts/install.sh

# Or specify a custom host
DEVICE_HOST=192.168.1.199 ./scripts/install.sh
```

The installer deploys whichever rootfs was built (prefers desktop if both exist). Module files and convenience scripts are deployed as `ableton@`; only the setuid helper, rootfs extraction, and chroot configuration require `root@`.

## Usage

### Audio Only (PipeWire module)

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

### Audio + MIDI (PipeWire + MIDI module)

1. Load **PipeWire** as a sound generator in a Move Everything shadow chain slot
2. PipeWire and the MIDI bridge start automatically
3. SSH into Move and enter the chroot:

```bash
ssh root@move.local
chroot /data/UserData/pw-chroot bash -l
su - move
```

4. Run a MIDI synth — Move pads play notes through the chroot:

```bash
# FluidSynth with a GM soundfont
pw-jack fluidsynth --midi-driver=jack --audio-driver=jack -r 48000 \
    /usr/share/sounds/sf2/FluidR3_GM.sf2

# Connect Move MIDI to FluidSynth (in another terminal)
pw-jack jack_connect "Move MIDI Bridge:Move MIDI In" "fluidsynth-midi:midi_00"
```

5. List available MIDI and audio ports:

```bash
pw-jack jack_lsp
```

> **Important:** Always launch JACK apps with the `pw-jack` wrapper so they find PipeWire's JACK server. PipeWire runs at 48000 Hz in the chroot — set synth sample rates to match (`-r 48000`).

### JACK Physical Port Shim

Some JACK apps (Yoshimi, some versions of Ardour) require "physical" JACK ports and refuse to start without them. PipeWire's pipe-tunnel creates virtual ports that lack this flag. The `pw-jack-physical` wrapper solves this:

```bash
# Use pw-jack-physical instead of pw-jack for apps that need physical ports
pw-jack-physical yoshimi -J -j

# Then connect Move MIDI (in another terminal)
pw-jack-physical jack_connect "Move MIDI Bridge:Move MIDI In" "yoshimi:midi in"
```

The wrapper uses an `LD_PRELOAD` shim (`jack-physical-shim.so`) that makes all PipeWire ports appear as physical JACK ports. Use `pw-jack-physical` as a drop-in replacement for `pw-jack` whenever an app complains about missing physical ports.

Apps that work fine with plain `pw-jack` (FluidSynth, Carla, etc.) don't need the shim.

## Desktop Mode (VNC)

The desktop rootfs includes XFCE and a VNC server, giving you a full Linux desktop on the Move accessible from any VNC client. Run graphical audio apps like Renoise, Guitarix, or Audacity — audio routes through PipeWire to Move's speakers.

### Quick Start

1. Build and deploy the desktop rootfs (see [Build](#build) and [Install](#install))
2. Open Move Everything on Move and load **PipeWire** (audio only) or **PipeWire + MIDI** (audio + MIDI) as a sound generator
3. SSH into Move and start VNC:

```bash
ssh root@move.local
sh /data/UserData/start-vnc.sh
```

4. Connect a VNC client to `move.local:5901` (password: `everything`)
5. Open apps from the XFCE desktop — audio just works via PipeWire

### Building the Desktop Image

```bash
# Register QEMU binfmt (one-time)
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# Build desktop rootfs
./scripts/build-rootfs.sh --desktop
```

This creates a Debian sid arm64 rootfs (~500MB) with:
- XFCE4 desktop environment
- TigerVNC server
- PipeWire + PulseAudio + ALSA + JACK (all routed to Move audio out)
- Falkon web browser
- User `move` with password `everything` (has passwordless sudo)
- pavucontrol, mpg321, alsa-utils, curl, nano

### Starting the VNC Server

The PipeWire sound generator must be loaded first — it creates the audio bridge FIFO that PipeWire writes to.

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

### MIDI with GUI Apps (VNC)

Load the **PipeWire + MIDI** module, then start VNC. Inside the XFCE desktop, any JACK-aware app sees Move's MIDI ports. After launching an app, connect Move's MIDI port to it:

```bash
# General pattern: connect Move MIDI to any app's MIDI input
pw-jack jack_connect "Move MIDI Bridge:Move MIDI In" "<app>:<midi-input-port>"
```

**QjackCtl (visual patchbay — highly recommended):**
```bash
sudo apt install qjackctl
pw-jack qjackctl
```
Gives you a GUI to drag-connect MIDI and audio ports between apps. Use this instead of `jack_connect` commands.

**Qsynth (FluidSynth GUI):**
```bash
sudo apt install qsynth fluidsynth
pw-jack qsynth
# Connect MIDI:
pw-jack jack_connect "Move MIDI Bridge:Move MIDI In" "fluidsynth-midi:midi_00"
```
In Qsynth settings: MIDI driver → `jack`, Audio driver → `jack`, sample rate → `48000`.

**Carla (plugin host — runs VSTs, LV2, SF2, SFZ):**
```bash
sudo apt install carla
pw-jack carla
```
Load any synth plugin. Connect "Move MIDI Bridge:Move MIDI In" to its MIDI input in Carla's patchbay tab.

**Yoshimi / ZynAddSubFX (requires physical port shim):**
```bash
sudo apt install yoshimi
pw-jack-physical yoshimi -J -j
# Connect MIDI:
pw-jack-physical jack_connect "Move MIDI Bridge:Move MIDI In" "yoshimi:midi in"
```
Note: Yoshimi requires `pw-jack-physical` (not `pw-jack`) because it refuses to start without physical JACK ports. See [JACK Physical Port Shim](#jack-physical-port-shim).

**Any JACK app** works the same way — launch with `pw-jack` (or `pw-jack-physical` if it requires physical ports), then connect MIDI with `jack_connect` or QjackCtl.

### JACK Apps (Renoise, etc.)

Some JACK apps need the PipeWire JACK library override to connect:

```bash
chroot /data/UserData/pw-chroot su - move
sudo cp /usr/share/doc/pipewire/examples/ld.so.conf.d/pipewire-jack-*.conf /etc/ld.so.conf.d/
sudo ldconfig
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

### PipeWire (audio only)

| Component | File |
|-----------|------|
| DSP plugin | `src/dsp/pipewire_plugin.c` |
| Setuid helper | `src/pw-helper.c` |
| Chroot launcher | `src/start-pw.sh` |
| Chroot teardown | `src/stop-pw.sh` |
| Module UI | `src/ui.js` |
| Module metadata | `src/module.json` |

### PipeWire + MIDI

| Component | File |
|-----------|------|
| DSP plugin (audio + MIDI FIFOs) | `src/dsp/pipewire_midi_plugin.c` |
| MIDI bridge (PipeWire filter) | `src/midi-bridge.c` |
| Setuid helper | `src/pw-helper-midi.c` |
| Chroot launcher | `src/start-pw-midi.sh` |
| Chroot teardown | `src/stop-pw-midi.sh` |
| Module UI | `src/pipewire-midi/ui.js` |
| Module metadata | `src/pipewire-midi/module.json` |

### Shared

| Component | File |
|-----------|------|
| Mount helper | `src/mount-chroot.sh` |
| VNC launcher | `src/start-vnc.sh` |
| JACK physical port shim | `src/jack-physical-shim.c` |
| pw-jack-physical wrapper | `src/pw-jack-physical` |
| Minimal rootfs | `scripts/Dockerfile.rootfs` |
| Desktop rootfs | `scripts/Dockerfile.rootfs-desktop` |
| Build script | `scripts/build.sh` |
| Install script | `scripts/install.sh` |

## Audio Specs

44100 Hz, stereo interleaved int16 (S16LE), 128-frame blocks (~2.9ms). Ring buffer provides 4 seconds of buffering. FIFO kernel buffer is set to 1MB to minimize dropouts.

## MIDI Specs

Bidirectional MIDI over FIFOs with 2-byte little-endian length-prefixed framing. Supports all MIDI messages including SysEx (up to 65535 bytes per message). Non-blocking I/O with accumulation buffers for partial reads. JACK MIDI ports appear as "Move MIDI In" and "Move MIDI Out" in the chroot.


## AI Assistance Disclaimer

This module is part of Move Everything and was developed with AI assistance, including Claude and other AI assistants.

All architecture, implementation, and release decisions are reviewed by human maintainers.
AI-assisted content may still contain errors, so please validate functionality, security, and license compatibility before production use.
