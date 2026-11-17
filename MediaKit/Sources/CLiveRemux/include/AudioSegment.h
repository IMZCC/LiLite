#ifndef PILI_AUDIO_SEGMENT_H
#define PILI_AUDIO_SEGMENT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef int32_t (*PLAudioStop)(void *ctx);
/* Only reads supplied fMP4 bytes. filter is a bounded numeric chain of
 * loudnorm, dynaudnorm and volume; file, expression, network and other filter
 * options are rejected. */
int32_t pl_audio_segment(const uint8_t *init, int32_t init_size,
                         const uint8_t *media, int32_t media_size,
                         int64_t media_offset, int64_t selected_first,
                         int64_t selected_last, const char *filter, void *ctx,
                         PLAudioStop stop, uint8_t **result, int32_t *size,
                         char *error, int32_t error_size);
void pl_free_audio(void *p);
typedef struct {
  int32_t rate, channels, frames, layout[8];
  int64_t first_sample;
  double first_video_seconds; /* NAN for a separate audio-only track */
} PLTimingPCM;
/* Same authorized fragment and effects as the HLS rendition; interleaved signed
 * native-endian PCM32 for the device output clock. No container, URL or
 * persistent file is created. */
int32_t pl_audio_pcm(const uint8_t *init, int32_t init_size,
                     const uint8_t *media, int32_t media_size, int64_t offset,
                     int64_t first, int64_t last, const char *filter, void *ctx,
                     PLAudioStop cancel, PLTimingPCM *description,
                     uint8_t **result, int32_t *size, char *error,
                     int32_t error_size);
#ifdef __cplusplus
}
#endif
#endif
