/* Debug plugin — real plugin with logging at every step to find the crash */
#include "plugin_api_v1.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <time.h>
#include <stdbool.h>

#define RING_SECONDS  2
#define RING_SAMPLES  (MOVE_AUDIO_SAMPLE_RATE * 2 * RING_SECONDS)
#define AUDIO_IDLE_MS 3000

static const host_api_v1_t *g_host = NULL;
static int g_log_fd = -1;

static void dbg(const char *msg) {
    /* Write to a debug file since we don't know if host->log works */
    if (g_log_fd < 0) {
        g_log_fd = open("/tmp/pw-dsp-debug.log",
                        O_WRONLY | O_CREAT | O_APPEND, 0666);
    }
    if (g_log_fd >= 0) {
        write(g_log_fd, msg, strlen(msg));
        write(g_log_fd, "\n", 1);
    }
    if (g_host && g_host->log) {
        g_host->log("[pw-dbg] %s", msg);
    }
}

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

typedef struct {
    char module_dir[512];
    char fifo_playback_path[256];
    char error_msg[256];
    int slot;
    int fifo_playback_fd;
    int16_t *ring;  /* heap-allocated instead of inline */
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

/* ── Ring Buffer ── */

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

/* ── FIFO ── */

static int create_fifo(pw_instance_t *inst) {
    dbg("create_fifo: enter");
    snprintf(inst->fifo_playback_path, sizeof(inst->fifo_playback_path),
             "/tmp/pw-to-move-%d", inst->slot);
    (void)unlink(inst->fifo_playback_path);
    dbg("create_fifo: mkfifo");
    if (mkfifo(inst->fifo_playback_path, 0666) != 0) {
        dbg("create_fifo: mkfifo FAILED");
        return -1;
    }
    dbg("create_fifo: open O_RDWR|O_NONBLOCK");
    inst->fifo_playback_fd = open(inst->fifo_playback_path, O_RDWR | O_NONBLOCK);
    if (inst->fifo_playback_fd < 0) {
        dbg("create_fifo: open FAILED");
        (void)unlink(inst->fifo_playback_path);
        return -1;
    }
    dbg("create_fifo: OK");
    return 0;
}

static void close_fifo(pw_instance_t *inst) {
    if (inst->fifo_playback_fd >= 0) {
        close(inst->fifo_playback_fd);
        inst->fifo_playback_fd = -1;
    }
    if (inst->fifo_playback_path[0])
        (void)unlink(inst->fifo_playback_path);
}

/* ── Pipe Pump ── */

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

/* ── Plugin API ── */

static void *v2_create_instance(const char *module_dir, const char *json_defaults) {
    pw_instance_t *inst;
    dbg("create_instance: enter");

    inst = calloc(1, sizeof(*inst));
    if (!inst) { dbg("create_instance: calloc FAILED"); return NULL; }
    dbg("create_instance: calloc OK");

    inst->slot = ++g_instance_counter;
    snprintf(inst->module_dir, sizeof(inst->module_dir), "%s",
             module_dir ? module_dir : ".");
    inst->gain = 1.0f;
    inst->fifo_playback_fd = -1;
    (void)json_defaults;

    dbg("create_instance: allocating ring buffer");
    inst->ring = calloc(RING_SAMPLES, sizeof(int16_t));
    if (!inst->ring) {
        dbg("create_instance: ring calloc FAILED");
        free(inst);
        return NULL;
    }
    dbg("create_instance: ring buffer OK");

    if (create_fifo(inst) != 0) {
        dbg("create_instance: create_fifo FAILED");
        free(inst->ring);
        free(inst);
        return NULL;
    }
    dbg("create_instance: FIFO OK");

    /* Don't start PipeWire chroot in this debug build — just test loading */
    inst->pw_running = false;
    dbg("create_instance: SUCCESS");
    return inst;
}

static void v2_destroy_instance(void *instance) {
    pw_instance_t *inst = (pw_instance_t *)instance;
    dbg("destroy_instance: enter");
    if (!inst) return;
    close_fifo(inst);
    free(inst->ring);
    free(inst);
    if (g_instance_counter > 0) g_instance_counter--;
    dbg("destroy_instance: done");
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
    }
}

static int v2_get_param(void *instance, const char *key, char *buf, int buf_len) {
    pw_instance_t *inst = (pw_instance_t *)instance;
    if (!inst || !key || !buf || buf_len <= 0) return -1;
    if (strcmp(key, "gain") == 0) {
        snprintf(buf, buf_len, "%.2f", inst->gain);
    } else if (strcmp(key, "status") == 0) {
        snprintf(buf, buf_len, "debug-mode");
    } else {
        return -1;
    }
    return 0;
}

static int v2_get_error(void *instance, char *buf, int buf_len) {
    (void)instance; (void)buf; (void)buf_len;
    return -1;
}

static void v2_render_block(void *instance, int16_t *out_interleaved_lr, int frames) {
    pw_instance_t *inst = (pw_instance_t *)instance;
    size_t needed, got, i;
    if (!out_interleaved_lr || frames <= 0) return;
    needed = (size_t)frames * 2;
    memset(out_interleaved_lr, 0, needed * sizeof(int16_t));
    if (!inst) return;
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
    /* keepalive */
    out_interleaved_lr[needed - 1] |= 5;
}

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
    dbg("move_plugin_init_v2 called");
    return &g_plugin_api_v2;
}
