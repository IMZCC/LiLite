#ifndef PILI_SOFT_VIDEO_H
#define PILI_SOFT_VIDEO_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Memory-only clear DASH video. UID/cookies/URLs never enter the codec layer.
   init describes the complete initialization segment, media begins at its resource byte offset.
   target >= media_offset permits decoding earlier samples for a non-independent segment.
   For each displayed frame an optional caller receives packed Y, U and V rows (only width bytes
   are active per row for 8-bit YUV420P); for 10-bit HDR the final format tag is 1 and the first
   two planes are little-endian P010, with two bytes per luma and four per chroma pair.
   Frame timestamps are container presentation times in microseconds. */
typedef int32_t (*PLFrameSink)(void *,int32_t,int32_t,int64_t,const uint8_t*,int32_t,const uint8_t*,int32_t,const uint8_t*,int32_t,int32_t);
typedef int32_t (*PLDecodeCancelled)(void *);
typedef struct { int32_t frames,width,height,transfer; int64_t first_us,last_us; } PLDecodedVideo;
enum { PL_SOFTWARE=0, PL_VT_COPY=1, PL_NEEDS_KEYFRAME=-1178995557 };
int32_t pl_decode_video(const uint8_t *init,int32_t init_size,const uint8_t *media,int32_t media_size,
  int64_t media_offset,int64_t target_offset,int32_t mode,int32_t pixel_limit,int32_t encode,
  void *opaque,PLDecodeCancelled cancel,PLFrameSink sink,PLDecodedVideo *stats,
  uint8_t **output,int32_t *output_size,char *error,int32_t error_size);
void pl_free_video(uint8_t *data);
#ifdef __cplusplus
}
#endif
#endif
