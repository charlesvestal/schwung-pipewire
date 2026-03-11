/* Absolute minimal plugin — does nothing, just proves dlopen + init works */
#include "plugin_api_v1.h"
#include <stdlib.h>
#include <string.h>

static const host_api_v1_t *g_host = NULL;

static void *v2_create_instance(const char *module_dir, const char *json_defaults) {
    (void)module_dir; (void)json_defaults;
    /* Return a non-NULL pointer so the host thinks we succeeded */
    return malloc(1);
}

static void v2_destroy_instance(void *instance) {
    free(instance);
}

static void v2_on_midi(void *instance, const uint8_t *msg, int len, int source) {
    (void)instance; (void)msg; (void)len; (void)source;
}

static void v2_set_param(void *instance, const char *key, const char *val) {
    (void)instance; (void)key; (void)val;
}

static int v2_get_param(void *instance, const char *key, char *buf, int buf_len) {
    (void)instance; (void)key; (void)buf; (void)buf_len;
    return -1;
}

static int v2_get_error(void *instance, char *buf, int buf_len) {
    (void)instance; (void)buf; (void)buf_len;
    return -1;
}

static void v2_render_block(void *instance, int16_t *out_interleaved_lr, int frames) {
    (void)instance;
    if (out_interleaved_lr && frames > 0) {
        memset(out_interleaved_lr, 0, (size_t)frames * 2 * sizeof(int16_t));
    }
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
    return &g_plugin_api_v2;
}
