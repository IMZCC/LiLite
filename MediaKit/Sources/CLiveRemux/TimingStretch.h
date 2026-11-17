// Bounded waveform-similarity overlap-add, operating directly on the source
// ring. All channels use the same analysis offset to preserve their relative
// phase. Scratch is allocated at creation.
static inline float sample_at(PLTimingRing *r, double position, int ch,
                              int64_t end) {
  int64_t a = (int64_t)position, b = a + 1 < end ? a + 1 : a;
  size_t x = (size_t)(a % r->capacity) * r->channels + ch,
         y = (size_t)(b % r->capacity) * r->channels + ch;
  double v = r->data[x];
  return (float)((v + ((double)r->data[y] - v) * (position - a)) /
                 2147483648.0);
}
static int make_hop(PLTimingRing *r, double pos, int64_t end, double ratio,
                    double tempo) {
  const int n = r->hop, k = r->channels, window = r->rate / 200;
  int64_t centre = (int64_t)pos, lo = centre - window, hi = centre + window;
  if (lo < r->historyFloor)
    lo = r->historyFloor;
  int64_t last = end - (int64_t)ceil(2 * n * ratio) - 1;
  if (hi > last)
    hi = last;
  // Do not consume the next logical position before it has been published.
  if (hi < lo || pos + n * tempo * ratio > end)
    return 0;
  int64_t best = centre < lo ? lo : centre > hi ? hi : centre;
  float *tail = r->overlap, *out = r->work;
  if (r->has_tail) {
    int ds = r->rate / 6000;
    if (ds < 1)
      ds = 1;
    int stride = r->rate / 24000;
    if (stride < 1)
      stride = 1;
    int guide = 0;
    double maxenergy = 0;
    for (int c = 0; c < k; c++) {
      double e = 0;
      for (int j = 0; j < n; j += ds) {
        double v = tail[j * k + c];
        e += v * v;
      }
      if (e > maxenergy) {
        maxenergy = e;
        guide = c;
      }
    }
    if (maxenergy > 1e-13) {
      double maximum = -2;
      for (int64_t a = lo; a <= hi; a += stride) {
        double xy = 0, yy = 0;
        for (int j = 0; j < n; j += ds) {
          double v = sample_at(r, a + j * ratio, guide, end);
          xy += tail[j * k + guide] * v;
          yy += v * v;
        }
        if (yy < 1e-14)
          continue;
        double score = xy / sqrt(maxenergy * yy) -
                       0.001 * fabs((double)(a - centre)) / (window + 1);
        if (score > maximum) {
          maximum = score;
          best = a;
        }
      }
    }
  }
  for (int j = 0; j < n; j++) {
    float w = (float)(j + 1) / (float)n;
    for (int c = 0; c < k; c++) {
      float v = sample_at(r, best + j * ratio, c, end);
      out[j * k + c] =
          r->has_tail ? tail[j * k + c] + w * (v - tail[j * k + c]) : v;
      tail[j * k + c] = sample_at(r, best + (j + n) * ratio, c, end);
    }
  }
  r->has_tail = 1;
  r->in_hop = 0;
  r->hop_rate = tempo * ratio;
  return 1;
}
