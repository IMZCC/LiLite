#include "CLiveRemux.h"
#include <libavformat/avformat.h>
#include <libavutil/mem.h>
#include <libavutil/error.h>
#include <math.h>
#include <string.h>
#include <errno.h>

typedef struct { const uint8_t *bytes; int32_t length; int64_t at, total; } Prefix;
static int prefix_read(void *raw, uint8_t *out, int requested) {
    Prefix *source = raw;
    if (source->at >= source->length) return AVERROR_EOF;
    int n = (int)FFMIN(requested, source->length - source->at);
    memcpy(out, source->bytes + source->at, n); source->at += n; return n;
}
static int64_t prefix_seek(void *raw, int64_t offset, int whence) {
    Prefix *source = raw;
    if (whence == AVSEEK_SIZE) return source->total;
    whence &= ~AVSEEK_FORCE;
    if (whence == SEEK_CUR) offset += source->at;
    else if (whence == SEEK_END) offset += source->total;
    else if (whence != SEEK_SET) return AVERROR(EINVAL);
    if (offset < 0 || offset > source->total) return AVERROR(EINVAL);
    source->at = offset; return offset;
}
void pl_vod_free_index(PLVODIndex *index) {
    if (!index) return;
    av_freep(&index->times); av_freep(&index->positions); index->count = 0;
}
/* FLV's onMetaData keyframe table is parsed by the pinned production demuxer. Payload beyond
 * the bounded prefix is deliberately unavailable, so index discovery cannot download the movie. */
int32_t pl_vod_flv_index(const uint8_t *bytes, int32_t length, int64_t total, PLVODIndex *index) {
    if (!index || !bytes || length < 16 || length > 4 * 1024 * 1024 || total < length) return AVERROR(EINVAL);
    memset(index, 0, sizeof(*index));
    Prefix source = {bytes, length, 0, total};
    AVFormatContext *in = avformat_alloc_context();
    AVIOContext *io = NULL;
    int ret = AVERROR(ENOMEM);
    if (!in) goto finish;
    uint8_t *buffer = av_malloc(32768);
    if (!buffer) goto finish;
    io = avio_alloc_context(buffer, 32768, 0, &source, prefix_read, NULL, prefix_seek);
    if (!io) { av_free(buffer); goto finish; }
    in->pb = io; in->flags |= AVFMT_FLAG_CUSTOM_IO;
    in->probesize = length; in->max_analyze_duration = AV_TIME_BASE;
    in->max_streams = 128;
    const AVInputFormat *format = av_find_input_format("flv");
    if (!format) { ret = AVERROR_DEMUXER_NOT_FOUND; goto finish; }
    ret = avformat_open_input(&in, NULL, format, NULL);
    if (ret < 0) goto finish;
    ret = avformat_find_stream_info(in, NULL);
    if (ret < 0) goto finish;
    int video = av_find_best_stream(in, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (video < 0) { ret = video; goto finish; }
    AVStream *stream = in->streams[video];
    int count = avformat_index_get_entries_count(stream);
    if (count < 2 || count > 131072 || in->duration <= 0 || in->duration == AV_NOPTS_VALUE) { ret = AVERROR(ENOSYS); goto finish; }
    index->duration = (double)in->duration / AV_TIME_BASE;
    index->fps = av_q2d(stream->avg_frame_rate);
    index->audio = av_find_best_stream(in, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0) >= 0;
    index->times = av_malloc_array(count, sizeof(double));
    index->positions = av_malloc_array(count, sizeof(int64_t));
    if (!index->times || !index->positions) { ret = AVERROR(ENOMEM); goto finish; }
    for (int n = 0; n < count; ++n) {
        const AVIndexEntry *entry = avformat_index_get_entry(stream, n);
        if (!(entry->flags & AVINDEX_KEYFRAME)) continue;
        double seconds = entry->timestamp * av_q2d(stream->time_base);
        if (!isfinite(seconds) || seconds < 0 || seconds >= index->duration || entry->pos < 13 || entry->pos >= total) { ret = AVERROR_INVALIDDATA; goto finish; }
        int previous = index->count - 1;
        /* A demuxed packet can refine a metadata timestamp rounded to milliseconds, while
         * retaining the identical byte position. It is one keyframe, not two media intervals. */
        if (previous >= 0 && entry->pos == index->positions[previous] &&
            fabs(seconds - index->times[previous]) <= FFMAX(0.002, 2 * av_q2d(stream->time_base))) {
            index->times[previous] = FFMAX(seconds, index->times[previous]);
            continue;
        }
        if (previous >= 0 && (seconds <= index->times[previous] || entry->pos <= index->positions[previous])) { ret = AVERROR_INVALIDDATA; goto finish; }
        index->times[index->count] = seconds; index->positions[index->count++] = entry->pos;
    }
    if (index->count < 2 || index->times[0] > 1 || index->positions[0] > 4 * 1024 * 1024) { ret = AVERROR(ENOSYS); goto finish; }
    double gap = (index->times[index->count - 1] - index->times[0]) / (index->count - 1);
    if (index->times[index->count - 1] < index->duration - FFMAX(2.0, gap * 2)) { ret = AVERROR(ENOSYS); goto finish; }
    ret = 0;
finish:
    avformat_close_input(&in);
    if (io) av_freep(&io->buffer);
    avio_context_free(&io);
    if (ret < 0) pl_vod_free_index(index);
    return ret;
}
