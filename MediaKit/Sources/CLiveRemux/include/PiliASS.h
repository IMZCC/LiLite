#ifndef PILI_ASS_H
#define PILI_ASS_H
#include <stddef.h>
#include <stdint.h>
typedef struct PiliASS PiliASS;
typedef struct {
  int x,y,width,height,stride;
  const uint8_t *pixels; /* sRGB premultiplied RGBA8; valid until next call or free */
} PiliASSFrame;
PiliASS *pili_ass_open(const uint8_t *utf8,size_t bytes,const char *local_default_font);
void pili_ass_free(PiliASS *p);
int pili_ass_events(const PiliASS *p);
/* -1 invalid/error, 0 unchanged, 1 changed (NULL pixels = transparent). */
int pili_ass_render(PiliASS *p,int width,int height,int storage_w,int storage_h,int64_t milliseconds,PiliASSFrame *out);
#endif
