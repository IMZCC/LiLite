#include "LiveDecoder.h"
#include "LivePairCore.h"
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavutil/avstring.h>
#include <libavutil/hwcontext.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#define MB (1024 * 1024)
#define BAD AVERROR_INVALIDDATA
#define TRY(x)                                                                 \
  do {                                                                         \
    int r_ = (x);                                                              \
    if (r_ < 0)                                                                \
      return r_;                                                               \
  } while (0)
typedef struct {
  PLLivePair *pair;
  int audio_demux;
  void *ctx;
  PLLiveRead pull;
  PLLiveCancelled stop;
  const char *folder;
  int demux, mode, codec, limit, started, hdr, v, a;
  PLLiveVideoStats *stats;
  AVFormatContext *input, *output;
  AVIOContext *io;
  AVStream *is, *os, *oa;
  AVCodecContext *dec, *enc;
  AVBufferRef *hw;
  struct SwsContext *scale;
  AVFrame *image, *copied, *color;
  AVBSFContext *aac;
  AVPacket *front[256];
  int front_read, front_count;
  AVPacket *pkt, *encoded, *waiting[256];
  int count, wait_bytes;
  int64_t last_key_us, last_clock;
} Live;
static int halted(void *opaque) {
  Live *l = opaque;
  return l->stop && l->stop(l->ctx);
}
static int feed(void *opaque, uint8_t *dst, int length) {
  Live *l = opaque;
  if (halted(l))
    return AVERROR_EXIT;
  int n = l->pull(l->ctx, dst, length);
  if (n > length)
    return BAD;
  return n > 0   ? n
         : n < 0 ? halted(l) ? AVERROR_EXIT : AVERROR(EIO)
                 : AVERROR_EOF;
}
static int no_external(AVFormatContext *s, AVIOContext **io, const char *path,
                       int flags, AVDictionary **opts) {
  (void)s;
  (void)io;
  (void)path;
  (void)flags;
  (void)opts;
  return AVERROR(EPERM);
}
static int encrypted(const AVCodecParameters *p) {
  return p->codec_tag == MKTAG('e', 'n', 'c', 'v') ||
         p->codec_tag == MKTAG('e', 'n', 'c', 'a') ||
         av_packet_side_data_get(p->coded_side_data, p->nb_coded_side_data,
                                 AV_PKT_DATA_ENCRYPTION_INIT_INFO) != NULL;
}
static enum AVPixelFormat choose_hw(AVCodecContext *c,
                                    const enum AVPixelFormat *pix) {
  (void)c;
  while (*pix != AV_PIX_FMT_NONE) {
    if (*pix == AV_PIX_FMT_VIDEOTOOLBOX)
      return *pix;
    pix++;
  }
  return AV_PIX_FMT_NONE;
}
static int can_audio(enum AVCodecID id) {
  return id == AV_CODEC_ID_AAC || id == AV_CODEC_ID_MP3 ||
         id == AV_CODEC_ID_AC3 || id == AV_CODEC_ID_EAC3 ||
         id == AV_CODEC_ID_OPUS || id == AV_CODEC_ID_FLAC;
}
static AVStream *source_audio(Live *l) {
  return l->pair ? pl_pair_audio(l->pair) : l->input->streams[l->a];
}
static int raw_packet(Live *l, AVPacket *p) {
  return l->pair ? pl_pair_next(l->pair, p) : av_read_frame(l->input, p);
}
static int write_audio(Live *l, AVPacket *p) {
  av_packet_rescale_ts(p, source_audio(l)->time_base, l->oa->time_base);
  p->stream_index = l->oa->index;
  p->pos = -1;
  int ret = av_interleaved_write_frame(l->output, p);
  if (ret >= 0)
    l->stats->audio_packets++;
  return ret;
}
static int next_packet(Live *l, AVPacket *p) {
  if (l->front_read < l->front_count) {
    AVPacket **v = &l->front[l->front_read++];
    av_packet_move_ref(p, *v);
    av_packet_free(v);
    return 0;
  }
  return raw_packet(l, p);
}
static int audio_packet(Live *l, AVPacket *p) {
  if (!l->aac)
    return write_audio(l, p);
  TRY(av_bsf_send_packet(l->aac, p));
  int r;
  while ((r = av_bsf_receive_packet(l->aac, p)) >= 0) {
    TRY(write_audio(l, p));
    av_packet_unref(p);
  }
  return r == AVERROR(EAGAIN) || r == AVERROR_EOF ? 0 : r;
}
static int aac_header(Live *l) {
  if (((l->pair ? l->audio_demux : l->demux) != 2 &&
       (l->pair ? l->audio_demux : l->demux) != 3) ||
      l->a < 0 || l->oa->codecpar->codec_id != AV_CODEC_ID_AAC)
    return 0;
  // ADTS framing is not valid inside fMP4. Probe the first authorised AAC
  // packet before emitting the initialization box, replay every packet read
  // during that probe, and keep AAC compressed.
  int bytes = 0;
  while (l->front_count < 256 && !halted(l)) {
    AVPacket *p = av_packet_alloc();
    if (!p)
      return AVERROR(ENOMEM);
    l->front[l->front_count++] = p;
    TRY(raw_packet(l, p));
    if (p->size <= 0 || p->size > 8 * MB - bytes ||
        av_packet_get_side_data(p, AV_PKT_DATA_ENCRYPTION_INFO, NULL))
      return BAD;
    bytes += p->size;
    if (p->stream_index != l->a)
      continue;
    if (p->size < 7 || p->data[0] != 0xff || (p->data[1] & 0xf6) != 0xf0)
      return l->oa->codecpar->extradata_size > 0 ? 0 : BAD;
    const AVBitStreamFilter *filter = av_bsf_get_by_name("aac_adtstoasc");
    if (!filter)
      return AVERROR_BSF_NOT_FOUND;
    TRY(av_bsf_alloc(filter, &l->aac));
    TRY(avcodec_parameters_copy(l->aac->par_in, l->oa->codecpar));
    l->aac->time_base_in = source_audio(l)->time_base;
    TRY(av_bsf_init(l->aac));
    AVPacket *test = av_packet_clone(p);
    if (!test)
      return AVERROR(ENOMEM);
    int ret = av_bsf_send_packet(l->aac, test);
    if (ret >= 0)
      ret = av_bsf_receive_packet(l->aac, test);
    if (ret >= 0) {
      size_t size = 0;
      uint8_t *data =
          av_packet_get_side_data(test, AV_PKT_DATA_NEW_EXTRADATA, &size);
      if (!size || size > 65536 || !data)
        ret = BAD;
      else {
        uint8_t *owned = av_mallocz(size + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!owned)
          ret = AVERROR(ENOMEM);
        else {
          memcpy(owned, data, size);
          av_freep(&l->oa->codecpar->extradata);
          l->oa->codecpar->extradata = owned;
          l->oa->codecpar->extradata_size = (int)size;
        }
      }
    }
    av_packet_free(&test);
    return ret;
  }
  return halted(l) ? AVERROR_EXIT : BAD;
}
static int save_side(AVCodecParameters *dest, const AVCodecParameters *source,
                     AVFrame *f, enum AVFrameSideDataType ftype,
                     enum AVPacketSideDataType ptype) {
  const AVFrameSideData *df = av_frame_get_side_data(f, ftype);
  const AVPacketSideData *dp = av_packet_side_data_get(
      source->coded_side_data, source->nb_coded_side_data, ptype);
  const uint8_t *data = df ? df->data : dp ? dp->data : NULL;
  size_t n = df ? df->size : dp ? dp->size : 0;
  if (!data || !n)
    return 0;
  if (n > 64 * 1024)
    return BAD;
  AVPacketSideData *copy = av_packet_side_data_new(
      &dest->coded_side_data, &dest->nb_coded_side_data, ptype, n, 0);
  if (!copy)
    return AVERROR(ENOMEM);
  memcpy(copy->data, data, n);
  return 0;
}
static int publish_header(Live *l) {
  AVDictionary *options = NULL;
  int ret;
  char *part = av_asprintf("%s/part%%08d.m4s", l->folder);
  if (!part)
    return AVERROR(ENOMEM);
  av_dict_set(&options, "hls_time", "2", 0);
  av_dict_set(&options, "hls_list_size", "6", 0);
  av_dict_set(&options, "hls_delete_threshold", "2", 0);
  av_dict_set(&options, "hls_segment_type", "fmp4", 0);
  av_dict_set(&options, "hls_fmp4_init_filename", "init.mp4", 0);
  av_dict_set(&options, "hls_segment_filename", part, 0);
  av_free(part);
  av_dict_set(
      &options, "hls_flags",
      "delete_segments+temp_file+independent_segments+program_date_time", 0);
  ret = avformat_write_header(l->output, &options);
  av_dict_free(&options);
  TRY(ret);
  l->started = 1;
  return 0;
}
static int setup_output(Live *l, AVFrame *f) {
  AVCodecParameters *src = l->is->codecpar;
  if ((f->width & 1) || (f->height & 1))
    return BAD;
  l->hdr = f->color_trc == AVCOL_TRC_SMPTE2084 ||
           f->color_trc == AVCOL_TRC_ARIB_STD_B67;
  if (av_packet_side_data_get(src->coded_side_data, src->nb_coded_side_data,
                              AV_PKT_DATA_DOVI_CONF) ||
      av_frame_get_side_data(f, AV_FRAME_DATA_DOVI_METADATA) ||
      (av_frame_get_side_data(f, AV_FRAME_DATA_DYNAMIC_HDR_VIVID) ||
       av_frame_get_side_data(f, AV_FRAME_DATA_DYNAMIC_HDR_PLUS)))
    return AVERROR(ENOSYS);
#if defined(__APPLE__) && TARGET_OS_IOS
  const AVCodec *codec = avcodec_find_encoder_by_name(
      l->hdr ? "hevc_videotoolbox" : "h264_videotoolbox");
#else
  if (l->hdr)
    return AVERROR(
        ENOSYS); // Only the iOS encoder is expected to produce ten-bit HDR.
  const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_MPEG2VIDEO);
#endif
  if (!codec)
    return AVERROR_ENCODER_NOT_FOUND;
  l->enc = avcodec_alloc_context3(codec);
  if (!l->enc)
    return AVERROR(ENOMEM);
  AVCodecContext *e = l->enc;
  AVRational fps = av_guess_frame_rate(l->input, l->is, f);
  double hz = av_q2d(fps);
  if (!isfinite(hz) || hz < 1 || hz > 120) {
    fps = (AVRational){30, 1};
    hz = 30.;
  }
  e->width = f->width;
  e->height = f->height;
  e->pix_fmt = l->hdr ? AV_PIX_FMT_P010LE : AV_PIX_FMT_YUV420P;
  e->color_range = f->color_range;
  e->color_trc = f->color_trc;
  e->color_primaries = f->color_primaries;
  e->colorspace = f->colorspace;
  e->sample_aspect_ratio = f->sample_aspect_ratio;
  e->framerate = fps;
  e->gop_size = FFMAX(1, (int)round(hz * 2.0));
  e->max_b_frames = 0;
  e->thread_count = 1;
  e->bit_rate =
      FFMAX(450000, FFMIN(35000000, (int64_t)e->width * e->height * 6));
  e->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
#if defined(__APPLE__) && TARGET_OS_IOS
  e->time_base = (AVRational){1, 90000};
  av_opt_set(e->priv_data, "realtime", "1", 0);
  if (l->hdr)
    e->profile = AV_PROFILE_HEVC_MAIN_10;
#else
  e->time_base = av_inv_q(fps);
#endif
  TRY(avcodec_open2(e, codec, NULL));
  TRY(avcodec_parameters_from_context(l->os->codecpar, e));
  l->os->time_base = (AVRational){1, 90000};
  l->os->avg_frame_rate = fps;
  if (l->hdr) {
    l->os->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
    TRY(save_side(l->os->codecpar, src, f,
                  AV_FRAME_DATA_MASTERING_DISPLAY_METADATA,
                  AV_PKT_DATA_MASTERING_DISPLAY_METADATA));
    TRY(save_side(l->os->codecpar, src, f, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL,
                  AV_PKT_DATA_CONTENT_LIGHT_LEVEL));
  }
  TRY(publish_header(l));
  for (int i = 0; i < l->count; i++) {
    TRY(audio_packet(l, l->waiting[i]));
    av_packet_free(&l->waiting[i]);
  }
  l->count = l->wait_bytes = 0;
  l->color = av_frame_alloc();
  if (!l->color)
    return AVERROR(ENOMEM);
  l->color->width = e->width;
  l->color->height = e->height;
  l->color->format = e->pix_fmt;
  l->color->sample_aspect_ratio = e->sample_aspect_ratio;
  l->color->color_range = e->color_range;
  l->color->color_trc = e->color_trc;
  l->color->color_primaries = e->color_primaries;
  l->color->colorspace = e->colorspace;
  return av_frame_get_buffer(l->color, 32);
}
static int encode(Live *l, AVFrame *f) {
  TRY(avcodec_send_frame(l->enc, f));
  int ret;
  while ((ret = avcodec_receive_packet(l->enc, l->encoded)) >= 0) {
    if (halted(l))
      return AVERROR_EXIT;
    if (l->encoded->pts == AV_NOPTS_VALUE)
      return BAD;
    l->encoded->dts = l->encoded->pts;
    av_packet_rescale_ts(l->encoded, l->enc->time_base, l->os->time_base);
    l->encoded->stream_index = l->os->index;
    l->encoded->pos = -1;
    ret = av_interleaved_write_frame(l->output, l->encoded);
    av_packet_unref(l->encoded);
    TRY(ret);
  }
  return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}
static int picture(Live *l, AVFrame *f) {
  if (halted(l))
    return AVERROR_EXIT;
  int64_t pts = f->best_effort_timestamp;
  if (pts == AV_NOPTS_VALUE)
    pts = f->pts;
  if (pts == AV_NOPTS_VALUE || f->width <= 0 || f->height <= 0 ||
      (int64_t)f->width * f->height > l->limit ||
      (f->flags & AV_FRAME_FLAG_CORRUPT) || f->decode_error_flags)
    return BAD;
  if (l->mode) {
    if (f->format != AV_PIX_FMT_VIDEOTOOLBOX)
      return AVERROR(ENOSYS);
    av_frame_unref(l->copied);
    TRY(av_hwframe_transfer_data(l->copied, f, 0));
    TRY(av_frame_copy_props(l->copied, f));
    f = l->copied;
    l->stats->hardware_copy = 1;
  }
  if (av_frame_get_side_data(f, AV_FRAME_DATA_DOVI_METADATA) ||
      (av_frame_get_side_data(f, AV_FRAME_DATA_DYNAMIC_HDR_VIVID) ||
       av_frame_get_side_data(f, AV_FRAME_DATA_DYNAMIC_HDR_PLUS)))
    return AVERROR(ENOSYS);
  if (!l->started)
    TRY(setup_output(l, f));
  int hdr = f->color_trc == AVCOL_TRC_SMPTE2084 ||
            f->color_trc == AVCOL_TRC_ARIB_STD_B67;
  if (hdr != l->hdr || f->width != l->enc->width ||
      f->height != l->enc->height || f->color_trc != l->enc->color_trc)
    return BAD;
  int64_t us = av_rescale_q(pts, l->is->time_base, AV_TIME_BASE_Q);
  if (l->stats->frames &&
      (us <= l->stats->last_us || us - l->stats->last_us > 45LL * 1000000))
    return BAD;
  AVFrame *c = l->color;
  TRY(av_frame_make_writable(c));
  l->scale = sws_getCachedContext(l->scale, f->width, f->height, f->format,
                                  c->width, c->height, c->format, SWS_BILINEAR,
                                  NULL, NULL, NULL);
  if (!l->scale)
    return AVERROR(ENOMEM);
  if (sws_scale(l->scale, (const uint8_t *const *)f->data, f->linesize, 0,
                f->height, c->data, c->linesize) != c->height)
    return BAD;
  c->pts = av_rescale_q(pts, l->is->time_base, l->enc->time_base);
  if (l->stats->frames && c->pts <= l->last_clock)
    return BAD;
  l->last_clock = c->pts;
  c->duration =
      FFMAX(1, av_rescale_q(f->duration, l->is->time_base, l->enc->time_base));
  int key = !l->stats->frames || us - l->last_key_us >= 2000000;
  c->pict_type = key ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;
  if (key)
    l->last_key_us = us;
  TRY(encode(l, c));
  if (!l->stats->frames) {
    l->stats->first_us = us;
    l->stats->width = c->width;
    l->stats->height = c->height;
    l->stats->transfer = f->color_trc;
  }
  l->stats->last_us = us;
  l->stats->frames++;
  return 0;
}
static int decode(Live *l, const AVPacket *packet) {
  TRY(avcodec_send_packet(l->dec, packet));
  int ret;
  while ((ret = avcodec_receive_frame(l->dec, l->image)) >= 0) {
    ret = picture(l, l->image);
    av_frame_unref(l->image);
    TRY(ret);
  }
  return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}
static int create_output(Live *l) {
  char *file = av_asprintf("%s/index.m3u8", l->folder);
  if (!file)
    return AVERROR(ENOMEM);
  int ret = avformat_alloc_output_context2(&l->output, NULL, "hls", file);
  av_free(file);
  TRY(ret);
  l->output->interrupt_callback = (AVIOInterruptCB){halted, l};
  l->output->avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_NON_NEGATIVE;
  l->output->max_interleave_delta = 2 * 1000000;
  return 0;
}
static int add_audio(Live *l) {
  if (l->a >= 0) {
    AVStream *in = source_audio(l);
    l->oa = avformat_new_stream(l->output, NULL);
    if (!l->oa)
      return AVERROR(ENOMEM);
    TRY(avcodec_parameters_copy(l->oa->codecpar, in->codecpar));
    l->oa->codecpar->codec_tag = 0;
    l->oa->time_base = in->time_base;
  }
  return 0;
}
static int radio(Live *l) {
  if (l->a < 0)
    return AVERROR_STREAM_NOT_FOUND;
  TRY(create_output(l));
  TRY(add_audio(l));
  TRY(aac_header(l));
  TRY(publish_header(l));
  l->pkt = av_packet_alloc();
  if (!l->pkt)
    return AVERROR(ENOMEM);
  int ret;
  while (!halted(l) && (ret = next_packet(l, l->pkt)) >= 0) {
    if (l->pkt->size < 0 || l->pkt->size > 8 * MB ||
        av_packet_get_side_data(l->pkt, AV_PKT_DATA_ENCRYPTION_INFO, NULL))
      return BAD;
    if (l->pkt->stream_index == l->a)
      TRY(audio_packet(l, l->pkt));
    av_packet_unref(l->pkt);
  }
  if (halted(l))
    return AVERROR_EXIT;
  if (ret != AVERROR_EOF)
    return ret;
  return l->stats->audio_packets ? av_write_trailer(l->output) : BAD;
}
// A clockable clear HLS rendition for AVKit's original decoder. Both elementary
// streams remain compressed; the device's supported codec/HDR selection is
// unchanged.
static int packet_copy(Live *l) {
  TRY(create_output(l));
  l->os = avformat_new_stream(l->output, NULL);
  if (!l->os)
    return AVERROR(ENOMEM);
  TRY(avcodec_parameters_copy(l->os->codecpar, l->is->codecpar));
  l->os->codecpar->codec_tag = l->os->codecpar->codec_id == AV_CODEC_ID_HEVC
                                   ? MKTAG('h', 'v', 'c', '1')
                                   : 0;
  l->os->time_base = l->is->time_base;
  l->os->avg_frame_rate = l->is->avg_frame_rate;
  l->os->sample_aspect_ratio = l->is->sample_aspect_ratio;
  TRY(add_audio(l));
  TRY(aac_header(l));
  TRY(publish_header(l));
  l->pkt = av_packet_alloc();
  if (!l->pkt)
    return AVERROR(ENOMEM);
  int ready = 0, ret = 0;
  int64_t bytes = 0;
  while (!halted(l) && (ret = next_packet(l, l->pkt)) >= 0) {
    AVPacket *p = l->pkt;
    if (p->size <= 0 || p->size > 32 * MB ||
        av_packet_get_side_data(p, AV_PKT_DATA_ENCRYPTION_INFO, NULL))
      return BAD;
    if (p->stream_index == l->v && (p->flags & AV_PKT_FLAG_KEY)) {
      ready = 1;
      bytes = 0;
    }
    if ((bytes += p->size) > (ready ? 128 : 32) * MB)
      return BAD;
    if (ready && p->stream_index == l->v) {
      if (p->pts == AV_NOPTS_VALUE || p->dts == AV_NOPTS_VALUE)
        return BAD;
      int64_t stamp = av_rescale_q(p->pts, l->is->time_base, AV_TIME_BASE_Q);
      if (!l->stats->frames)
        l->stats->first_us = stamp;
      l->stats->last_us = stamp;
      l->stats->frames++;
      av_packet_rescale_ts(p, l->is->time_base, l->os->time_base);
      p->stream_index = l->os->index;
      p->pos = -1;
      TRY(av_interleaved_write_frame(l->output, p));
    } else if (p->stream_index == l->a) {
      // LiveHLSFeed starts at a complete segment with independent pictures.
      // Keep original audio that leads its first keyframe; never separately
      // rebase the elementary streams.
      TRY(audio_packet(l, p));
    }
    av_packet_unref(p);
  }
  if (halted(l))
    return AVERROR_EXIT;
  if (ret != AVERROR_EOF)
    return ret;
  return l->stats->frames ? av_write_trailer(l->output) : BAD;
}
static int run(Live *l) {
  uint8_t *bytes = av_malloc(32768);
  if (!bytes)
    return AVERROR(ENOMEM);
  l->io = avio_alloc_context(bytes, 32768, 0, l, feed, NULL, NULL);
  if (!l->io) {
    av_free(bytes);
    return AVERROR(ENOMEM);
  }
  l->input = avformat_alloc_context();
  if (!l->input)
    return AVERROR(ENOMEM);
  l->input->flags |= AVFMT_FLAG_CUSTOM_IO;
  l->input->pb = l->io;
  l->input->io_open = no_external;
  l->input->interrupt_callback = (AVIOInterruptCB){halted, l};
  l->input->probesize = 2 * MB;
  l->input->max_analyze_duration = 2000000;
  l->input->max_streams = 128;
  const AVInputFormat *flv = av_find_input_format(l->demux == 2   ? "mpegts"
                                                  : l->demux == 1 ? "mov"
                                                                  : "flv");
  if (!flv)
    return AVERROR_DEMUXER_NOT_FOUND;
  TRY(avformat_open_input(&l->input, NULL, flv, NULL));
  TRY(avformat_find_stream_info(l->input, NULL));
  if (l->input->nb_streams > 128)
    return BAD;
  l->v = l->a = -1;
  for (unsigned i = 0; i < l->input->nb_streams; i++) {
    AVCodecParameters *c = l->input->streams[i]->codecpar;
    if (l->mode == 2 && c->codec_type != AVMEDIA_TYPE_VIDEO &&
        c->codec_type != AVMEDIA_TYPE_AUDIO)
      return AVERROR(ENOSYS);
    if (l->mode == 2 && ((c->codec_type == AVMEDIA_TYPE_VIDEO && l->v >= 0) ||
                         (c->codec_type == AVMEDIA_TYPE_AUDIO && l->a >= 0)))
      return AVERROR(ENOSYS);
    if (encrypted(c))
      return AVERROR(EPERM);
    if (c->codec_type == AVMEDIA_TYPE_VIDEO && l->v < 0)
      l->v = i;
    else if (c->codec_type == AVMEDIA_TYPE_AUDIO && l->a < 0) {
      if (!can_audio(c->codec_id))
        return AVERROR(ENOSYS);
      l->a = i;
    }
  }
  if (l->v < 0)
    return l->pair ? AVERROR_STREAM_NOT_FOUND : radio(l);
  if (l->pair) {
    TRY(pl_pair_open(l->pair, l->input, l->v));
    if (!can_audio(pl_pair_audio(l->pair)->codecpar->codec_id))
      return AVERROR(ENOSYS);
    l->a = 128;
  }
  l->is = l->input->streams[l->v];
  AVCodecParameters *src = l->is->codecpar;
  int kind = src->codec_id == AV_CODEC_ID_H264   ? 1
             : src->codec_id == AV_CODEC_ID_HEVC ? 2
             : src->codec_id == AV_CODEC_ID_AV1  ? 3
             : src->codec_id == AV_CODEC_ID_VP9  ? 4
                                                 : 0;
  if (!kind || (l->codec && l->codec != kind) ||
      av_packet_side_data_get(src->coded_side_data, src->nb_coded_side_data,
                              AV_PKT_DATA_DOVI_CONF))
    return AVERROR(ENOSYS);
  if (l->mode == 2)
    return packet_copy(l);
  const char *name = kind == 1   ? "h264"
                     : kind == 2 ? "hevc"
                     : kind == 3 ? (l->mode ? "av1" : "libdav1d")
                                 : "vp9";
  const AVCodec *decoder = avcodec_find_decoder_by_name(name);
  if (!decoder)
    return AVERROR_DECODER_NOT_FOUND;
  l->dec = avcodec_alloc_context3(decoder);
  if (!l->dec)
    return AVERROR(ENOMEM);
  TRY(avcodec_parameters_to_context(l->dec, src));
  l->dec->pkt_timebase = l->is->time_base;
  l->dec->max_pixels = l->limit;
  l->dec->thread_count = 2;
  if (l->mode) {
    TRY(av_hwdevice_ctx_create(&l->hw, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL,
                               NULL, 0));
    l->dec->hw_device_ctx = av_buffer_ref(l->hw);
    if (!l->dec->hw_device_ctx)
      return AVERROR(ENOMEM);
    l->dec->get_format = choose_hw;
  }
  TRY(avcodec_open2(l->dec, decoder, NULL));
  int ret;
  TRY(create_output(l));
  l->os = avformat_new_stream(l->output, NULL);
  if (!l->os)
    return AVERROR(ENOMEM);
  TRY(add_audio(l));
  TRY(aac_header(l));
  l->pkt = av_packet_alloc();
  l->encoded = av_packet_alloc();
  l->image = av_frame_alloc();
  l->copied = av_frame_alloc();
  if (!l->pkt || !l->encoded || !l->image || !l->copied)
    return AVERROR(ENOMEM);
  int ready = 0;
  int64_t gop_bytes = 0, prekey_bytes = 0;
  while (!halted(l) && (ret = next_packet(l, l->pkt)) >= 0) {
    AVPacket *p = l->pkt;
    if (p->size < 0 || p->size > 32 * MB ||
        av_packet_get_side_data(p, AV_PKT_DATA_ENCRYPTION_INFO, NULL))
      return BAD;
    if (!ready && (prekey_bytes += p->size) > 32 * MB)
      return BAD;
    if (p->stream_index == l->v && (p->flags & AV_PKT_FLAG_KEY)) {
      ready = 1;
      gop_bytes = 0;
    }
    if (ready && (p->stream_index == l->v || p->stream_index == l->a)) {
      gop_bytes += p->size;
      if (gop_bytes > 128 * MB)
        return BAD;
      if (p->stream_index == l->v) {
        TRY(decode(l, p));
      } else if (l->started) {
        TRY(audio_packet(l, p));
      } else {
        if (l->count >= 256 || p->size > 8 * MB - l->wait_bytes)
          return BAD;
        AVPacket *copy = av_packet_clone(p);
        if (!copy)
          return AVERROR(ENOMEM);
        l->waiting[l->count++] = copy;
        l->wait_bytes += p->size;
      }
    }
    av_packet_unref(p);
  }
  if (halted(l))
    return AVERROR_EXIT;
  if (ret != AVERROR_EOF)
    return ret;
  if (!ready)
    return BAD;
  TRY(decode(l, NULL));
  if (!l->started || !l->stats->frames)
    return BAD;
  TRY(encode(l, NULL));
  return av_write_trailer(l->output);
}
int32_t pl_live_decode_pair(void *ctx, void *audio_ctx, PLLiveRead read,
                            PLLiveCancelled stop, int32_t audio_demux,
                            int64_t program_delta, int64_t origin90,
                            const char *folder, int32_t demux, int32_t mode,
                            int32_t required_codec, int32_t pixels,
                            PLLiveVideoStats *stats, char *msg, int32_t cap) {
  if (!read || !folder || !*folder || demux < 0 || demux > 2 || mode < 0 ||
      mode > 2 || required_codec < 0 || required_codec > 4 || pixels < 1 ||
      pixels > 8192 * 4608 || !stats)
    return BAD;
  memset(stats, 0, sizeof(*stats));
  if (msg && cap > 0)
    msg[0] = 0;
  Live l = {.ctx = ctx,
            .pull = read,
            .stop = stop,
            .folder = folder,
            .demux = demux,
            .mode = mode,
            .codec = required_codec,
            .limit = pixels,
            .stats = stats};
  if (audio_ctx) {
    if (audio_demux < 1 || audio_demux > 6 || demux < 1)
      return BAD;
    l.pair = pl_pair_new(audio_ctx, read, stop, audio_demux, program_delta,
                         origin90);
    if (!l.pair)
      return BAD;
    l.audio_demux = audio_demux;
  }
  int ret = run(&l);
  pl_pair_drop(l.pair);
  if (ret < 0 && msg && cap > 0)
    av_strerror(ret, msg, cap);
  for (int i = 0; i < l.front_count; i++)
    av_packet_free(&l.front[i]);
  av_bsf_free(&l.aac);
  for (int i = 0; i < l.count; i++)
    av_packet_free(&l.waiting[i]);
  av_packet_free(&l.pkt);
  av_packet_free(&l.encoded);
  av_frame_free(&l.image);
  av_frame_free(&l.copied);
  av_frame_free(&l.color);
  sws_freeContext(l.scale);
  avcodec_free_context(&l.dec);
  avcodec_free_context(&l.enc);
  av_buffer_unref(&l.hw);
  avformat_free_context(l.output);
  avformat_close_input(&l.input);
  if (l.io) {
    av_freep(&l.io->buffer);
    avio_context_free(&l.io);
  }
  return ret;
}

int32_t pl_live_decode_stream(void *ctx, PLLiveRead read, PLLiveCancelled stop,
                              const char *folder, int32_t demux, int32_t mode,
                              int32_t required_codec, int32_t pixels,
                              PLLiveVideoStats *stats, char *msg, int32_t cap) {
  return pl_live_decode_pair(ctx, NULL, read, stop, 0, INT64_MIN, -1, folder,
                             demux, mode, required_codec, pixels, stats, msg,
                             cap);
}
int32_t pl_live_decode(void *ctx, PLLiveRead read, PLLiveCancelled stop,
                       const char *folder, int32_t mode, int32_t codec,
                       int32_t pixels, PLLiveVideoStats *stats, char *msg,
                       int32_t size) {
  return pl_live_decode_stream(ctx, read, stop, folder, 0, mode, codec, pixels,
                               stats, msg, size);
}
