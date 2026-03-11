/*
 * pipewire_plugin.c — Move Everything DSP plugin for PipeWire FIFO bridge
 *
 * Audio path:
 *   PipeWire sink → /tmp/pw-to-move-<slot> (FIFO) → ring buffer → render_block()
 *
 * The plugin runs as user 'ableton'. PipeWire chroot requires root, so
 * start/stop scripts are invoked via sudo (Move has passwordless sudo for root).
 * If sudo isn't available, user can start PipeWire manually via SSH.
 *
 * Based on the proven airplay_plugin.c FIFO bridge pattern.
 */

#define _GNU_SOURCE
#include "plugin_api_v1.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <stdbool.h>

/* ── Constants ────────────────────────────────────────── */

#define RING_SECONDS  4
#define RING_SAMPLES  (MOVE_AUDIO_SAMPLE_RATE * 2 * RING_SECONDS)
#define AUDIO_IDLE_MS 3000
#define FIFO_PIPE_SZ  (1024 * 1024)  /* 1MB kernel FIFO buffer */

/* ── Logging ──────────────────────────────────────────── */

static const host_api_v1_t *g_host = NULL;
static int g_log_fd = -1;

static void pw_log(const char *msg) {
    /* Always write to file — host->log may not be visible */
    if (g_log_fd < 0) {
        g_log_fd = open("/tmp/pw-dsp-debug.log",
                        O_WRONLY | O_CREAT | O_APPEND, 0666);
    }
    if (g_log_fd >= 0) {
        write(g_log_fd, "[pw] ", 5);
        write(g_log_fd, msg, strlen(msg));
        write(g_log_fd, "\n", 1);
    }
    if (g_host && g_host->log) {
        g_host->log("[pipewire] %s", msg);
    }
}

/* ── Timestamp ────────────────────────────────────────── */

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

/* ── Instance State ───────────────────────────────────── */

typedef struct {
    char module_dir[512];
    char fifo_playback_path[256];
    char error_msg[256];
    int slot;

    int fifo_playback_fd;

    int16_t *ring;  /* heap-allocated ring buffer */
    size_t write_pos;
    uint64_t write_abs;
    uint64_t play_abs;
    uint8_t pending_bytes[4];
    uint8_t pending_len;

    float gain;
    bool pw_running;
    bool receiving_audio;
    uint64_t last_audio_ms;
} pw_instance_t;

static int g_instance_counter = 0;

/* ── Error Handling ───────────────────────────────────── */

static void set_error(pw_instance_t *inst, const char *msg) {
    if (!inst) return;
    snprintf(inst->error_msg, sizeof(inst->error_msg), "%s", msg);
    pw_log(msg);
}

/* ── Ring Buffer ──────────────────────────────────────── */

static size_t ring_available(const pw_instance_t *inst) {
    uint64_t avail;
    if (!inst) return 0;
    if (inst->write_abs <= inst->play_abs) return 0;
    avail = inst->write_abs - inst->play_abs;
    if (avail > (uint64_t)RING_SAMPLES) avail = (uint64_t)RING_SAMPLES;
    return (size_t)avail;
}

static void ring_push(pw_instance_t *inst, const int16_t *samples, size_t n) {
    size_t i;
    uint64_t oldest;
    for (i = 0; i < n; i++) {
        inst->ring[inst->write_pos] = samples[i];
        inst->write_pos = (inst->write_pos + 1) % RING_SAMPLES;
        inst->write_abs++;
    }
    oldest = 0;
    if (inst->write_abs > (uint64_t)RING_SAMPLES)
        oldest = inst->write_abs - (uint64_t)RING_SAMPLES;
    if (inst->play_abs < oldest)
        inst->play_abs = oldest;
}

static size_t ring_pop(pw_instance_t *inst, int16_t *out, size_t n) {
    size_t got, i;
    uint64_t abs_pos;
    if (!inst || !out || n == 0) return 0;
    got = ring_available(inst);
    if (got > n) got = n;
    abs_pos = inst->play_abs;
    for (i = 0; i < got; i++) {
        out[i] = inst->ring[(size_t)(abs_pos % (uint64_t)RING_SAMPLES)];
        abs_pos++;
    }
    inst->play_abs = abs_pos;
    return got;
}

/* ── FIFO Management ──────────────────────────────────── */

static int create_fifo(pw_instance_t *inst) {
    struct stat st;

    if (!inst) return -1;

    snprintf(inst->fifo_playback_path, sizeof(inst->fifo_playback_path),
             "/tmp/pw-to-move-%d", inst->slot);

    pw_log("create_fifo: creating FIFO");

    /* Remove stale FIFO. If unlink fails (owned by another user), try
     * opening the existing FIFO — it may still be usable. */
    if (unlink(inst->fifo_playback_path) != 0 && errno != ENOENT) {
        /* Can't remove — check if it's already a FIFO we can use */
        if (stat(inst->fifo_playback_path, &st) == 0 && S_ISFIFO(st.st_mode)) {
            pw_log("create_fifo: reusing existing FIFO");
            inst->fifo_playback_fd = open(inst->fifo_playback_path, O_RDWR | O_NONBLOCK);
            if (inst->fifo_playback_fd >= 0) {
                (void)fcntl(inst->fifo_playback_fd, F_SETPIPE_SZ, FIFO_PIPE_SZ);
                pw_log("create_fifo: reuse OK");
                return 0;
            }
        }
        set_error(inst, "cannot remove stale FIFO");
        return -1;
    }

    if (mkfifo(inst->fifo_playback_path, 0666) != 0) {
        set_error(inst, "mkfifo failed");
        return -1;
    }

    inst->fifo_playback_fd = open(inst->fifo_playback_path, O_RDWR | O_NONBLOCK);
    if (inst->fifo_playback_fd < 0) {
        set_error(inst, "open FIFO failed");
        (void)unlink(inst->fifo_playback_path);
        return -1;
    }

    /* Increase kernel pipe buffer to reduce dropouts */
    (void)fcntl(inst->fifo_playback_fd, F_SETPIPE_SZ, FIFO_PIPE_SZ);

    pw_log("create_fifo: OK");
    return 0;
}

static void close_fifo(pw_instance_t *inst) {
    if (!inst) return;
    if (inst->fifo_playback_fd >= 0) {
        close(inst->fifo_playback_fd);
        inst->fifo_playback_fd = -1;
    }
    if (inst->fifo_playback_path[0] != '\0') {
        (void)unlink(inst->fifo_playback_path);
    }
}

/* ── Pipe Pump (FIFO → Ring Buffer) ──────────────────── */

static void pump_pipe(pw_instance_t *inst) {
    uint8_t buf[4096];
    uint8_t merged[4100];
    int16_t samples[2048];

    if (!inst || inst->fifo_playback_fd < 0) return;

    while (1) {
        if (ring_available(inst) + 2048 >= (size_t)RING_SAMPLES) break;

        ssize_t n = read(inst->fifo_playback_fd, buf, sizeof(buf));
        if (n > 0) {
            size_t merged_bytes = inst->pending_len;
            size_t aligned_bytes, remainder, sample_count;

            if (inst->pending_len > 0)
                memcpy(merged, inst->pending_bytes, inst->pending_len);
            memcpy(merged + merged_bytes, buf, (size_t)n);
            merged_bytes += (size_t)n;

            aligned_bytes = merged_bytes & ~((size_t)3U);
            remainder = merged_bytes - aligned_bytes;
            if (remainder > 0)
                memcpy(inst->pending_bytes, merged + aligned_bytes, remainder);
            inst->pending_len = (uint8_t)remainder;

            sample_count = aligned_bytes / sizeof(int16_t);
            if (sample_count > 0) {
                memcpy(samples, merged, sample_count * sizeof(int16_t));
                ring_push(inst, samples, sample_count);
            }

            inst->last_audio_ms = now_ms();
            inst->receiving_audio = true;

            if ((size_t)n < sizeof(buf)) break;
            continue;
        }

        break;
    }

    if (inst->receiving_audio && inst->last_audio_ms > 0) {
        uint64_t now = now_ms();
        if (now > inst->last_audio_ms && (now - inst->last_audio_ms) > AUDIO_IDLE_MS)
            inst->receiving_audio = false;
    }
}

/* ── PipeWire Chroot Daemon ───────────────────────────── */

static void start_pw_chroot(pw_instance_t *inst) {
    char slot_str[8];
    if (!inst) return;

    /* Plugin runs as 'ableton' but chroot/mount need root.
     * Use setuid pw-helper binary installed at /usr/local/bin.
     * Fork + exec to avoid blocking the audio thread. */
    snprintf(slot_str, sizeof(slot_str), "%d", inst->slot);

    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        /* Close FIFO fd so child/PipeWire don't inherit it */
        if (inst->fifo_playback_fd >= 0)
            close(inst->fifo_playback_fd);
        /* Close log fd */
        if (g_log_fd >= 0)
            close(g_log_fd);
        int fd = open("/tmp/pw-start.log", O_WRONLY | O_CREAT | O_TRUNC, 0666);
        if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
        execl("/usr/local/bin/pw-helper", "pw-helper", "start",
              inst->fifo_playback_path, slot_str, (char *)NULL);
        _exit(127);
    }

    /* Don't wait for child — it runs in background */
    inst->pw_running = true;
    pw_log("PipeWire chroot launch requested (via pw-helper)");
}

static void stop_pw_chroot(pw_instance_t *inst) {
    char cmd[256];
    if (!inst) return;

    snprintf(cmd, sizeof(cmd),
             "/usr/local/bin/pw-helper stop %d >/dev/null 2>&1",
             inst->slot);
    (void)system(cmd);

    inst->pw_running = false;
    pw_log("PipeWire chroot stopped");
}

static void check_pw_alive(pw_instance_t *inst) {
    static int check_counter = 0;
    char pid_path[64];
    char pid_buf[16];
    int fd, pid;

    if (++check_counter < 17200) return;  /* ~every 50 seconds */
    check_counter = 0;

    if (!inst || !inst->pw_running) return;

    /* Non-blocking check: read PID file and test with kill(pid, 0) */
    snprintf(pid_path, sizeof(pid_path), "/tmp/pw-pids-%d/pipewire.pid", inst->slot);
    fd = open(pid_path, O_RDONLY);
    if (fd < 0) {
        inst->pw_running = false;
        pw_log("PipeWire PID file not found");
        return;
    }
    memset(pid_buf, 0, sizeof(pid_buf));
    (void)read(fd, pid_buf, sizeof(pid_buf) - 1);
    close(fd);
    pid = atoi(pid_buf);
    if (pid <= 0 || kill(pid, 0) != 0) {
        inst->pw_running = false;
        pw_log("PipeWire process not found");
    }
}

/* ── Plugin API v2 Implementation ─────────────────────── */

static void *v2_create_instance(const char *module_dir, const char *json_defaults) {
    pw_instance_t *inst;

    pw_log("create_instance: enter");

    inst = calloc(1, sizeof(*inst));
    if (!inst) { pw_log("create_instance: calloc failed"); return NULL; }

    inst->slot = ++g_instance_counter;
    snprintf(inst->module_dir, sizeof(inst->module_dir), "%s",
             module_dir ? module_dir : ".");
    inst->gain = 1.0f;
    inst->fifo_playback_fd = -1;
    (void)json_defaults;

    /* Heap-allocate ring buffer */
    inst->ring = calloc(RING_SAMPLES, sizeof(int16_t));
    if (!inst->ring) {
        pw_log("create_instance: ring alloc failed");
        free(inst);
        return NULL;
    }

    if (create_fifo(inst) != 0) {
        pw_log("create_instance: FIFO failed");
        free(inst->ring);
        free(inst);
        return NULL;
    }

    /* Start PipeWire in background — don't block or fail on error */
    start_pw_chroot(inst);

    pw_log("create_instance: OK");
    return inst;
}

static void v2_destroy_instance(void *instance) {
    pw_instance_t *inst = (pw_instance_t *)instance;
    if (!inst) return;
    pw_log("destroy_instance");

    stop_pw_chroot(inst);
    close_fifo(inst);

    free(inst->ring);
    free(inst);
    if (g_instance_counter > 0) g_instance_counter--;
}

static void v2_on_midi(void *instance, const uint8_t *msg, int len, int source) {
    (void)instance; (void)msg; (void)len; (void)source;
}

static void v2_set_param(void *instance, const char *key, const char *val) {
    pw_instance_t *inst = (pw_instance_t *)instance;
    if (!inst || !key || !val) return;

    if (strcmp(key, "gain") == 0) {
        inst->gain = strtof(val, NULL);
        if (inst->gain < 0.0f) inst->gain = 0.0f;
        if (inst->gain > 2.0f) inst->gain = 2.0f;
    } else if (strcmp(key, "restart") == 0) {
        stop_pw_chroot(inst);
        start_pw_chroot(inst);
    }
}

static int v2_get_param(void *instance, const char *key, char *buf, int buf_len) {
    pw_instance_t *inst = (pw_instance_t *)instance;
    if (!inst || !key || !buf || buf_len <= 0) return -1;

    if (strcmp(key, "gain") == 0) {
        snprintf(buf, buf_len, "%.2f", inst->gain);
    } else if (strcmp(key, "status") == 0) {
        if (inst->pw_running && inst->receiving_audio)
            snprintf(buf, buf_len, "receiving");
        else if (inst->pw_running)
            snprintf(buf, buf_len, "running");
        else
            snprintf(buf, buf_len, "stopped");
    } else if (strcmp(key, "fifo") == 0) {
        snprintf(buf, buf_len, "%s", inst->fifo_playback_path);
    } else {
        return -1;
    }
    return 0;
}

static int v2_get_error(void *instance, char *buf, int buf_len) {
    pw_instance_t *inst = (pw_instance_t *)instance;
    if (!inst || !buf || buf_len <= 0) return -1;
    if (inst->error_msg[0] == '\0') return -1;
    snprintf(buf, buf_len, "%s", inst->error_msg);
    inst->error_msg[0] = '\0';
    return 0;
}

static void v2_render_block(void *instance, int16_t *out_interleaved_lr, int frames) {
    pw_instance_t *inst = (pw_instance_t *)instance;
    size_t needed, got, i;

    if (!out_interleaved_lr || frames <= 0) return;

    needed = (size_t)frames * 2;
    memset(out_interleaved_lr, 0, needed * sizeof(int16_t));

    if (!inst) return;

    check_pw_alive(inst);
    pump_pipe(inst);

    got = ring_pop(inst, out_interleaved_lr, needed);

    if (inst->gain != 1.0f && got > 0) {
        for (i = 0; i < got; i++) {
            float s = out_interleaved_lr[i] * inst->gain;
            if (s > 32767.0f) s = 32767.0f;
            if (s < -32768.0f) s = -32768.0f;
            out_interleaved_lr[i] = (int16_t)s;
        }
    }

    /* Keepalive */
    out_interleaved_lr[needed - 1] |= 5;
}

/* ── Plugin Registration ──────────────────────────────── */

static plugin_api_v2_t g_plugin_api_v2 = {
    .api_version      = MOVE_PLUGIN_API_VERSION_2,
    .create_instance  = v2_create_instance,
    .destroy_instance = v2_destroy_instance,
    .on_midi          = v2_on_midi,
    .set_param        = v2_set_param,
    .get_param        = v2_get_param,
    .get_error        = v2_get_error,
    .render_block     = v2_render_block,
};

plugin_api_v2_t* move_plugin_init_v2(const host_api_v1_t *host) {
    g_host = host;
    pw_log("move_plugin_init_v2 called");
    return &g_plugin_api_v2;
}
