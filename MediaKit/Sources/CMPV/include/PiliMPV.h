#pragma once
#if __has_include(<mpv/client.h>)
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>
#else
#include "../../../Vendor/include/mpv/client.h"
#include "../../../Vendor/include/mpv/render.h"
#include "../../../Vendor/include/mpv/render_gl.h"
#endif

int pili_mpv_load(mpv_handle *mpv, const char *url, const char *audio, const char *referer,
                  const char *agent, double start, int paused);
int pili_mpv_command(mpv_handle *mpv, const char *const *args);
int pili_mpv_create_renderer(mpv_handle *mpv, mpv_render_context **context);
void pili_mpv_render(mpv_render_context *context, int fbo, int width, int height);
void pili_mpv_render_buffer(mpv_render_context *context, int fbo, int width, int height);
int pili_mpv_create_software_renderer(mpv_handle *mpv, mpv_render_context **context);
int pili_mpv_render_software(mpv_render_context *context, void *pixels, int width, int height, size_t stride);
void pili_mpv_skip_render(mpv_render_context *context);
int pili_mpv_rebind_video(mpv_handle *mpv, const char *hardware, int enabled, double position);
