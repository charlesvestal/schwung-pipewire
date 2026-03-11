/*
 * ui.js — PipeWire Bridge module UI
 * 128x64 monochrome display, QuickJS runtime
 */

var status = "stopped";
var gain = 1.0;
var tickCount = 0;
var spinner = ["-", "/", "|", "\\"];

function init() {
    refreshState();
}

function refreshState() {
    var s = get_param("status");
    if (s) status = s;
    var g = get_param("gain");
    if (g) gain = parseFloat(g);
}

function tick() {
    tickCount++;

    /* Refresh state every ~1 second (60 ticks) */
    if (tickCount % 60 === 0) {
        refreshState();
    }

    clear();

    /* Header */
    print(0, 0, "PipeWire Bridge");

    /* Status line */
    var statusText = "";
    if (status === "receiving") {
        statusText = "Receiving audio";
    } else if (status === "running") {
        var sp = spinner[Math.floor(tickCount / 10) % 4];
        statusText = "Running " + sp;
    } else {
        statusText = "Stopped";
    }
    print(0, 12, statusText);

    /* Gain */
    print(0, 24, "Gain: " + gain.toFixed(2));

    /* Connection info */
    print(0, 38, "ssh root@move.local");
    print(0, 48, "chroot /data/UserData");
    print(0, 56, "  /pw-chroot bash");
}

function onMidiMessageInternal(status_byte, data1, data2) {
    /* Knob 1 (CC 71): gain control */
    if ((status_byte & 0xF0) === 0xB0 && data1 === 71) {
        gain = data2 / 63.5;  /* 0-127 → 0.0-2.0 */
        set_param("gain", gain.toFixed(2));
    }

    /* Pad 1 press: restart PipeWire */
    if ((status_byte & 0xF0) === 0x90 && data1 === 36 && data2 > 0) {
        set_param("restart", "1");
    }
}

function onMidiMessageExternal(status_byte, data1, data2) {
    /* unused */
}

/* Export for Move Everything host */
globalThis.chain_ui = {
    init: init,
    tick: tick,
    onMidiMessageInternal: onMidiMessageInternal,
    onMidiMessageExternal: onMidiMessageExternal
};
