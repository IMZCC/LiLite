#include "AudioGain.h"
#ifdef __APPLE__
#include <AudioToolbox/AudioToolbox.h>
#include <stdlib.h>
#include <stdatomic.h>

struct TapState { _Atomic(int32_t) percent; uint32_t kind; };
static void tap_init(MTAudioProcessingTapRef tap, void *info, void **storage) {
    (void)tap;
    struct TapState *s = calloc(1, sizeof(*s));
    if (s) atomic_init(&s->percent, *(int32_t *)info);
    *storage = s;
}
static void tap_finalize(MTAudioProcessingTapRef tap) { free(MTAudioProcessingTapGetStorage(tap)); }
static void tap_prepare(MTAudioProcessingTapRef tap, CMItemCount capacity, const AudioStreamBasicDescription *fmt) {
    (void)capacity;
    struct TapState *s = MTAudioProcessingTapGetStorage(tap);
    if (!s) return;
    s->kind = 0;
    if (!fmt || fmt->mFormatID != kAudioFormatLinearPCM || !fmt->mChannelsPerFrame ||
        (fmt->mFormatFlags & (kAudioFormatFlagIsBigEndian|kAudioFormatFlagIsAlignedHigh))) return;
    const int planar = !!(fmt->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    const uint32_t channels = planar ? 1 : fmt->mChannelsPerFrame;
    if (channels > 64 || fmt->mBytesPerFrame != channels * (fmt->mBitsPerChannel / 8)) return;
    if ((fmt->mFormatFlags & kAudioFormatFlagIsFloat) && fmt->mBitsPerChannel == 32) s->kind = 1;
    else if (fmt->mFormatFlags & kAudioFormatFlagIsSignedInteger) {
        s->kind = fmt->mBitsPerChannel == 16 ? 2 : (fmt->mBitsPerChannel == 32 ? 3 : 0);
    }
}
static void tap_process(MTAudioProcessingTapRef tap, CMItemCount want, MTAudioProcessingTapFlags flags,
                        AudioBufferList *buffers, CMItemCount *frames, MTAudioProcessingTapFlags *out) {
    (void)flags;
    *frames = 0; *out = 0;
    if (MTAudioProcessingTapGetSourceAudio(tap, want, buffers, out, NULL, frames) != noErr || *frames <= 0) return;
    struct TapState *s = MTAudioProcessingTapGetStorage(tap);
    if (!s) return;
    int32_t p = atomic_load_explicit(&s->percent, memory_order_relaxed);
    if (p == 100 || !s->kind) return;
    for (uint32_t i=0; i<buffers->mNumberBuffers; i++) {
        AudioBuffer *b = &buffers->mBuffers[i];
        if (!b->mNumberChannels || b->mNumberChannels > 64 || !b->mData) continue;
        uint32_t n = b->mDataByteSize / (s->kind == 2 ? 2 : 4);
        if ((uint64_t)*frames < (uint64_t)n / b->mNumberChannels + 1) {
            uint64_t samples = (uint64_t)*frames * b->mNumberChannels;
            if (samples < n) n = (uint32_t)samples;
        }
        if (s->kind == 1) pl_gain_float(b->mData, n, p);
        else if (s->kind == 2) pl_gain_int16(b->mData, n, p);
        else pl_gain_int32(b->mData, n, p);
    }
}
MTAudioProcessingTapRef pl_gain_create_tap(int32_t percent) {
    MTAudioProcessingTapCallbacks cb = {.version=kMTAudioProcessingTapCallbacksVersion_0,
        .clientInfo=&percent, .init=tap_init, .finalize=tap_finalize, .prepare=tap_prepare, .process=tap_process};
    MTAudioProcessingTapRef tap = NULL;
    if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) != noErr) {
        return NULL;
    }
    if (!MTAudioProcessingTapGetStorage(tap)) { CFRelease(tap); return NULL; }
    return tap;
}
void pl_gain_set_percent(MTAudioProcessingTapRef tap, int32_t p) {
    struct TapState *s = MTAudioProcessingTapGetStorage(tap);
    if (s) atomic_store_explicit(&s->percent, p < 100 ? 100 : (p > 300 ? 300 : p), memory_order_relaxed);
}
#endif
