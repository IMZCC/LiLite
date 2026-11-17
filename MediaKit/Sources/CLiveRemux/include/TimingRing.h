#ifndef PL_TIMING_RING_H
#define PL_TIMING_RING_H
#include <stdint.h>
#ifdef __APPLE__
#include <CoreAudioTypes/CoreAudioTypes.h>
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef struct PLTimingRing PLTimingRing;
PLTimingRing *pl_clock_ring(int32_t rate, int32_t channels, int32_t capacity,
                            int64_t first_frame);
void pl_clock_destroy(PLTimingRing *);
int32_t pl_clock_write(PLTimingRing *, const void *pcm32, int32_t frames);
int32_t pl_clock_available(PLTimingRing *);
int32_t pl_clock_buffered(PLTimingRing *);
void pl_clock_tempo(PLTimingRing *, double tempo);
void pl_clock_control(PLTimingRing *, double ratio, int32_t block);
int32_t pl_clock_render(PLTimingRing *, int32_t frames, float *const *planes,
                        double host);
double pl_clock_time(PLTimingRing *, double host, double audible_rate,
                     double latency);
#ifdef __APPLE__
AudioChannelLayout *pl_clock_audio_layout(const int32_t *ids, int32_t channels);
void pl_clock_free_layout(AudioChannelLayout *);
int32_t pl_clock_render_abl(PLTimingRing *, int32_t frames,
                            AudioBufferList *out, double host);
#endif
#ifdef __cplusplus
}
#endif
#endif
