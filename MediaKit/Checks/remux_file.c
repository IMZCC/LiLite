#include "CLiveRemux.h"
#include <stdio.h>
#include <stdlib.h>
typedef struct { FILE *file; long remaining; int cancelled; } Feed;
static int32_t pull(void *ctx,uint8_t *dst,int32_t length) {
    Feed *s=ctx;
    /* Exercise short input callbacks, even when a tag crosses a read boundary. */
    if(length>197)length=197;
    if(s->remaining>=0 && s->remaining<length)length=(int)s->remaining;
    if(!length){s->cancelled=1;return -1;}
    int n=(int)fread(dst,1,(size_t)length,s->file);if(s->remaining>=0)s->remaining-=n;
    return n ? n : ferror(s->file)?-1:0;
}
static int32_t stopped(void *ctx){return ((Feed*)ctx)->cancelled;}
int main(int argc,char **argv){
    if(argc<3 || argc>4)return 2;
    FILE *file=fopen(argv[1],"rb");if(!file)return 2;
    Feed s={file,argc==4?strtol(argv[3],NULL,10):-1,0};
    char error[160]={0};int result=pl_live_remux(&s,pull,stopped,argv[2],error,sizeof(error));fclose(file);
    if(result<0){fprintf(stderr,"remux: %s\n",error);return 1;}return 0;
}
