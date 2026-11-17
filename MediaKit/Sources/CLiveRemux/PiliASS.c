#include "PiliASS.h"
#include <ass/ass.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <limits.h>

struct PiliASS{ASS_Library *library;ASS_Renderer *renderer;ASS_Track *track;uint8_t *pixels;int w,h,sw,sh;};
static void silent(int level,const char *fmt,va_list args,void *data){(void)level;(void)fmt;(void)args;(void)data;}
void pili_ass_free(PiliASS *p){
 if(!p)return;
 if(p->track)ass_free_track(p->track);
 if(p->renderer)ass_renderer_done(p->renderer);
 if(p->library)ass_library_done(p->library);
 free(p->pixels);free(p);
}
int pili_ass_events(const PiliASS*p){return p&&p->track?p->track->n_events:0;}
PiliASS *pili_ass_open(const uint8_t *text,size_t n,const char *font){
 if(!text||!n||n>8u*1024*1024)return NULL;
 PiliASS*p=calloc(1,sizeof(*p));if(!p)return NULL;
 p->library=ass_library_init();if(!p->library)goto fail;
 ass_set_message_cb(p->library,silent,NULL);
 // Font attachments are never written to a directory; libass may select embedded fonts in memory.
 ass_set_extract_fonts(p->library,1);
 p->renderer=ass_renderer_init(p->library);if(!p->renderer)goto fail;
 ass_set_cache_limits(p->renderer,384,12);
 ass_set_fonts(p->renderer,font,"Helvetica",font?ASS_FONTPROVIDER_NONE:ASS_FONTPROVIDER_AUTODETECT,NULL,0);
 char*buf=malloc(n+1);if(!buf)goto fail;memcpy(buf,text,n);buf[n]=0;
 p->track=ass_read_memory(p->library,buf,n,"UTF-8");free(buf);
 if(!p->track||p->track->n_events<1||p->track->n_events>50000)goto fail;
 return p;
fail:pili_ass_free(p);return NULL;
}
int pili_ass_render(PiliASS*p,int w,int h,int sw,int sh,int64_t ms,PiliASSFrame*out){
 if(!p||!out||w<1||h<1||w>4096||h>4096||(int64_t)w*h>2304000||ms<0||ms>31536000000LL)return -1;
 *out=(PiliASSFrame){0};if(sw<1||sh<1||sw>32768||sh>32768){sw=w;sh=h;}
 int resize=p->w!=w||p->h!=h||sw!=p->sw||sh!=p->sh;
 if(resize){ass_set_frame_size(p->renderer,w,h);ass_set_storage_size(p->renderer,sw,sh);p->w=w;p->h=h;p->sw=sw;p->sh=sh;}
 int changed=0;ASS_Image *head=ass_render_frame(p->renderer,p->track,ms,&changed);
 if(!changed&&!resize)return 0;
 int x0=w,y0=h,x1=0,y1=0,items=0;
 for(ASS_Image*i=head;i;i=i->next){
  if(++items>16384)return -1;
  if(!i->bitmap||i->w<=0||i->h<=0||(i->color&255)==255)continue;
  if(i->dst_x<0||i->dst_y<0||i->dst_x>w||i->dst_y>h||i->w>w-i->dst_x||i->h>h-i->dst_y||i->stride<i->w)return -1;
  if(i->dst_x<x0)x0=i->dst_x;if(i->dst_y<y0)y0=i->dst_y;
  if(i->dst_x+i->w>x1)x1=i->dst_x+i->w;if(i->dst_y+i->h>y1)y1=i->dst_y+i->h;
 }
 free(p->pixels);p->pixels=NULL;
 if(x1<=x0||y1<=y0)return 1;
 int width=x1-x0,height=y1-y0,stride=width*4;
 uint8_t*dst=calloc(height,(size_t)stride);if(!dst)return -1;p->pixels=dst;
 for(ASS_Image*i=head;i;i=i->next){
  uint32_t color=i->color;unsigned opacity=255-(color&255);
  if(!opacity||!i->bitmap||i->w<=0||i->h<=0)continue;
  unsigned channels[3]={color>>24,(color>>16)&255,(color>>8)&255};
  for(int y=0;y<i->h;y++){
   const uint8_t *src=i->bitmap+(size_t)y*i->stride;uint8_t *q=dst+(size_t)(i->dst_y-y0+y)*stride+(i->dst_x-x0)*4;
   for(int x=0;x<i->w;x++,q+=4){unsigned a=(src[x]*opacity+127)/255;if(!a)continue;
    for(int k=0;k<3;k++)q[k]=(channels[k]*a+q[k]*(255-a)+127)/255;
    q[3]=a+(q[3]*(255-a)+127)/255;
   }
  }
 }
 *out=(PiliASSFrame){x0,y0,width,height,stride,dst};return 1;
}
