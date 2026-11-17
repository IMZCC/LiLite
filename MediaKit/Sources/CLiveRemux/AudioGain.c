#include "AudioGain.h"
#include <limits.h>
#include <math.h>

static int32_t valid(int32_t v) { return v < 100 ? 100 : (v > 300 ? 300 : v); }

void pl_gain_float(float *a, uint32_t n, int32_t p) {
    p = valid(p);
    if (!a || p == 100) return;
    const float gain = (float)p / 100.0f;
    for (uint32_t i=0; i<n; i++) {
        float x = a[i] * gain;
        a[i] = isnan(x) ? 0 : (x > 1 ? 1 : (x < -1 ? -1 : x));
    }
}
void pl_gain_int16(int16_t *a, uint32_t n, int32_t p) {
    p = valid(p);
    if (!a || p == 100) return;
    for (uint32_t i=0; i<n; i++) {
        int32_t x = a[i] * p / 100;
        a[i] = x > INT16_MAX ? INT16_MAX : (x < INT16_MIN ? INT16_MIN : (int16_t)x);
    }
}
void pl_gain_int32(int32_t *a, uint32_t n, int32_t p) {
    p = valid(p);
    if (!a || p == 100) return;
    for (uint32_t i=0; i<n; i++) {
        int64_t x = (int64_t)a[i] * p / 100;
        a[i] = x > INT32_MAX ? INT32_MAX : (x < INT32_MIN ? INT32_MIN : (int32_t)x);
    }
}
