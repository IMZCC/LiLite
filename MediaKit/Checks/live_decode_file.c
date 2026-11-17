#include "LiveDecoder.h"
#include <stdio.h>
#include <stdlib.h>
typedef struct {
  FILE *f;
  long left;
  int ended;
} Source;
static int32_t pull(void *v, uint8_t *dst, int32_t n) {
  Source *s = v;
  if (n > 311)
    n = 311;
  if (s->left >= 0 && n > s->left)
    n = (int)s->left;
  if (!n) {
    s->ended = 1;
    return -1;
  }
  int got = (int)fread(dst, 1, n, s->f);
  if (s->left >= 0)
    s->left -= got;
  return got ? got : ferror(s->f) ? -1 : 0;
}
static int32_t stop(void *v) { return ((Source *)v)->ended; }
int main(int argc, char **argv) {
  if (argc != 6 && argc != 7 && argc != 10 && argc != 11)
    return 2;
  FILE *f = fopen(argv[1], "rb");
  if (!f)
    return 2;
  Source s = {f, strtol(argv[5], NULL, 10), 0};
  PLLiveVideoStats stats = {0};
  char error[128] = {0};
  int rc;
  if (argc >= 10) {
    FILE *af = fopen(argv[7], "rb");
    if (!af) {
      fclose(f);
      return 2;
    }
    Source a = {af, -1, 0};
    rc = pl_live_decode_pair(
        &s, &a, pull, stop, atoi(argv[8]), strtoll(argv[9], NULL, 10),
        argc == 11 ? strtoll(argv[10], NULL, 10) : -1, argv[2], atoi(argv[6]),
        atoi(argv[3]), atoi(argv[4]), 3840 * 2160, &stats, error,
        sizeof(error));
    fclose(af);
  } else
    rc = pl_live_decode_stream(
        &s, pull, stop, argv[2], argc == 7 ? atoi(argv[6]) : 0, atoi(argv[3]),
        atoi(argv[4]), 3840 * 2160, &stats, error, sizeof(error));
  fclose(f);
  if (rc < 0) {
    fprintf(stderr, "live decoder: %s\n", error);
    return 1;
  }
  printf("%lld %lld %lld %lld %d %d %d\n", (long long)stats.frames,
         (long long)stats.first_us, (long long)stats.last_us,
         (long long)stats.audio_packets, stats.width, stats.height,
         stats.hardware_copy);
  return 0;
}
