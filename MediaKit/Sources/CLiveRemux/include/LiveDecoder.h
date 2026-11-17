#ifndef PILI_LIVE_DECODER_H
#define PILI_LIVE_DECODER_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef int32_t (*PLLiveRead)(void *, uint8_t *, int32_t);
typedef int32_t (*PLLiveCancelled)(void *);
typedef struct {
  int64_t frames, first_us, last_us, audio_packets;
  int32_t width, height, transfer, hardware_copy;
} PLLiveVideoStats;
/* Non-seekable, already-authorized FLV byte source. mode 0 = CPU, mode 1 =
   VideoToolbox copy, mode 2 = packet remux for the system AVKit decoder. required_codec 0=reported codec, 1=AVC, 2=HEVC, 3=AV1,
   4=VP9. An application-private rolling HLS directory is the only writable
   path. No remote URLs. */
int32_t pl_live_decode(void *ctx, PLLiveRead read, PLLiveCancelled interrupted,
                       const char *directory, int32_t mode,
                       int32_t required_codec, int32_t pixels,
                       PLLiveVideoStats *stats, char *error,
                       int32_t error_size);
/* Demux format: 0=FLV, 1=clear fMP4 live fragments, 2=clear MPEG-TS segments.
 */
int32_t pl_live_decode_stream(void *ctx, PLLiveRead read,
                              PLLiveCancelled interrupted,
                              const char *directory, int32_t demux,
                              int32_t mode, int32_t required_codec,
                              int32_t pixels, PLLiveVideoStats *stats,
                              char *error, int32_t error_size);
/* Independently transported authorized audio. INT64_MIN = use encoded media
   clocks; otherwise the time of the first selected audio segment minus that of
   the video segment, in microseconds. */
int32_t pl_live_decode_pair(void *video_ctx, void *audio_ctx, PLLiveRead read,
                            PLLiveCancelled interrupted, int32_t audio_demux,
                            int64_t program_delta, int64_t origin90,
                            const char *directory, int32_t video_demux,
                            int32_t mode, int32_t required_codec,
                            int32_t pixels, PLLiveVideoStats *stats,
                            char *error, int32_t error_size);
#ifdef __cplusplus
}
#endif
#endif
