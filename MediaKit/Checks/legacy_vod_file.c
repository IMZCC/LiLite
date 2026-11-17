#include "CLiveRemux.h"
#include <stdio.h>
#include <stdlib.h>
typedef struct { int count, limit; } State;
static int32_t cancelled(void *raw) {
    State *s = raw;
    return s->limit >= 0 && ++s->count > s->limit;
}
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    State state = {0, argc > 3 ? atoi(argv[3]) : -1};
    char error[128];
    int status = pl_vod_remux_file(argv[1], argv[2], &state, cancelled, error, sizeof(error));
    if (status < 0) { fprintf(stderr, "%s\n", error); return 1; }
    return 0;
}
