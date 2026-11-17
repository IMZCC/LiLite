#include "PiliMPV.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static double number(mpv_handle *p, const char *name) {
    double value = 0;
    assert(mpv_get_property(p, name, MPV_FORMAT_DOUBLE, &value) >= 0);
    return value;
}
static int flag(mpv_handle *p, const char *name) {
    int value = 0;
    assert(mpv_get_property(p, name, MPV_FORMAT_FLAG, &value) >= 0);
    return value;
}
static void wait_event(mpv_handle *p, mpv_event_id wanted) {
    for (int i = 0; i < 300; ++i) {
        mpv_event *e = mpv_wait_event(p, 0.05);
        if (e->event_id == wanted) return;
        if (e->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = e->data;
            if (end->reason == MPV_END_FILE_REASON_ERROR) {
                fprintf(stderr,"mpv load error: %s\n",mpv_error_string(end->error));
                abort();
            }
        }
    }
    fprintf(stderr,"timed out waiting for event %d\n", wanted);
    abort();
}
static void drain(mpv_handle *p) { while(mpv_wait_event(p,0)->event_id != MPV_EVENT_NONE) {} }
static void command(mpv_handle *p, const char *a, const char *b, const char *c) {
    const char *args[] = {a,b,c,NULL};
    assert(pili_mpv_command(p,args) >= 0);
}
int main(int argc, char **argv) {
    assert(argc == 3);
    mpv_handle *p = mpv_create(); assert(p);
    const char *options[][2] = {{"config","no"},{"terminal","no"},{"vo","null"},{"ao","null"},
      {"idle","yes"},{"keep-open","yes"},{"audio-pitch-correction","yes"}};
    for(size_t i=0;i<sizeof(options)/sizeof(options[0]);i++) assert(mpv_set_option_string(p,options[i][0],options[i][1])>=0);
    assert(mpv_initialize(p)>=0);
    const char *properties[]={"time-pos","duration","speed","demuxer-cache-time"};
    for(size_t i=0;i<4;i++) assert(mpv_observe_property(p,i+1,properties[i],MPV_FORMAT_DOUBLE)>=0);
    int load = pili_mpv_load(p,argv[1],argv[2],"https://www.bilibili.com/","Mozilla/5.0 CMPV check",1.5,1);
    if(load<0) fprintf(stderr,"CMPV load failed: %s\n",mpv_error_string(load));
    assert(load>=0);
    wait_event(p,MPV_EVENT_FILE_LOADED);
    wait_event(p,MPV_EVENT_PLAYBACK_RESTART);
    assert(fabs(number(p,"duration")-12)<0.2);
    assert(number(p,"track-list/count")==2);
    assert(number(p,"aid")>0);
    assert(flag(p,"pause"));
    fprintf(stderr,"loaded start=%.6f duration=%.6f\n",number(p,"time-pos"),number(p,"duration"));
    assert(fabs(number(p,"time-pos")-1.5)<0.2);
    drain(p);
    command(p,"seek","2.5","absolute+exact");
    wait_event(p,MPV_EVENT_PLAYBACK_RESTART);
    assert(fabs(number(p,"time-pos")-2.5)<0.2);
    assert(mpv_set_property_string(p,"speed","3")>=0);
    assert(mpv_set_property_string(p,"pause","no")>=0);
    usleep(200000);
    double before=number(p,"time-pos");
    usleep(800000);
    double advanced=number(p,"time-pos")-before;
    assert(advanced>1.8 && advanced<3.0);
    assert(mpv_set_property_string(p,"pause","yes")>=0);
    before=number(p,"time-pos");
    usleep(300000);
    assert(fabs(number(p,"time-pos")-before)<0.2);
    drain(p);
    command(p,"seek","10.5","absolute+exact");
    wait_event(p,MPV_EVENT_PLAYBACK_RESTART);
    assert(mpv_set_property_string(p,"pause","no")>=0);
    for(int i=0;i<60 && !flag(p,"eof-reached");i++) usleep(50000);
    assert(flag(p,"eof-reached"));
    for(int i=0;i<8;i++) {
        command(p,"stop",NULL,NULL); drain(p);
        assert(pili_mpv_load(p,argv[1],NULL,"https://www.bilibili.com/","Mozilla/5.0 CMPV check",0.25,1)>=0);
        wait_event(p,MPV_EVENT_FILE_LOADED);
        wait_event(p,MPV_EVENT_PLAYBACK_RESTART);
        assert(number(p,"track-list/count")==1);
        assert(fabs(number(p,"time-pos")-0.25)<0.2);
    }
    mpv_terminate_destroy(p);
    printf("{\"dash_audio_tracks\":2,\"start\":1.5,\"seek\":2.5,\"speed\":3,\"media_advance_in_0_8s\":%.3f,\"pause\":true,\"eof\":true,\"reload_without_stale_audio\":8}\n",advanced);
}
