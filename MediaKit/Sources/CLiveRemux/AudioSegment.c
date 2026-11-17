#include "AudioSegment.h"
#include <errno.h>
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MIB (1024 * 1024)
#define INVALID AVERROR_INVALIDDATA
#define CHECK(expr)                                                            \
  do {                                                                         \
    int fail_ = (expr);                                                        \
    if (fail_ < 0)                                                             \
      return fail_;                                                            \
  } while (0)
typedef struct {
  PLTimingPCM *raw;
  const uint8_t *init, *media;
  int in_n, med_n;
  int64_t base, last, pos, traffic, first_byte, last_byte, deadline;
  uint8_t pad[16];
  int pad_n;
  void *opaque;
  PLAudioStop cancel;
  int stream, rate, channels;
  int64_t begin, end, written, last_input, first_out;
  const char *filters;
  AVFormatContext *input, *output;
  AVIOContext *io, *oio;
  AVStream *os;
  AVCodecContext *dec, *enc;
  AVFilterGraph *graph;
  AVFilterContext *src, *sink;
  AVAudioFifo *fifo;
  AVFrame *frame, *pcm;
  AVPacket *packet, *encoded;
  uint8_t *bytes;
  int size, cap;
} Process;
static uint32_t num(const uint8_t *p) {
  return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 |
         p[3];
}
static void store(uint8_t *p, uint64_t v, int n) {
  while (n) {
    p[--n] = (uint8_t)v;
    v >>= 8;
  }
}
static int stopping(void *v) {
  Process *p = v;
  return (p->cancel && p->cancel(p->opaque)) ||
         av_gettime_relative() > p->deadline;
}
static int read_bytes(void *v, uint8_t *dst, int n) {
  Process *p = v;
  if (stopping(p))
    return AVERROR_EXIT;
  if (n <= 0 || p->pos >= p->last)
    return AVERROR_EOF;
  if (p->traffic > 6LL * (p->in_n + p->med_n) + 4 * MIB)
    return INVALID;
  int64_t at = p->pos, t = n;
  if (at < p->in_n) {
    t = FFMIN(t, p->in_n - at);
    memcpy(dst, p->init + at, t);
  } else if (at < p->base) {
    t = FFMIN(t, p->base - at);
    memset(dst, 0, t);
    int64_t j = at - p->in_n;
    if (j < p->pad_n)
      memcpy(dst, p->pad + j, FFMIN(t, p->pad_n - j));
  } else {
    t = FFMIN(t, p->last - at);
    memcpy(dst, p->media + at - p->base, t);
  }
  p->pos += t;
  p->traffic += t;
  return (int)t;
}
static int64_t seek_bytes(void *v, int64_t offset, int whence) {
  Process *p = v;
  whence &= ~AVSEEK_FORCE;
  if (whence == AVSEEK_SIZE)
    return p->last;
  int64_t from = whence == SEEK_SET   ? 0
                 : whence == SEEK_CUR ? p->pos
                 : whence == SEEK_END ? p->last
                                      : -1;
  if (from < 0 || offset < -from || offset > p->last - from)
    return INVALID;
  return p->pos = from + offset;
}
static int external(AVFormatContext *a, AVIOContext **b, const char *c, int d,
                    AVDictionary **e) {
  (void)a;
  (void)b;
  (void)c;
  (void)d;
  (void)e;
  return AVERROR(EPERM);
}
static void close_in(Process *p) {
  avformat_close_input(&p->input);
  if (p->io) {
    av_freep(&p->io->buffer);
    avio_context_free(&p->io);
  }
}
static int open_in(Process *p) {
  p->pos = p->traffic = 0;
  uint8_t *buf = av_malloc(32768);
  if (!buf)
    return AVERROR(ENOMEM);
  p->io = avio_alloc_context(buf, 32768, 0, p, read_bytes, NULL, seek_bytes);
  if (!p->io) {
    av_free(buf);
    return AVERROR(ENOMEM);
  }
  p->input = avformat_alloc_context();
  if (!p->input)
    return AVERROR(ENOMEM);
  p->input->pb = p->io;
  p->input->flags |= AVFMT_FLAG_CUSTOM_IO;
  p->input->io_open = external;
  p->input->interrupt_callback = (AVIOInterruptCB){stopping, p};
  p->input->max_streams = 16;
  AVDictionary *options = NULL;
  av_dict_set(&options, "enable_drefs", "0", 0);
  av_dict_set(&options, "use_absolute_path", "0", 0);
  int ret = avformat_open_input(&p->input, NULL, av_find_input_format("mov"),
                                &options);
  av_dict_free(&options);
  CHECK(ret);
  p->stream =
      av_find_best_stream(p->input, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
  CHECK(p->stream);
  AVCodecParameters *par = p->input->streams[p->stream]->codecpar;
  if (par->codec_tag == MKTAG('e', 'n', 'c', 'a') ||
      av_packet_side_data_get(par->coded_side_data, par->nb_coded_side_data,
                              AV_PKT_DATA_ENCRYPTION_INIT_INFO))
    return AVERROR(EPERM);
  // Atmos/JOC object metadata must remain on the original rendition. Do not
  // flatten it to PCM.
  switch (par->codec_id) {
  case AV_CODEC_ID_AAC:
  case AV_CODEC_ID_ALAC:
  case AV_CODEC_ID_FLAC:
  case AV_CODEC_ID_MP3:
  case AV_CODEC_ID_OPUS:
    break;
  default:
    return AVERROR(ENOSYS);
  }
  if (par->sample_rate < 8000 || par->sample_rate > 192000 ||
      par->ch_layout.nb_channels < 1 || par->ch_layout.nb_channels > 8)
    return INVALID;
  p->rate = par->sample_rate;
  p->channels = par->ch_layout.nb_channels;
  return 0;
}
static int bounds(Process *p) {
  CHECK(open_in(p));
  if (p->raw)
    p->raw->first_video_seconds = NAN;
  int ret, count = 0;
  int64_t first = INT64_MAX, last = INT64_MIN;
  AVStream *track = p->input->streams[p->stream];
  while ((ret = av_read_frame(p->input, p->packet)) >= 0) {
    AVPacket *pkt = p->packet;
    if (stopping(p))
      return AVERROR_EXIT;
    if (++count > 65536 ||
        av_packet_get_side_data(pkt, AV_PKT_DATA_ENCRYPTION_INFO, NULL))
      return INVALID;
    if (p->raw && pkt->pts != AV_NOPTS_VALUE && pkt->pos >= p->first_byte &&
        pkt->pos <= p->last_byte &&
        p->input->streams[pkt->stream_index]->codecpar->codec_type ==
            AVMEDIA_TYPE_VIDEO) {
      double t =
          pkt->pts * av_q2d(p->input->streams[pkt->stream_index]->time_base);
      if (isfinite(t) && (!isfinite(p->raw->first_video_seconds) ||
                          t < p->raw->first_video_seconds))
        p->raw->first_video_seconds = t;
    }
    if (pkt->stream_index == p->stream) {
      if (pkt->pos < 0 || pkt->pts == AV_NOPTS_VALUE || pkt->duration <= 0 ||
          pkt->pts > INT64_MAX - pkt->duration)
        return INVALID;
      if (pkt->pos >= p->first_byte && pkt->pos <= p->last_byte) {
        int64_t start =
            av_rescale_q(pkt->pts, track->time_base, (AVRational){1, p->rate});
        int64_t end = av_rescale_q(pkt->pts + pkt->duration, track->time_base,
                                   (AVRational){1, p->rate});
        if (start < -p->rate * 60LL || start > 31LL * 86400 * p->rate ||
            end <= start || end - start > p->rate * 10LL)
          return INVALID;
        first = FFMIN(first, start);
        last = FFMAX(last, end);
      }
    }
    av_packet_unref(pkt);
  }
  if (ret != AVERROR_EOF)
    return ret;
  if (first == INT64_MAX || last <= FFMAX(first, 0) ||
      last - FFMAX(first, 0) > 90LL * p->rate)
    return INVALID;
  // Negative AAC priming is before movie time zero, not an audible extra first
  // block.
  p->begin = FFMAX(first, 0);
  p->end = last;
  close_in(p);
  return 0;
}
static int output_bytes(void *v, const uint8_t *data, int n) {
  Process *p = v;
  if (stopping(p))
    return AVERROR_EXIT;
  if (n < 0 || n > 48 * MIB - p->size)
    return AVERROR(ENOSPC);
  if (p->size + n > p->cap) {
    int newcap = FFMIN(48 * MIB, FFMAX(p->size + n, FFMAX(65536, p->cap * 2)));
    uint8_t *t = av_realloc(p->bytes, newcap);
    if (!t)
      return AVERROR(ENOMEM);
    p->bytes = t;
    p->cap = newcap;
  }
  memcpy(p->bytes + p->size, data, n);
  p->size += n;
  return n;
}
static int set_time(uint8_t *b, int size, uint64_t time, int depth) {
  int found = 0;
  for (int i = 0; i < size;) {
    if (size - i < 8)
      return -1;
    uint32_t n = num(b + i);
    if (n < 8 || n > (uint32_t)(size - i))
      return -1;
    if (depth == 2 && !memcmp(b + i + 4, "tfdt", 4)) {
      if (n < 16 || b[i + 8] > 1 || (b[i + 8] ? n < 20 : time > UINT32_MAX))
        return -1;
      store(b + i + 12, time, b[i + 8] ? 8 : 4);
      found++;
    } else if ((depth == 0 && !memcmp(b + i + 4, "moof", 4)) ||
               (depth == 1 && !memcmp(b + i + 4, "traf", 4))) {
      int sub = set_time(b + i + 8, n - 8, time, depth + 1);
      if (sub < 0)
        return -1;
      found += sub;
    }
    i += (int)n;
  }
  return found;
}
static int write_packets(Process *p, AVFrame *frame) {
  CHECK(avcodec_send_frame(p->enc, frame));
  int ret;
  while ((ret = avcodec_receive_packet(p->enc, p->encoded)) >= 0) {
    AVPacket *q = p->encoded;
    if (q->dts < 0 || q->pts == AV_NOPTS_VALUE)
      return INVALID;
    av_packet_rescale_ts(q, p->enc->time_base, p->os->time_base);
    q->stream_index = p->os->index;
    if (p->first_out == AV_NOPTS_VALUE)
      p->first_out = q->dts;
    ret = av_interleaved_write_frame(p->output, q);
    av_packet_unref(q);
    CHECK(ret);
  }
  return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}
static int drain_fifo(Process *p, int final) {
  int n;
  while ((n = av_audio_fifo_size(p->fifo)) >= p->enc->frame_size ||
         (final && n > 0)) {
    if (stopping(p))
      return AVERROR_EXIT;
    n = FFMIN(n, p->enc->frame_size);
    AVFrame *f = av_frame_alloc();
    if (!f)
      return AVERROR(ENOMEM);
    f->format = p->enc->sample_fmt;
    f->sample_rate = p->rate;
    f->nb_samples = n;
    f->pts = p->begin + p->written;
    int ret = av_channel_layout_copy(&f->ch_layout, &p->enc->ch_layout);
    if (ret >= 0)
      ret = av_frame_get_buffer(f, 0);
    if (ret >= 0 &&
        av_audio_fifo_read(p->fifo, (void **)f->extended_data, n) != n)
      ret = INVALID;
    if (ret >= 0)
      ret = write_packets(p, f);
    av_frame_free(&f);
    CHECK(ret);
    p->written += n;
  }
  return 0;
}
static int receive_pcm(Process *p) {
  int ret;
  while ((ret = av_buffersink_get_frame(p->sink, p->pcm)) >= 0) {
    AVFrame *f = p->pcm;
    if (stopping(p))
      return AVERROR_EXIT;
    if (f->format != AV_SAMPLE_FMT_S32P || f->sample_rate != p->rate ||
        f->ch_layout.nb_channels != p->channels || f->pts == AV_NOPTS_VALUE)
      return INVALID;
    int64_t from = av_rescale_q(f->pts, av_buffersink_get_time_base(p->sink),
                                (AVRational){1, p->rate}),
            to = from + f->nb_samples;
    int64_t desired =
        p->begin + p->written + (p->raw ? 0 : av_audio_fifo_size(p->fifo));
    int64_t a = FFMAX(from, desired), b = FFMIN(to, p->end);
    if (a < b) {
      if (a != desired)
        return INVALID;
      void *planes[8];
      for (int c = 0; c < p->channels; c++)
        planes[c] = f->extended_data[c] + (a - from) * 4;
      if (p->raw) {
        size_t count = (size_t)(b - a) * p->channels;
        if (count > (size_t)(p->cap - p->size) / 4)
          return INVALID;
        int32_t *out = (int32_t *)(p->bytes + p->size);
        for (int i = 0; i < b - a; i++)
          for (int ch = 0; ch < p->channels; ch++)
            *out++ = ((const int32_t *)planes[ch])[i];
        p->size += (int)(count * 4);
        p->written += b - a;
        av_frame_unref(f);
        continue;
      }
      if (av_audio_fifo_write(p->fifo, planes, (int)(b - a)) != b - a)
        return INVALID;
      CHECK(drain_fifo(p, 0));
    }
    av_frame_unref(f);
  }
  return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}
static int numeric(const char *s, double *v) {
  if (!s || !*s || strlen(s) > 22 || strspn(s, "+-0123456789.eE") != strlen(s))
    return 0;
  char *end = NULL;
  *v = strtod(s, &end);
  return end && !*end && isfinite(*v);
}
static int allowed(const char *name, const char *k, double v) {
  if (!strcmp(name, "volume"))
    return !strcmp(k, "volume") && v >= 0 && v <= 3;
  if (!strcmp(name, "loudnorm")) {
    if (!strcmp(k, "I"))
      return v >= -70 && v <= -5;
    if (!strcmp(k, "LRA"))
      return v >= 1 && v <= 50;
    if (!strcmp(k, "TP"))
      return v >= -9 && v <= 0;
    if (!strcmp(k, "offset") || !strcmp(k, "measured_TP"))
      return fabs(v) <= 99;
    if (!strcmp(k, "measured_I") || !strcmp(k, "measured_thresh"))
      return v >= -99 && v <= 0;
    if (!strcmp(k, "measured_LRA"))
      return v >= 0 && v <= 99;
    return (!strcmp(k, "linear") || !strcmp(k, "dual_mono")) &&
           (v == 0 || v == 1);
  }
  if (strcmp(name, "dynaudnorm"))
    return 0;
  if (!strcmp(k, "f"))
    return v == floor(v) && v >= 10 && v <= 1000;
  if (!strcmp(k, "g"))
    return v == floor(v) && v >= 3 && v <= 31 && ((int)v % 2);
  if (!strcmp(k, "p") || !strcmp(k, "r") || !strcmp(k, "t"))
    return v >= 0 && v <= 1;
  if (!strcmp(k, "m"))
    return v >= 1 && v <= 100;
  if (!strcmp(k, "s"))
    return v >= 0 && v <= 30;
  return (!strcmp(k, "n") || !strcmp(k, "c") || !strcmp(k, "b")) &&
         (v == 0 || v == 1);
}
static int chain(Process *p, AVFilterContext **previous) {
  char copy[1024];
  size_t len = strlen(p->filters);
  if (len < 1 || len >= sizeof(copy))
    return INVALID;
  memcpy(copy, p->filters, len + 1);
  char *s = copy;
  int count = 0;
  uint64_t filter_budget = 0;
  while (s && *s) {
    char *next = strchr(s, ',');
    if (next)
      *next++ = 0;
    char *values = strchr(s, '=');
    if (!values || ++count > 6)
      return INVALID;
    *values++ = 0;
    if (strcmp(s, "loudnorm") && strcmp(s, "dynaudnorm") && strcmp(s, "volume"))
      return INVALID;
    const AVFilter *f = avfilter_get_by_name(s);
    if (!f)
      return AVERROR_FILTER_NOT_FOUND;
    AVFilterContext *ctx = avfilter_graph_alloc_filter(p->graph, f, NULL);
    if (!ctx)
      return AVERROR(ENOMEM);
    double width = 500, gauss = 31;
    while (values && *values) {
      char *tail = strchr(values, ':');
      if (tail)
        *tail++ = 0;
      char *value = strchr(values, '=');
      if (!value)
        return INVALID;
      *value++ = 0;
      double v;
      if (!numeric(value, &v) || !allowed(s, values, v))
        return INVALID;
      if (!strcmp(values, "f"))
        width = v;
      if (!strcmp(values, "g"))
        gauss = v;
      CHECK(av_opt_set(ctx->priv, values, value, 0));
      values = tail;
    }
    if (!strcmp(s, "dynaudnorm")) {
      if (width * gauss > 12000)
        return INVALID;
      filter_budget +=
          (uint64_t)(width * gauss / 1000.0 * p->rate * p->channels * 16.0);
    } else if (!strcmp(s, "loudnorm"))
      filter_budget += 192000ULL * p->channels * 3 * 12;
    if (filter_budget > 96 * MIB)
      return AVERROR(ENOMEM);
    CHECK(avfilter_init_str(ctx, NULL));
    CHECK(avfilter_link(*previous, 0, ctx, 0));
    *previous = ctx;
    s = next;
  }
  return count ? 0 : INVALID;
}
static int setup(Process *p, AVFrame *f) {
  char layout[128], desc[380];
  if (f->sample_rate != p->rate || f->ch_layout.nb_channels != p->channels)
    return INVALID;
  CHECK(av_channel_layout_describe(&f->ch_layout, layout, sizeof(layout)));
  const char *fmt = av_get_sample_fmt_name(f->format);
  if (!fmt)
    return INVALID;
  snprintf(desc, sizeof(desc),
           "time_base=1/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
           p->rate, p->rate, fmt, layout);
  p->graph = avfilter_graph_alloc();
  if (!p->graph)
    return AVERROR(ENOMEM);
  p->graph->nb_threads = 1;
  CHECK(avfilter_graph_create_filter(&p->src, avfilter_get_by_name("abuffer"),
                                     "input", desc, NULL, p->graph));
  AVFilterContext *tail = p->src, *form = NULL;
  CHECK(chain(p, &tail));
  snprintf(desc, sizeof(desc),
           "sample_fmts=s32p:sample_rates=%d:channel_layouts=%s", p->rate,
           layout);
  CHECK(avfilter_graph_create_filter(&form, avfilter_get_by_name("aformat"),
                                     "pcm", desc, NULL, p->graph));
  CHECK(avfilter_link(tail, 0, form, 0));
  CHECK(avfilter_graph_create_filter(&p->sink,
                                     avfilter_get_by_name("abuffersink"),
                                     "output", NULL, NULL, p->graph));
  CHECK(avfilter_link(form, 0, p->sink, 0));
  CHECK(avfilter_graph_config(p->graph, NULL));
  if (p->raw) {
    const int64_t count = p->end - p->begin;
    if (count <= 0 || count > (32 * MIB) / (4 * p->channels) ||
        count > INT32_MAX)
      return AVERROR(ENOSPC);
    p->cap = (int)(count * 4 * p->channels);
    p->bytes = av_malloc(p->cap);
    if (!p->bytes)
      return AVERROR(ENOMEM);
    p->raw->frames = (int)count;
    p->raw->first_sample = p->begin;
    p->raw->rate = p->rate;
    p->raw->channels = p->channels;
    for (int i = 0; i < p->channels; i++)
      p->raw->layout[i] =
          (int)av_channel_layout_channel_from_index(&f->ch_layout, (unsigned)i);
    return 0;
  }
  const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_ALAC);
  if (!codec)
    return AVERROR_ENCODER_NOT_FOUND;
  p->enc = avcodec_alloc_context3(codec);
  if (!p->enc)
    return AVERROR(ENOMEM);
  CHECK(av_channel_layout_copy(&p->enc->ch_layout, &f->ch_layout));
  p->enc->sample_rate = p->rate;
  p->enc->sample_fmt = AV_SAMPLE_FMT_S32P;
  p->enc->bits_per_raw_sample = 24;
  p->enc->time_base = (AVRational){1, p->rate};
  p->enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  CHECK(avcodec_open2(p->enc, codec, NULL));
  if (p->enc->frame_size <= 0 || p->enc->frame_size > 32768)
    return INVALID;
  p->fifo = av_audio_fifo_alloc(p->enc->sample_fmt, p->channels,
                                2 * p->enc->frame_size);
  if (!p->fifo)
    return AVERROR(ENOMEM);
  CHECK(avformat_alloc_output_context2(&p->output, NULL, "mp4", NULL));
  p->output->flags |= AVFMT_FLAG_CUSTOM_IO;
  p->output->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
  p->os = avformat_new_stream(p->output, NULL);
  if (!p->os)
    return AVERROR(ENOMEM);
  CHECK(avcodec_parameters_from_context(p->os->codecpar, p->enc));
  p->os->time_base = p->enc->time_base;
  uint8_t *buffer = av_malloc(32768);
  if (!buffer)
    return AVERROR(ENOMEM);
  p->oio = avio_alloc_context(buffer, 32768, 1, p, NULL, output_bytes, NULL);
  if (!p->oio) {
    av_free(buffer);
    return AVERROR(ENOMEM);
  }
  p->output->pb = p->oio;
  CHECK(av_opt_set(p->output->priv_data, "movflags",
                   "empty_moov+frag_custom+default_base_moof+skip_trailer", 0));
  CHECK(av_opt_set(p->output->priv_data, "use_editlist", "0", 0));
  return avformat_write_header(p->output, NULL);
}
static int decoder(Process *p, const AVPacket *pkt) {
  CHECK(avcodec_send_packet(p->dec, pkt));
  int ret;
  while ((ret = avcodec_receive_frame(p->dec, p->frame)) >= 0) {
    AVFrame *f = p->frame;
    int64_t pts = f->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE)
      pts = f->pts;
    if (pts == AV_NOPTS_VALUE || f->nb_samples <= 0 || f->nb_samples > 131072 ||
        stopping(p))
      return INVALID;
    if (!p->graph)
      CHECK(setup(p, f));
    f->pts = av_rescale_q(pts, p->input->streams[p->stream]->time_base,
                          (AVRational){1, p->rate});
    if (p->last_input != AV_NOPTS_VALUE &&
        llabs(f->pts - p->last_input) > p->rate * 2LL)
      return INVALID;
    p->last_input = f->pts + f->nb_samples;
    CHECK(av_buffersrc_add_frame_flags(p->src, f, 0));
    av_frame_unref(f);
    CHECK(receive_pcm(p));
  }
  return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}
static int process(Process *p) {
  p->frame = av_frame_alloc();
  p->pcm = av_frame_alloc();
  p->packet = av_packet_alloc();
  p->encoded = av_packet_alloc();
  if (!p->frame || !p->pcm || !p->packet || !p->encoded)
    return AVERROR(ENOMEM);
  CHECK(bounds(p));
  CHECK(open_in(p));
  AVCodecParameters *par = p->input->streams[p->stream]->codecpar;
  const AVCodec *codec = avcodec_find_decoder(par->codec_id);
  if (!codec)
    return AVERROR_DECODER_NOT_FOUND;
  p->dec = avcodec_alloc_context3(codec);
  if (!p->dec)
    return AVERROR(ENOMEM);
  CHECK(avcodec_parameters_to_context(p->dec, par));
  p->dec->pkt_timebase = p->input->streams[p->stream]->time_base;
  p->dec->thread_count = 1;
  CHECK(avcodec_open2(p->dec, codec, NULL));
  p->last_input = p->first_out = AV_NOPTS_VALUE;
  int ret;
  while ((ret = av_read_frame(p->input, p->packet)) >= 0) {
    if (stopping(p))
      return AVERROR_EXIT;
    if (p->packet->stream_index == p->stream)
      CHECK(decoder(p, p->packet));
    av_packet_unref(p->packet);
  }
  if (ret != AVERROR_EOF)
    return ret;
  CHECK(decoder(p, NULL));
  if (!p->graph)
    return INVALID;
  CHECK(av_buffersrc_add_frame_flags(p->src, NULL, 0));
  CHECK(receive_pcm(p));
  if (p->raw)
    return p->written == p->end - p->begin && p->size == p->cap ? 0 : INVALID;
  CHECK(drain_fifo(p, 1));
  if (p->written != p->end - p->begin || p->first_out == AV_NOPTS_VALUE)
    return INVALID;
  CHECK(write_packets(p, NULL));
  CHECK(av_interleaved_write_frame(p->output, NULL));
  CHECK(av_write_frame(p->output, NULL));
  CHECK(av_write_trailer(p->output));
  avio_flush(p->oio);
  if (p->oio->error)
    return p->oio->error;
  return set_time(p->bytes, p->size, p->first_out, 0) == 1 ? 0 : INVALID;
}
static int32_t pl_audio_run(PLTimingPCM *raw, const uint8_t *init, int32_t in_n,
                            const uint8_t *media, int32_t med_n, int64_t offset,
                            int64_t first, int64_t last, const char *filters,
                            void *ctx, PLAudioStop cancel, uint8_t **result,
                            int32_t *size, char *error, int32_t error_size) {
  if (!result || !size)
    return INVALID;
  *result = NULL;
  *size = 0;
  if (!init || !media || !filters || in_n < 8 || in_n > 4 * MIB || med_n < 8 ||
      med_n > 48 * MIB || offset < in_n || offset > INT64_MAX - med_n ||
      first < offset || last < first || last >= offset + med_n)
    return INVALID;
  Process p = {0};
  p.raw = raw;
  if (raw)
    memset(raw, 0, sizeof(*raw));
  p.init = init;
  p.in_n = in_n;
  p.media = media;
  p.med_n = med_n;
  p.base = offset;
  p.last = offset + med_n;
  p.first_byte = first;
  p.last_byte = last;
  p.opaque = ctx;
  p.cancel = cancel;
  p.filters = filters;
  p.deadline = av_gettime_relative() + 55000000;
  uint64_t gap = offset - in_n;
  if (gap) {
    if (gap < 8)
      return INVALID;
    p.pad_n = gap > UINT32_MAX ? 16 : 8;
    store(p.pad, gap > UINT32_MAX ? 1 : gap, 4);
    memcpy(p.pad + 4, "free", 4);
    if (p.pad_n == 16)
      store(p.pad + 8, gap, 8);
  }
  int ret = process(&p);
  if (ret >= 0) {
    *result = p.bytes;
    *size = p.size;
    p.bytes = NULL;
  } else if (error && error_size > 0) {
    av_strerror(ret, error, error_size);
  }
  close_in(&p);
  avformat_free_context(p.output);
  if (p.oio) {
    av_freep(&p.oio->buffer);
    avio_context_free(&p.oio);
  }
  av_audio_fifo_free(p.fifo);
  avfilter_graph_free(&p.graph);
  avcodec_free_context(&p.dec);
  avcodec_free_context(&p.enc);
  av_packet_free(&p.packet);
  av_packet_free(&p.encoded);
  av_frame_free(&p.frame);
  av_frame_free(&p.pcm);
  av_free(p.bytes);
  return ret;
}
void pl_free_audio(void *p) { av_free(p); }

int32_t pl_audio_segment(const uint8_t *init, int32_t in_n,
                         const uint8_t *media, int32_t med_n, int64_t offset,
                         int64_t first, int64_t last, const char *filter,
                         void *ctx, PLAudioStop cancel, uint8_t **result,
                         int32_t *size, char *error, int32_t error_size) {
  return pl_audio_run(NULL, init, in_n, media, med_n, offset, first, last,
                      filter, ctx, cancel, result, size, error, error_size);
}
int32_t pl_audio_pcm(const uint8_t *init, int32_t in_n, const uint8_t *media,
                     int32_t med_n, int64_t offset, int64_t first, int64_t last,
                     const char *filter, void *ctx, PLAudioStop cancel,
                     PLTimingPCM *raw, uint8_t **result, int32_t *size,
                     char *error, int32_t error_size) {
  if (!raw)
    return INVALID;
  return pl_audio_run(raw, init, in_n, media, med_n, offset, first, last,
                      filter, ctx, cancel, result, size, error, error_size);
}
