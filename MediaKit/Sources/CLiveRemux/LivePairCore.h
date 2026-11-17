#ifndef PILI_LIVE_PAIR_CORE_H
#define PILI_LIVE_PAIR_CORE_H
#include "LiveDecoder.h"
#include <libavformat/avformat.h>
typedef struct PLLivePair PLLivePair;
/* INT64_MIN denotes no programme date anchor. Both stream PTS then already
 * share the HLS clock. */
PLLivePair *pl_pair_new(void *audio_ctx, PLLiveRead read, PLLiveCancelled stop,
                        int source, int64_t program_delta, int64_t origin90);
int pl_pair_open(PLLivePair *p, AVFormatContext *video, int video_stream);
AVStream *pl_pair_audio(PLLivePair *p);
int pl_pair_next(PLLivePair *p, AVPacket *out);
void pl_pair_drop(PLLivePair *p);
#endif
