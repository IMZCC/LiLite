#include "CLiveRemux.h"
#include <libavcodec/codec_id.h>
#include <libavformat/avformat.h>
#include <libavutil/avstring.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

typedef struct { void *ctx; PLReadBytes read; PLInterrupted interrupted; } Input;
static int interrupt_io(void *opaque) {
    Input *input = opaque;
    return input->interrupted && input->interrupted(input->ctx);
}
static int read_io(void *opaque, uint8_t *dst, int length) {
    Input *input = opaque;
    if (interrupt_io(input)) return AVERROR_EXIT;
    int n = input->read(input->ctx, dst, length);
    if (n > length) return AVERROR(EINVAL);
    if (n < 0) return interrupt_io(input) ? AVERROR_EXIT : AVERROR(EIO);
    return n ? n : AVERROR_EOF;
}
static int video_ok(enum AVCodecID c) {
    return c == AV_CODEC_ID_H264 || c == AV_CODEC_ID_HEVC || c == AV_CODEC_ID_AV1;
}
static int audio_ok(enum AVCodecID c) {
    return c == AV_CODEC_ID_AAC || c == AV_CODEC_ID_MP3 || c == AV_CODEC_ID_AC3 ||
           c == AV_CODEC_ID_EAC3 || c == AV_CODEC_ID_OPUS || c == AV_CODEC_ID_FLAC;
}
int32_t pl_live_remux(void *ctx, PLReadBytes read, PLInterrupted interrupted,
                      const char *directory, char *error, int32_t error_size) {
    if (error && error_size > 0) error[0]=0;
    if (!read || !directory || !*directory) return AVERROR(EINVAL);
    Input input = {ctx, read, interrupted};
    AVFormatContext *in = NULL, *out = NULL;
    AVIOContext *io = NULL;
    AVPacket *pkt = NULL;
    AVDictionary *options = NULL;
    int streams[128], video = -1, audio = -1, ready = 0, started = 0;
    int ret = AVERROR(ENOMEM);
    char *playlist = av_asprintf("%s/index.m3u8", directory);
    char *segments = av_asprintf("%s/part%%08d.m4s", directory);
    if (!playlist || !segments) goto cleanup;
    in = avformat_alloc_context();
    if (!in) goto cleanup;
    uint8_t *buf = av_malloc(32 * 1024);
    if (!buf) goto cleanup;
    io = avio_alloc_context(buf,32 * 1024,0,&input,read_io,NULL,NULL);
    if (!io) { av_free(buf); goto cleanup; }
    in->pb=io;
    in->flags |= AVFMT_FLAG_CUSTOM_IO;
    in->interrupt_callback=(AVIOInterruptCB){interrupt_io,&input};
    in->probesize=2 * 1024 * 1024; in->max_analyze_duration=2000000; in->max_streams=128;
    const AVInputFormat *flv = av_find_input_format("flv");
    if (!flv) { ret=AVERROR_DEMUXER_NOT_FOUND; goto cleanup; }
    ret=avformat_open_input(&in,NULL,flv,NULL);
    if (ret<0) goto cleanup;
    ret=avformat_find_stream_info(in,NULL);
    if (ret<0) goto cleanup;
    if (in->nb_streams>128) {ret=AVERROR_INVALIDDATA;goto cleanup;}
    ret=avformat_alloc_output_context2(&out,NULL,"hls",playlist);
    if (ret<0 || !out) { if (ret>=0)ret=AVERROR(ENOMEM);goto cleanup;}
    out->interrupt_callback=(AVIOInterruptCB){interrupt_io,&input};
    out->avoid_negative_ts=AVFMT_AVOID_NEG_TS_MAKE_NON_NEGATIVE;
    for (unsigned i=0;i<128;i++)streams[i]=-1;
    int saw_audio=0, saw_video=0;
    for (unsigned i=0;i<in->nb_streams;i++) {
        AVStream *s=in->streams[i]; enum AVCodecID c=s->codecpar->codec_id;
        if (s->codecpar->codec_type==AVMEDIA_TYPE_AUDIO)saw_audio=1;
        if (s->codecpar->codec_type==AVMEDIA_TYPE_VIDEO)saw_video=1;
        if (s->codecpar->codec_type==AVMEDIA_TYPE_VIDEO && video<0 && video_ok(c)) video=(int)i;
        else if (s->codecpar->codec_type==AVMEDIA_TYPE_AUDIO && audio<0 && audio_ok(c)) audio=(int)i;
        else continue;
        AVStream *d=avformat_new_stream(out,NULL);
        if (!d) {ret=AVERROR(ENOMEM);goto cleanup;}
        streams[i]=d->index;
        ret=avcodec_parameters_copy(d->codecpar,s->codecpar);if(ret<0)goto cleanup;
        d->codecpar->codec_tag=(c==AV_CODEC_ID_HEVC) ? MKTAG('h','v','c','1') : 0;
        d->time_base=s->time_base; d->avg_frame_rate=s->avg_frame_rate;
    }
    if ((video<0 && audio<0) || (saw_video && video<0) || (saw_audio && audio<0)) {ret=AVERROR(ENOSYS);goto cleanup;}
    av_dict_set(&options,"hls_time","2",0);
    av_dict_set(&options,"hls_list_size","6",0);
    av_dict_set(&options,"hls_delete_threshold","2",0);
    av_dict_set(&options,"hls_segment_type","fmp4",0);
    av_dict_set(&options,"hls_fmp4_init_filename","init.mp4",0);
    av_dict_set(&options,"hls_segment_filename",segments,0);
    av_dict_set(&options,"hls_flags","delete_segments+temp_file+independent_segments+program_date_time",0);
    ret=avformat_write_header(out,&options);if(ret<0)goto cleanup;
    started=1;
    pkt=av_packet_alloc(); if(!pkt){ret=AVERROR(ENOMEM);goto cleanup;}
    int64_t gop_bytes=0;
    long double key_time=-1;
    if (video<0) ready=1; /* audio-only broadcasts have no video keyframes */
    while(!interrupt_io(&input) && (ret=av_read_frame(in,pkt))>=0) {
        int n=pkt->stream_index;
        if (video>=0 && n==video) {
            int64_t ts=pkt->dts==AV_NOPTS_VALUE ? pkt->pts:pkt->dts;
            long double now=ts==AV_NOPTS_VALUE ? -1 : (long double)ts*av_q2d(in->streams[n]->time_base);
            if (pkt->flags & AV_PKT_FLAG_KEY) {ready=1; key_time=now;gop_bytes=0;}
            if (ready && key_time>=0 && now-key_time>45) {ret=AVERROR_INVALIDDATA;break;}
        }
        if (ready && video>=0 && n>=0 && n<128 && streams[n]>=0) {
            gop_bytes+=pkt->size;
            if(gop_bytes>128LL*1024*1024) {ret=AVERROR_INVALIDDATA;break;}
        }
        if (ready && n>=0 && n<128 && streams[n]>=0) {
            int dest=streams[n];
            av_packet_rescale_ts(pkt,in->streams[n]->time_base,out->streams[dest]->time_base);
            pkt->stream_index=dest;pkt->pos=-1;
            ret=av_interleaved_write_frame(out,pkt);
        }
        av_packet_unref(pkt);
        if (ret<0)break;
    }
    if (interrupt_io(&input))ret=AVERROR_EXIT;
    else if (ret==AVERROR_EOF)ret=ready ? 0:AVERROR_INVALIDDATA;
    if (started && ret>=0)ret=av_write_trailer(out);
cleanup:
    if (ret<0 && error && error_size>0)av_strerror(ret,error,(size_t)error_size);
    av_dict_free(&options);av_packet_free(&pkt);
    avformat_free_context(out);avformat_close_input(&in);
    if (io)av_freep(&io->buffer);
    avio_context_free(&io);av_free(playlist);av_free(segments);
    return ret;
}
