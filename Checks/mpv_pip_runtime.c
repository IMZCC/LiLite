#include "PiliMPV.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// Exercise the production software render bridge, including context replacement while
// audio continues. The iOS GL-to-SW handoff uses the same free/create/vid re-selection.
static mpv_handle *player;
static atomic_int operation, finished, frames, colorful, changes;
static atomic_uint_fast64_t checksum;
static void *render_thread(void *unused) {
    mpv_render_context *context = NULL;
    unsigned char *pixels = calloc(640 * 360, 4);
    assert(pixels);
    uint64_t last = 0;
    for (;;) {
        int request = atomic_exchange(&operation, 0);
        if (request == 1 || request == 2) {
            mpv_render_context_free(context);
            context = NULL;
            if (request == 2) break;
            assert(pili_mpv_create_software_renderer(player, &context) >= 0);
            atomic_store(&finished, 1);
        }
        if (context && (mpv_render_context_update(context) & MPV_RENDER_UPDATE_FRAME)) {
            assert(pili_mpv_render_software(context, pixels, 640, 360, 640 * 4) >= 0);
            uint64_t hash = 1469598103934665603ULL;
            int nonblack = 0;
            for (int i = 0; i < 640 * 360; i += 97) {
                hash = (hash ^ pixels[i * 4]) * 1099511628211ULL;
                hash = (hash ^ pixels[i * 4 + 1]) * 1099511628211ULL;
                hash = (hash ^ pixels[i * 4 + 2]) * 1099511628211ULL;
                nonblack += pixels[i * 4] + pixels[i * 4 + 1] + pixels[i * 4 + 2] > 30;
            }
            if (nonblack > 100) {
                atomic_fetch_add(&colorful, 1);
                if (last != hash) atomic_fetch_add(&changes, 1);
                last = hash;
            }
            atomic_store(&checksum, hash);
            atomic_fetch_add(&frames, 1);
            mpv_render_context_report_swap(context);
        }
        usleep(1000);
    }
    free(pixels);
    return NULL;
}
static double number(const char *name) {
    double value = 0;
    assert(mpv_get_property(player, name, MPV_FORMAT_DOUBLE, &value) >= 0);
    return value;
}
static void property(const char *name, const char *value) { assert(mpv_set_property_string(player, name, value) >= 0); }
static void replace_renderer(void) {
    atomic_store(&finished, 0);
    atomic_store(&operation, 1);
    for (int n = 0; n < 10000 && !atomic_load(&finished); n++) usleep(1000);
    assert(atomic_load(&finished));
}
static void wait_picture(int previous) {
    for (int n = 0; n < 5000 && atomic_load(&colorful) <= previous; n++) {
        mpv_event *event;
        while ((event = mpv_wait_event(player, 0))->event_id != MPV_EVENT_NONE) {
            if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
                mpv_event_log_message *message = event->data;
                fprintf(stderr, "%s: %s", message->prefix, message->text);
            }
        }
        usleep(1000);
    }
    if (atomic_load(&colorful) <= previous) fprintf(stderr, "pictures=%d previous=%d frames=%d\n", atomic_load(&colorful), previous, atomic_load(&frames));
    assert(atomic_load(&colorful) > previous);
}
int main(int argc, char **argv) {
    assert(argc == 3);
    player = mpv_create(); assert(player);
    const char *options[][2] = {{"config","no"},{"terminal","no"},{"vo","libmpv"},{"ao","null"},
      {"idle","yes"},{"keep-open","yes"},{"hwdec","no"},{"sws-fast","yes"},{"sws-scaler","bilinear"}};
    for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); i++) {
        int result = mpv_set_option_string(player, options[i][0], options[i][1]);
        if (result < 0) fprintf(stderr, "%s: %s\n", options[i][0], mpv_error_string(result));
        assert(result >= 0);
    }
    assert(mpv_initialize(player) >= 0);
    mpv_request_log_messages(player, "debug");
    pthread_t thread;
    assert(pthread_create(&thread, NULL, render_thread, NULL) == 0);
    replace_renderer();
    assert(pili_mpv_load(player, argv[1], argv[2], "https://www.bilibili.com/", "Mozilla/5.0 CMPV check", 1, 1) >= 0);
    wait_picture(0);
    fprintf(stderr, "initial picture OK\n");
    assert(number("aid") > 0 && number("vid") > 0);
    property("speed", "3");
    property("pause", "no");
    usleep(250000);
    double before = number("time-pos");
    usleep(800000);
    double advance = number("time-pos") - before;
    assert(advance > 1.8 && advance < 3.0);
    for (int n = 0; n < 4; n++) {
        fprintf(stderr, "replacing renderer %d\n", n);
        property("pause", "yes");
        double position = number("time-pos");
        replace_renderer();
        int prior = atomic_load(&colorful);
        assert(pili_mpv_rebind_video(player, "no", 1, position) >= 0);
        wait_picture(prior);
        assert(number("aid") > 0 && number("vid") > 0);
        fprintf(stderr, "position before %.3f after %.3f\n", position, number("time-pos"));
        assert(fabs(number("time-pos") - position) < 0.3);
        usleep(50000);
        uint64_t paused = atomic_load(&checksum);
        usleep(250000);
        assert(paused == atomic_load(&checksum));
        property("pause", "no");
        wait_picture(atomic_load(&colorful));
        usleep(180000);
    }
    property("pause", "yes");
    int prior = atomic_load(&colorful);
    const char *seek[] = {"seek", "2.5", "absolute+exact", NULL};
    assert(pili_mpv_command(player, seek) >= 0);
    wait_picture(prior);
    assert(fabs(number("time-pos") - 2.5) < 0.2);
    assert(atomic_load(&changes) > 15);
    atomic_store(&operation, 2);
    pthread_join(thread, NULL);
    mpv_terminate_destroy(player);
    printf("{\"software_frames\":%d,\"changing_pictures\":%d,\"context_replacements\":4,\"preserved_audio_position\":true,\"paused_frame_stable\":true,\"seek\":2.5,\"speed\":3,\"advance_in_0_8s\":%.3f}\n",
      atomic_load(&frames), atomic_load(&changes), advance);
}
