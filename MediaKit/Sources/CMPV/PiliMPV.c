#include "PiliMPV.h"
#include <dlfcn.h>
#include <stdio.h>

int pili_mpv_command(mpv_handle *mpv, const char *const *args) {
    return mpv_command(mpv, (const char **)args);
}

int pili_mpv_load(mpv_handle *mpv, const char *url, const char *audio, const char *referer,
                  const char *agent, double start, int paused) {
    int r = mpv_set_property_string(mpv, "referrer", referer);
    if (r < 0) return r;
    r = mpv_set_property_string(mpv, "user-agent", agent);
    if (r < 0) return r;
    mpv_node value = {.format = MPV_FORMAT_STRING, .u.string = (char *)audio};
    mpv_node_list list = {.num = audio && *audio ? 1 : 0, .values = &value};
    mpv_node files = {.format = MPV_FORMAT_NODE_ARRAY, .u.list = &list};
    r = mpv_set_property(mpv, "audio-files", MPV_FORMAT_NODE, &files);
    if (r < 0) return r;
    r = mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &paused);
    if (r < 0) return r;
    char options[128];
    snprintf(options, sizeof(options), "start=%.6f", start > 0 ? start : 0);
    const char *args[] = {"loadfile", url, "replace", "-1", options, NULL};
    return mpv_command(mpv, args);
}

static void *get_proc(void *unused, const char *name) { return dlsym(RTLD_DEFAULT, name); }
int pili_mpv_create_renderer(mpv_handle *mpv, mpv_render_context **context) {
    mpv_opengl_init_params gl = {.get_proc_address = get_proc};
    int advanced = 1;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
        {MPV_RENDER_PARAM_INVALID, NULL}
    };
    return mpv_render_context_create(context, mpv, params);
}
static void render_gl(mpv_render_context *context, int fbo, int width, int height, int flip) {
    mpv_opengl_fbo target = {.fbo = fbo, .w = width, .h = height, .internal_format = 0};
    int block = 0;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &target},
        {MPV_RENDER_PARAM_FLIP_Y, &flip},
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block},
        {MPV_RENDER_PARAM_INVALID, NULL}
    };
    mpv_render_context_render(context, params);
}
void pili_mpv_render(mpv_render_context *context, int fbo, int width, int height) {
    render_gl(context, fbo, width, height, 1);
}
void pili_mpv_render_buffer(mpv_render_context *context, int fbo, int width, int height) {
    render_gl(context, fbo, width, height, 0);
}
int pili_mpv_create_software_renderer(mpv_handle *mpv, mpv_render_context **context) {
    int advanced = 1;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
        {MPV_RENDER_PARAM_INVALID, NULL}
    };
    return mpv_render_context_create(context, mpv, params);
}
int pili_mpv_render_software(mpv_render_context *context, void *pixels, int width, int height, size_t stride) {
    int size[] = {width, height};
    int block = 0;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_SW_SIZE, size},
        {MPV_RENDER_PARAM_SW_FORMAT, "bgra"},
        {MPV_RENDER_PARAM_SW_STRIDE, &stride},
        {MPV_RENDER_PARAM_SW_POINTER, pixels},
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block},
        {MPV_RENDER_PARAM_INVALID, NULL}
    };
    return mpv_render_context_render(context, params);
}
void pili_mpv_skip_render(mpv_render_context *context) {
    int skip = 1;
    int block = 0;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_SKIP_RENDERING, &skip},
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block},
        {MPV_RENDER_PARAM_INVALID, NULL}
    };
    mpv_render_context_render(context, params);
}
int pili_mpv_rebind_video(mpv_handle *mpv, const char *hardware, int enabled, double position) {
    int result = mpv_set_property_string(mpv, "hwdec", hardware);
    if (result < 0) return result;
    result = mpv_set_property_string(mpv, "vid", "no");
    if (result < 0 || !enabled) return result;
    result = mpv_set_property_string(mpv, "vid", "auto");
    if (result < 0 || position < 0) return result;
    // Re-selection can use the audio decoder's buffered PTS. Seek to the playback
    // clock to keep the video and separate audio tracks aligned after the handoff.
    char target[64];
    snprintf(target, sizeof(target), "%.6f", position);
    const char *args[] = {"seek", target, "absolute+exact", NULL};
    return mpv_command(mpv, args);
}
