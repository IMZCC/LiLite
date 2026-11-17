#include "TimingRing.h"
#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// The producer is a serial decoder, the sole consumer is the real-time hardware
// callback. Cursor state and controls never block the render thread. The
// reserved history makes a repeated audio block read real PCM that has not been
// overwritten by the producer.
struct PLTimingRing {
  int rate, channels, capacity, history;
  int64_t first;
  _Atomic(int64_t) put, consumed;
  int64_t historyFloor;
  double cursor, hop_rate;
  int hop, in_hop, has_tail;
  float *overlap, *work;
  _Atomic(double) ratio, tempo, anchor, host, renderSpan;
  _Atomic(unsigned) sequence;
  _Atomic(int) step, rendered;
  int32_t data[];
};
PLTimingRing *pl_clock_ring(int32_t rate, int32_t channels, int32_t capacity,
                            int64_t first) {
  if (rate < 8000 || rate > 192000 || channels < 1 || channels > 8 ||
      capacity < 4096 || capacity > rate * 8 || first < 0)
    return NULL;
  if ((size_t)capacity * channels > 32u * 1024u * 1024u / 4u)
    return NULL;
  PLTimingRing *r =
      calloc(1, sizeof *r + sizeof(int32_t) * (size_t)capacity * channels);
  if (!r)
    return NULL;
  r->rate = rate;
  r->channels = channels;
  r->capacity = capacity;
  r->history = 1025;
  r->first = first;
  r->hop = rate / 50;
  r->in_hop = r->hop;
  if (r->history < rate / 200 + 2)
    r->history = rate / 200 + 2;
  r->overlap = calloc((size_t)r->hop * channels * 2, sizeof(float));
  if (!r->overlap) {
    free(r);
    return NULL;
  }
  r->work = r->overlap + (size_t)r->hop * channels;
  atomic_init(&r->tempo, 1);
  atomic_init(&r->renderSpan, 0);
  atomic_init(&r->put, 0);
  atomic_init(&r->consumed, 0);
  atomic_init(&r->ratio, 1);
  atomic_init(&r->anchor, 0);
  atomic_init(&r->host, NAN);
  atomic_init(&r->sequence, 0);
  atomic_init(&r->step, 0);
  atomic_init(&r->rendered, 0);
  return r;
}
void pl_clock_destroy(PLTimingRing *r) {
  if (r)
    free(r->overlap);
  free(r);
}
int32_t pl_clock_available(PLTimingRing *r) {
  if (!r)
    return 0;
  int64_t used = atomic_load(&r->put) - atomic_load(&r->consumed) + r->history;
  return used >= r->capacity ? 0 : (int32_t)(r->capacity - used);
}
int32_t pl_clock_buffered(PLTimingRing *r) {
  if (!r)
    return 0;
  int64_t n = atomic_load(&r->put) - atomic_load(&r->consumed);
  return (int32_t)(n > 0 ? n : 0);
}
int32_t pl_clock_write(PLTimingRing *r, const void *pcm, int32_t n) {
  if (!r || n <= 0)
    return 0;
  int avail = pl_clock_available(r);
  if (n > avail)
    n = avail;
  int64_t seq = atomic_load_explicit(&r->put, memory_order_relaxed);
  int pos = (int)(seq % r->capacity), first = r->capacity - pos;
  if (first > n)
    first = n;
  size_t width = (size_t)r->channels * sizeof(int32_t);
  if (pcm) {
    memcpy(r->data + (size_t)pos * r->channels, pcm, first * width);
    if (first < n)
      memcpy(r->data, (const char *)pcm + first * width, (n - first) * width);
  } else {
    memset(r->data + (size_t)pos * r->channels, 0, first * width);
    if (first < n)
      memset(r->data, 0, (n - first) * width);
  }
  atomic_store_explicit(&r->put, seq + n, memory_order_release);
  return n;
}
void pl_clock_control(PLTimingRing *r, double ratio, int32_t block) {
  if (!r)
    return;
  if (isfinite(ratio) && ratio >= 0.9 && ratio <= 1.1)
    atomic_store(&r->ratio, ratio);
  if (block == 1 || block == -1)
    atomic_store(&r->step, block);
}
#include "TimingStretch.h"
void pl_clock_tempo(PLTimingRing *r, double tempo) {
  if (r && isfinite(tempo) && tempo >= 0.45 && tempo <= 2.55)
    atomic_store(&r->tempo, tempo);
}
int32_t pl_clock_render(PLTimingRing *r, int32_t frames, float *const *planes,
                        double host) {
  if (!r || !planes || frames < 0 || frames > 65536)
    return 0;
  for (int c = 0; c < r->channels; c++)
    if (!planes[c])
      return 0;
  int64_t end = atomic_load_explicit(&r->put, memory_order_acquire);
  double ratio = atomic_load(&r->ratio), pos = r->cursor;
  int step = atomic_exchange(&r->step, 0);
  // A command drops or repeats exactly 1024 source frames; direction survives
  // fractional resampling.
  if (step == 1 && end - (int64_t)pos >= 1024 + 2)
    pos += 1024;
  if (step == -1 && (int64_t)pos - 1024 >= r->historyFloor)
    pos -= 1024;
  if (step) {
    r->in_hop = r->hop;
    r->has_tail = 0;
  }
  double start = pos, tempo = atomic_load(&r->tempo);
  int i = 0;
  for (; i < frames; i++) {
    if (pos >= end)
      break;
    if (fabs(tempo - 1) > 0.00001 || r->has_tail) {
      if (r->in_hop >= r->hop && !make_hop(r, pos, end, ratio, tempo))
        break;
      for (int c = 0; c < r->channels; c++)
        planes[c][i] = r->work[r->in_hop * r->channels + c];
      r->in_hop++;
      pos += r->hop_rate;
    } else {
      for (int c = 0; c < r->channels; c++)
        planes[c][i] = sample_at(r, pos, c, end);
      pos += ratio;
    }
  }
  if (pos > end)
    pos = end;
  for (int c = 0; c < r->channels; c++)
    if (i < frames)
      memset(planes[c] + i, 0, (size_t)(frames - i) * sizeof(float));
  r->cursor = pos;
  // A repeated block must not reopen already-overwritten history for a second
  // repeat.
  int64_t floor = (int64_t)pos - r->history;
  if (floor > r->historyFloor)
    r->historyFloor = floor;
  atomic_store_explicit(&r->consumed, (int64_t)pos, memory_order_release);
  atomic_fetch_add(&r->sequence, 1);
  atomic_store(&r->anchor, (r->first + start) / r->rate);
  atomic_store(&r->renderSpan, (pos - start) / r->rate);
  atomic_store(&r->host, host);
  atomic_store(&r->rendered, i);
  atomic_fetch_add(&r->sequence, 1);
  return i;
}
double pl_clock_time(PLTimingRing *r, double host, double rate,
                     double latency) {
  if (!r || !isfinite(host) || !isfinite(rate) || rate <= 0)
    return NAN;
  for (int i = 0; i < 3; i++) {
    unsigned s = atomic_load(&r->sequence);
    if (s & 1)
      continue;
    double t = atomic_load(&r->host), a = atomic_load(&r->anchor);
    double span = atomic_load(&r->renderSpan);
    int n = atomic_load(&r->rendered);
    if (s != atomic_load(&r->sequence))
      continue;
    if (!n || !isfinite(t))
      return NAN;
    double dt = host - t - latency;
    if (dt > 0.25 || dt < -0.5)
      return NAN;
    // Source-node packets may be rendered ahead of hardware; allow backward
    // interpolation.
    return a + fmin(dt * rate, span);
  }
  return NAN;
}
#ifdef __APPLE__
AudioChannelLayout *pl_clock_audio_layout(const int32_t *ids,
                                          int32_t channels) {
  if (!ids || channels < 1 || channels > 8)
    return NULL;
  AudioChannelLayout *l =
      calloc(1, offsetof(AudioChannelLayout, mChannelDescriptions) +
                    sizeof(AudioChannelDescription) * (size_t)channels);
  if (!l)
    return NULL;
  l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
  l->mNumberChannelDescriptions = channels;
  int side = 0;
  for (int i = 0; i < channels; i++)
    if (ids[i] == 9 || ids[i] == 10)
      side = 1;
  for (int i = 0; i < channels; i++) {
    AudioChannelLabel label;
    switch (ids[i]) {
    case 0:
      label = kAudioChannelLabel_Left;
      break;
    case 1:
      label = kAudioChannelLabel_Right;
      break;
    case 2:
      label =
          channels == 1 ? kAudioChannelLabel_Mono : kAudioChannelLabel_Center;
      break;
    case 3:
      label = kAudioChannelLabel_LFEScreen;
      break;
    case 4:
      label = side ? kAudioChannelLabel_RearSurroundLeft
                   : kAudioChannelLabel_LeftSurround;
      break;
    case 5:
      label = side ? kAudioChannelLabel_RearSurroundRight
                   : kAudioChannelLabel_RightSurround;
      break;
    case 6:
      label = kAudioChannelLabel_LeftCenter;
      break;
    case 7:
      label = kAudioChannelLabel_RightCenter;
      break;
    case 8:
      label = kAudioChannelLabel_CenterSurround;
      break;
    case 9:
      label = kAudioChannelLabel_LeftSurround;
      break;
    case 10:
      label = kAudioChannelLabel_RightSurround;
      break;
    default:
      free(l);
      return NULL;
    }
    l->mChannelDescriptions[i].mChannelLabel = label;
  }
  return l;
}
void pl_clock_free_layout(AudioChannelLayout *l) { free(l); }
int32_t pl_clock_render_abl(PLTimingRing *r, int32_t count,
                            AudioBufferList *out, double host) {
  float *planes[8] = {0};
  if (!r || !out || out->mNumberBuffers != (unsigned)r->channels || count < 0 ||
      count > 65536)
    return 0;
  for (int i = 0; i < r->channels; i++) {
    if (out->mBuffers[i].mNumberChannels != 1 ||
        out->mBuffers[i].mDataByteSize < (unsigned)count * sizeof(float))
      return 0;
    planes[i] = out->mBuffers[i].mData;
  }
  return pl_clock_render(r, count, planes, host);
}
#endif
