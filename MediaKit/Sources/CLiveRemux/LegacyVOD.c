#include "CLiveRemux.h"
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <errno.h>
#include <stdio.h>
#include <math.h>

typedef struct { void *ctx; PLInterrupted stopped; } VODInterrupt;
static int vod_stopped(void *opaque) {
    VODInterrupt *state = opaque;
    return state->stopped && state->stopped(state->ctx);
}
/* Legacy on-demand FLV is copied into a seekable movie, without a decoder or encoder.
 * Only the already downloaded private file is opened; demuxed URLs are never followed. */
static int32_t vod_remux(const char *input, const char *output, double beginning, void *ctx,
                         PLInterrupted stopped, char *error, int32_t error_size) {
    if (error && error_size > 0) error[0] = 0;
    if (!input || !output || !*input || !*output) return AVERROR(EINVAL);
    VODInterrupt state = {ctx, stopped};
    AVFormatContext *in = avformat_alloc_context(), *out = NULL;
    AVPacket *packet = NULL;
    AVDictionary *options = NULL;
    int mapping[128], ret = AVERROR(ENOMEM), video = -1, audio = -1;
    if (!in) goto finish;
    in->interrupt_callback = (AVIOInterruptCB){vod_stopped, &state};
    in->max_streams = 128;
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    const AVInputFormat *flv = av_find_input_format("flv");
    if (!flv) { ret = AVERROR_DEMUXER_NOT_FOUND; goto finish; }
    ret = avformat_open_input(&in, input, flv, &options);
    av_dict_free(&options);
    if (ret < 0) goto finish;
    if (vod_stopped(&state)) { ret = AVERROR_EXIT; goto finish; }
    ret = avformat_find_stream_info(in, NULL);
    if (ret < 0) goto finish;
    if (in->nb_streams > 128) { ret = AVERROR_INVALIDDATA; goto finish; }
    ret = avformat_alloc_output_context2(&out, NULL, "mp4", output);
    if (ret < 0 || !out) { if (ret >= 0) ret = AVERROR(ENOMEM); goto finish; }
    out->interrupt_callback = (AVIOInterruptCB){vod_stopped, &state};
    out->avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_NON_NEGATIVE;
    for (unsigned n = 0; n < 128; ++n) mapping[n] = -1;
    for (unsigned n = 0; n < in->nb_streams; ++n) {
        AVStream *src = in->streams[n];
        if (src->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && video < 0) video = n;
        else if (src->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && audio < 0) audio = n;
        else continue;
        AVStream *dst = avformat_new_stream(out, NULL);
        if (!dst) { ret = AVERROR(ENOMEM); goto finish; }
        mapping[n] = dst->index;
        ret = avcodec_parameters_copy(dst->codecpar, src->codecpar);
        if (ret < 0) goto finish;
        dst->codecpar->codec_tag = src->codecpar->codec_id == AV_CODEC_ID_HEVC ? MKTAG('h','v','c','1') : 0;
        dst->time_base = src->time_base;
        dst->avg_frame_rate = src->avg_frame_rate;
    }
    if (video < 0) { ret = AVERROR_INVALIDDATA; goto finish; }
    ret = avio_open2(&out->pb, output, AVIO_FLAG_WRITE, &out->interrupt_callback, NULL);
    if (ret < 0) goto finish;
    av_dict_set(&options, "movflags", "+faststart", 0);
    av_dict_set(&options, "video_track_timescale", "90000", 0);
    ret = avformat_write_header(out, &options);
    av_dict_free(&options);
    if (ret < 0) goto finish;
    packet = av_packet_alloc();
    if (!packet) { ret = AVERROR(ENOMEM); goto finish; }
    while (!vod_stopped(&state) && (ret = av_read_frame(in, packet)) >= 0) {
        int n = packet->stream_index;
        if (n >= 0 && n < 128 && mapping[n] >= 0) {
            if (beginning >= 0) {
                int64_t base = av_rescale_q((int64_t)llround(beginning * AV_TIME_BASE), AV_TIME_BASE_Q, in->streams[n]->time_base);
                int64_t stamp = packet->dts == AV_NOPTS_VALUE ? packet->pts : packet->dts;
                if (stamp != AV_NOPTS_VALUE && stamp < base) { av_packet_unref(packet); continue; }
                if (packet->dts != AV_NOPTS_VALUE) packet->dts -= base;
                if (packet->pts != AV_NOPTS_VALUE) packet->pts -= base;
            }
            av_packet_rescale_ts(packet, in->streams[n]->time_base, out->streams[mapping[n]]->time_base);
            packet->stream_index = mapping[n];
            packet->pos = -1;
            ret = av_interleaved_write_frame(out, packet);
        }
        av_packet_unref(packet);
        if (ret < 0) break;
    }
    if (vod_stopped(&state)) ret = AVERROR_EXIT;
    else if (ret == AVERROR_EOF) ret = av_write_trailer(out);
finish:
    if (ret < 0 && error && error_size > 0) av_strerror(ret, error, (size_t)error_size);
    av_dict_free(&options);
    av_packet_free(&packet);
    if (out && out->pb) avio_closep(&out->pb);
    avformat_free_context(out);
    avformat_close_input(&in);
    if (ret < 0) remove(output);
    return ret;
}
int32_t pl_vod_remux_file(const char *input, const char *output, void *ctx,
                         PLInterrupted stopped, char *error, int32_t error_size) {
    return vod_remux(input, output, -1, ctx, stopped, error, error_size);
}
int32_t pl_vod_remux_window(const char *input, const char *output, double beginning,
                           void *ctx, PLInterrupted stopped, char *error, int32_t error_size) {
    if (!isfinite(beginning) || beginning < 0 || beginning > 30 * 86400) return AVERROR(EINVAL);
    return vod_remux(input, output, beginning, ctx, stopped, error, error_size);
}
