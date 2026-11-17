#ifndef PILI_LIVE_REMUX_H
#define PILI_LIVE_REMUX_H
#include <stdint.h>
#include "SoftVideo.h"
#include "AudioSegment.h"
#include "TimingRing.h"
#include "AudioGain.h"
#include "LiveDecoder.h"
#include "PiliASS.h"
#ifdef __cplusplus
extern "C" {
#endif
/* read returns bytes copied, zero for EOF, negative for cancellation or a transport error.
 * Calls are synchronous on the caller's worker thread. The AVIO layer never opens a network URL. */
typedef int32_t (*PLReadBytes)(void *ctx, uint8_t *dst, int32_t length);
typedef int32_t (*PLInterrupted)(void *ctx);
int32_t pl_live_remux(void *ctx, PLReadBytes read, PLInterrupted interrupted,
                      const char *directory, char *error, int32_t error_size);
int32_t pl_vod_remux_file(const char *input, const char *output, void *ctx,
                         PLInterrupted interrupted, char *error, int32_t error_size);
int32_t pl_vod_remux_window(const char *input, const char *output, double beginning,
                           void *ctx, PLInterrupted interrupted, char *error, int32_t error_size);
typedef struct {
    double duration, fps;
    int32_t count, audio;
    double *times;
    int64_t *positions;
} PLVODIndex;
int32_t pl_vod_flv_index(const uint8_t *prefix, int32_t length, int64_t total,
                         PLVODIndex *index);
void pl_vod_free_index(PLVODIndex *index);
#ifdef __cplusplus
}
#endif
#endif
