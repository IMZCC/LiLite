#include "LivePairCore.h"
#include <libavutil/avstring.h>
#include <libavutil/mem.h>
#include <limits.h>
#include <stdlib.h>

/* Each clear rendition owns a separate demuxer. The two look-ahead packets are
 * emitted in DTS order on a shared timeline; no audio resampling, lossy
 * transcode or HLS sequence-number sync. */
struct PLLivePair {
  void *ctx;
  PLLiveRead read;
  PLLiveCancelled stop;
  int type, v, a, ve, ae, aligned;
  AVFormatContext *video, *audio;
  AVIOContext *io;
  AVPacket *vp, *ap;
  int64_t origin90, program_delta, shift, last_v, last_a, next_audio;
};
static int stop_io(void *ctx) {
  PLLivePair *p = ctx;
  return p->stop && p->stop(p->ctx);
}
static int pull_io(void *ctx, uint8_t *bytes, int n) {
  PLLivePair *p = ctx;
  if (stop_io(p))
    return AVERROR_EXIT;
  int r = p->read(p->ctx, bytes, n);
  if (r > n)
    return AVERROR_INVALIDDATA;
  return r > 0   ? r
         : r < 0 ? stop_io(p) ? AVERROR_EXIT : AVERROR(EIO)
                 : AVERROR_EOF;
}
static int no_url(AVFormatContext *f, AVIOContext **io, const char *u,
                  int flags, AVDictionary **options) {
  (void)f;
  (void)io;
  (void)u;
  (void)flags;
  (void)options;
  return AVERROR(EPERM);
}
PLLivePair *pl_pair_new(void *ctx, PLLiveRead read, PLLiveCancelled stop,
                        int type, int64_t delta, int64_t origin90) {
  if (!read || type < 1 || type > 6 || origin90 < -1 ||
      origin90 >= INT64_C(8589934592) ||
      (delta != INT64_MIN && (delta < -300000000LL || delta > 300000000LL)))
    return NULL;
  PLLivePair *p = av_mallocz(sizeof(*p));
  if (p) {
    p->ctx = ctx;
    p->read = read;
    p->stop = stop;
    p->type = type;
    p->program_delta = delta;
    p->origin90 = origin90;
    p->next_audio = p->last_v = p->last_a = AV_NOPTS_VALUE;
  }
  return p;
}
int pl_pair_open(PLLivePair *p, AVFormatContext *video, int stream) {
  if (!p || !video || stream < 0 || stream >= (int)video->nb_streams)
    return AVERROR_INVALIDDATA;
  p->video = video;
  p->v = stream;
  p->vp = av_packet_alloc();
  p->ap = av_packet_alloc();
  p->audio = avformat_alloc_context();
  uint8_t *b = av_malloc(32768);
  if (!b || !p->audio || !p->vp || !p->ap) {
    av_free(b);
    return AVERROR(ENOMEM);
  }
  p->io = avio_alloc_context(b, 32768, 0, p, pull_io, NULL, NULL);
  if (!p->io) {
    av_free(b);
    return AVERROR(ENOMEM);
  }
  AVFormatContext *f = p->audio;
  f->io_open = no_url;
  f->pb = p->io;
  f->flags |= AVFMT_FLAG_CUSTOM_IO;
  f->interrupt_callback = (AVIOInterruptCB){stop_io, p};
  f->max_streams = 32;
  f->probesize = 1024 * 1024;
  f->max_analyze_duration = 1000000;
  AVDictionary *options = NULL;
  av_dict_set(&options, "enable_drefs", "0", 0);
  av_dict_set(&options, "use_absolute_path", "0", 0);
  int ret = avformat_open_input(
      &p->audio, NULL,
      av_find_input_format((const char *[]){"", "mov", "mpegts", "aac", "mp3",
                                            "ac3", "eac3"}[p->type]),
      &options);
  av_dict_free(&options);
  if (ret < 0)
    return ret;
  if ((ret = avformat_find_stream_info(p->audio, NULL)) < 0)
    return ret;
  int a = -1;
  for (unsigned i = 0; i < p->audio->nb_streams; i++) {
    AVCodecParameters *s = p->audio->streams[i]->codecpar;
    if (s->codec_tag == MKTAG('e', 'n', 'c', 'a') ||
        s->codec_tag == MKTAG('e', 'n', 'c', 'v') ||
        av_packet_side_data_get(s->coded_side_data, s->nb_coded_side_data,
                                AV_PKT_DATA_ENCRYPTION_INIT_INFO))
      return AVERROR(EPERM);
    if (s->codec_type == AVMEDIA_TYPE_AUDIO) {
      if (a != -1)
        return AVERROR_INVALIDDATA;
      a = (int)i;
    }
  }
  if (a < 0)
    return AVERROR_STREAM_NOT_FOUND;
  p->a = a;
  return 0;
}
AVStream *pl_pair_audio(PLLivePair *p) { return p->audio->streams[p->a]; }
static int take(PLLivePair *p, AVFormatContext *f, int idx, AVPacket *packet,
                int *eof) {
  if (*eof || packet->buf)
    return 0;
  for (int i = 0; i < 4096; i++) {
    if (stop_io(p))
      return AVERROR_EXIT;
    int r = av_read_frame(f, packet);
    if (r == AVERROR_EOF) {
      *eof = 1;
      return 0;
    }
    if (r < 0)
      return r;
    if (packet->size <= 0 || packet->size > 32 * 1024 * 1024 ||
        av_packet_get_side_data(packet, AV_PKT_DATA_ENCRYPTION_INFO, NULL))
      return AVERROR_INVALIDDATA;
    if (packet->stream_index == idx) {
      if (f == p->audio) {
        AVStream *s = f->streams[idx];
        AVCodecParameters *c = s->codecpar;
        if (packet->pts == AV_NOPTS_VALUE)
          packet->pts =
              packet->dts != AV_NOPTS_VALUE ? packet->dts : p->next_audio;
        if (packet->pts == AV_NOPTS_VALUE && p->type >= 3 &&
            (p->origin90 >= 0 || p->program_delta != INT64_MIN))
          packet->pts = 0;
        if (packet->pts == AV_NOPTS_VALUE)
          return AVERROR_INVALIDDATA;
        if (packet->dts == AV_NOPTS_VALUE)
          packet->dts = packet->pts;
        int samples = av_get_audio_frame_duration2(c, packet->size);
        if (c->codec_id == AV_CODEC_ID_AAC && packet->size >= 7 &&
            packet->data[0] == 0xff && (packet->data[1] & 0xf6) == 0xf0)
          samples = 1024 * (1 + (packet->data[6] & 3));
        if (samples > 0 && samples <= 65536 && c->sample_rate > 0) {
          p->next_audio =
              av_add_stable(s->time_base, packet->pts,
                            (AVRational){1, c->sample_rate}, samples);
          if (packet->duration <= 0)
            packet->duration = p->next_audio - packet->pts;
        } else if (packet->duration > 0 &&
                   packet->pts < INT64_MAX - packet->duration) {
          p->next_audio = packet->pts + packet->duration;
        } else {
          p->next_audio = AV_NOPTS_VALUE;
        }
      } else {
        if (packet->pts == AV_NOPTS_VALUE)
          return AVERROR_INVALIDDATA;
        if (packet->dts == AV_NOPTS_VALUE)
          packet->dts = packet->pts;
      }
      return 0;
    }
    av_packet_unref(packet);
  }
  return AVERROR_INVALIDDATA;
}
static int64_t us(int64_t ts, AVStream *s) {
  return av_rescale_q(ts, s->time_base, AV_TIME_BASE_Q);
}
int pl_pair_next(PLLivePair *p, AVPacket *out) {
  int r = take(p, p->video, p->v, p->vp, &p->ve);
  if (r < 0)
    return r;
  r = take(p, p->audio, p->a, p->ap, &p->ae);
  if (r < 0)
    return r;
  AVStream *v = p->video->streams[p->v], *a = pl_pair_audio(p);
  if (!p->aligned) {
    if (!p->vp->buf || !p->ap->buf)
      return AVERROR_INVALIDDATA;
    int64_t vp = us(p->vp->pts, v), ap = us(p->ap->pts, a);
    if (vp < -300000000LL || vp > INT64_C(1000000000000000) ||
        ap < -300000000LL || ap > INT64_C(1000000000000000))
      return AVERROR_INVALIDDATA;
    int64_t d = vp - ap,
            wrap = INT64_C(95443717689); // 2^33 at 90 kHz, in microseconds
    int64_t offset = 0;
    if (p->program_delta != INT64_MIN) {
      offset = d + p->program_delta;
    } else if (p->origin90 >= 0) {
      int64_t target =
          av_rescale_q(p->origin90, (AVRational){1, 90000}, AV_TIME_BASE_Q);
      if (llabs(vp - target) > 120000000 &&
          llabs(llabs(vp - target) - wrap) <= 120000000)
        target += vp > target ? wrap : -wrap;
      if (llabs(vp - target) > 120000000)
        return AVERROR_INVALIDDATA;
      offset = target - ap;
    } else if (llabs(d) > 120000000) {
      if (llabs(llabs(d) - wrap) > 120000000)
        return AVERROR_INVALIDDATA;
      offset = d > 0 ? wrap : -wrap;
    }
    p->shift = av_rescale_q(offset, AV_TIME_BASE_Q, a->time_base);
    p->aligned = 1;
  }
  if (!p->vp->buf && !p->ap->buf)
    return AVERROR_EOF;
  int64_t av = INT64_MAX, vv = INT64_MAX;
  if (p->vp->buf)
    vv = us(p->vp->dts, v);
  if (p->ap->buf) {
    if (llabs(p->ap->dts) > INT64_MAX / 4 ||
        llabs(p->ap->pts) > INT64_MAX / 4 || llabs(p->shift) > INT64_MAX / 4)
      return AVERROR_INVALIDDATA;
    av = us(p->ap->dts + p->shift, a);
  }
  if (p->ae && !p->ap->buf && p->last_a != AV_NOPTS_VALUE && vv != INT64_MAX &&
      vv - p->last_a > 2000000)
    return AVERROR_INVALIDDATA;
  if (p->ve && !p->vp->buf && p->last_v != AV_NOPTS_VALUE && av != INT64_MAX &&
      av - p->last_v > 50000)
    return AVERROR_EOF;
  if (vv <= av) {
    if (!p->vp->buf)
      return AVERROR_EOF;
    av_packet_move_ref(out, p->vp);
    int64_t end = us(out->pts, v) + FFMAX(0, us(out->duration, v));
    p->last_v = FFMAX(p->last_v, end);
  } else {
    av_packet_move_ref(out, p->ap);
    out->pts += p->shift;
    out->dts += p->shift;
    out->stream_index = 128;
    p->last_a = av + FFMAX(0, us(out->duration, a));
  }
  return 0;
}
void pl_pair_drop(PLLivePair *p) {
  if (!p)
    return;
  av_packet_free(&p->vp);
  av_packet_free(&p->ap);
  avformat_close_input(&p->audio);
  if (p->io) {
    av_freep(&p->io->buffer);
    avio_context_free(&p->io);
  }
  av_free(p);
}
