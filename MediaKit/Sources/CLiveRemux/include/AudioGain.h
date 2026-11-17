#ifndef PILI_AUDIO_GAIN_H
#define PILI_AUDIO_GAIN_H
#include <stdint.h>
#ifdef __APPLE__
#include <MediaToolbox/MTAudioProcessingTap.h>
#endif
#ifdef __cplusplus
extern "C" {
#endif
#ifdef __clang__
#define PL_GAIN_NULLABLE _Nullable
#else
#define PL_GAIN_NULLABLE
#endif
void pl_gain_float(float * PL_GAIN_NULLABLE samples, uint32_t count, int32_t percent);
void pl_gain_int16(int16_t * PL_GAIN_NULLABLE samples, uint32_t count, int32_t percent);
void pl_gain_int32(int32_t * PL_GAIN_NULLABLE samples, uint32_t count, int32_t percent);
#undef PL_GAIN_NULLABLE
#ifdef __APPLE__
MTAudioProcessingTapRef _Nullable pl_gain_create_tap(int32_t percent) CF_RETURNS_RETAINED;
void pl_gain_set_percent(MTAudioProcessingTapRef _Nonnull tap, int32_t percent);
#endif
#ifdef __cplusplus
}
#endif
#endif
