#include "SoftVideo.h"
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/hwcontext.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/time.h>
#include <libswscale/swscale.h>

#define MB (1024*1024)
typedef struct {
    const uint8_t *init,*media; int i,m; int64_t base,pos,total,readbytes,target;
    uint8_t pad[16]; int padlen;
    void *ctx; PLDecodeCancelled cancel; int64_t deadline;
} Src;
static int halted(void *v) {
    Src *s=v;
    return (s->cancel && s->cancel(s->ctx)) || av_gettime_relative()>s->deadline;
}
static int read_mem(void *v,uint8_t *dst,int n) {
    Src *s=v;
    if(halted(s))return AVERROR_EXIT;
    if(n<=0 || s->pos>=s->total)return AVERROR_EOF;
    if(s->readbytes>4LL*(s->m+s->i)+8*MB)return AVERROR_INVALIDDATA;
    int64_t at=s->pos, take=n;
    if(at<s->i) { take=FFMIN(take,s->i-at); memcpy(dst,s->init+at,take); }
    else if(at<s->base) {
        take=FFMIN(take,s->base-at); memset(dst,0,take);
        int64_t j=at-s->i;
        if(j<s->padlen)memcpy(dst,s->pad+j,FFMIN(take,s->padlen-j));
    } else { take=FFMIN(take,s->total-at); memcpy(dst,s->media+(at-s->base),take); }
    s->pos+=take;s->readbytes+=take;return (int)take;
}
static int64_t seek_mem(void *v,int64_t offset,int whence) {
    Src *s=v; whence&=~AVSEEK_FORCE;
    if(whence==AVSEEK_SIZE)return s->total;
    int64_t base=whence==SEEK_SET?0:whence==SEEK_CUR?s->pos:whence==SEEK_END?s->total:-1;
    if(base<0 || offset < -base || offset>s->total-base)return AVERROR(EINVAL);
    return s->pos=base+offset;
}
static int reject_external(AVFormatContext *s,AVIOContext **p,const char *u,int fl,AVDictionary **o) {
    (void)s;(void)p;(void)u;(void)fl;(void)o;return AVERROR(EPERM);
}
static void put_u64(uint8_t *p,uint64_t value,int n) {
    for(int i=n-1;i>=0;i--){p[i]=value&255;value>>=8;}
}
typedef struct {
    uint8_t *bytes; int len,cap; Src *src;
} Output;
static int write_mem(void *v,const uint8_t *p,int n) {
    Output *o=v;
    if(halted(o->src))return AVERROR_EXIT;
    if(n<0 || n>48*MB-o->len)return AVERROR(ENOSPC);
    if(o->len+n>o->cap) {
        int cap=FFMIN(48*MB, FFMAX(o->len+n,FFMAX(65536,o->cap*2)));
        uint8_t *b=av_realloc(o->bytes,cap);
        if(!b)return AVERROR(ENOMEM);
        o->cap=cap;o->bytes=b;
    }
    memcpy(o->bytes+o->len,p,n);o->len+=n;return n;
}
static enum AVPixelFormat vt_format(AVCodecContext *ctx,const enum AVPixelFormat *fmts) {
    (void)ctx;
    for(;*fmts!=AV_PIX_FMT_NONE;fmts++)if(*fmts==AV_PIX_FMT_VIDEOTOOLBOX)return *fmts;
    return AV_PIX_FMT_NONE;
}
typedef struct {
    AVFormatContext *in,*out; AVCodecContext *dec,*enc; AVIOContext *io,*oio;
    AVPacket *pkt,*epkt; AVFrame *frame,*converted,*copied; struct SwsContext *scale;
    AVStream *is,*os; AVRational fps; Src src; Output dst;
    int limit,encode,preroll,hdr; PLFrameSink sink; PLDecodedVideo *stats;
} Proc;
static uint32_t read32(const uint8_t *b) {
    return (uint32_t)b[0]<<24|(uint32_t)b[1]<<16|(uint32_t)b[2]<<8|b[3];
}
static int set_clock(uint8_t *p,int size,uint64_t ticks,int depth) {
    int count=0;
    for(int i=0;i<size;){
        if(size-i<8)return -1;
        uint32_t length=read32(p+i);
        if(length<8 || length>(uint32_t)(size-i))return -1;
        uint8_t *box=p+i;
        if(depth==2 && !memcmp(box+4,"tfdt",4)){
            if(length<16 || box[8]>1 || (box[8]==1 && length<20) || (!box[8] && ticks>UINT32_MAX))return -1;
            put_u64(box+12,ticks,box[8]?8:4);count++;
        } else if((depth==0 && !memcmp(box+4,"moof",4)) || (depth==1 && !memcmp(box+4,"traf",4))){
            int n=set_clock(box+8,(int)length-8,ticks,depth+1);
            if(n<0)return -1;
            count+=n;
        }
        i+=(int)length;
    }
    return count;
}
static int start_enc(Proc *p,const AVFrame *f) {
    int ret=0;
#if defined(__APPLE__) && TARGET_OS_IOS
    const AVCodec *encoder=avcodec_find_encoder_by_name(p->hdr?"hevc_videotoolbox":"h264_videotoolbox");
#else
    const AVCodec *encoder=avcodec_find_encoder(AV_CODEC_ID_MPEG2VIDEO);
#endif
    if(!encoder)return AVERROR_ENCODER_NOT_FOUND;
    p->enc=avcodec_alloc_context3(encoder);
    if(!p->enc)return AVERROR(ENOMEM);
    AVCodecContext *e=p->enc;
    e->width=f->width; e->height=f->height; e->pix_fmt=p->hdr?AV_PIX_FMT_P010LE:AV_PIX_FMT_YUV420P;
    e->sample_aspect_ratio=f->sample_aspect_ratio;
    e->color_range=f->color_range;e->colorspace=f->colorspace;e->color_trc=f->color_trc;e->color_primaries=f->color_primaries;
    e->framerate=p->fps; e->max_b_frames=0; e->gop_size=240; e->thread_count=2;
    e->bit_rate=FFMAX(450000,FFMIN(35000000,(int64_t)e->width*e->height*6));
#if defined(__APPLE__) && TARGET_OS_IOS
    e->time_base=(AVRational){1,90000};e->profile=p->hdr?AV_PROFILE_HEVC_MAIN_10:AV_PROFILE_H264_MAIN;
    av_opt_set(e->priv_data,"allow_sw","1",0);av_opt_set(e->priv_data,"realtime","1",0);
#else
    // A Linux test encoder for mux/time-base validation. It is not enabled for iOS targets.
    e->time_base=av_inv_q(e->framerate);
#endif
    if(p->encode==2)e->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if((ret=avcodec_open2(e,encoder,NULL))<0)return ret;
    if((ret=avformat_alloc_output_context2(&p->out,NULL,p->encode==2?"mp4":"mpegts",NULL))<0)return ret;
    p->out->flags |= AVFMT_FLAG_CUSTOM_IO;p->out->max_delay=0;p->out->avoid_negative_ts=AVFMT_AVOID_NEG_TS_DISABLED;
    p->os=avformat_new_stream(p->out,NULL);if(!p->os)return AVERROR(ENOMEM);
    p->os->time_base=(AVRational){1,90000};
    if((ret=avcodec_parameters_from_context(p->os->codecpar,e))<0)return ret;
    if(p->hdr) {
        p->os->codecpar->codec_tag=MKTAG('h','v','c','1');
        const enum AVFrameSideDataType ftypes[]={AV_FRAME_DATA_MASTERING_DISPLAY_METADATA,AV_FRAME_DATA_CONTENT_LIGHT_LEVEL};
        const enum AVPacketSideDataType ptypes[]={AV_PKT_DATA_MASTERING_DISPLAY_METADATA,AV_PKT_DATA_CONTENT_LIGHT_LEVEL};
        for(unsigned i=0;i<2;i++){
            const AVFrameSideData *fs=av_frame_get_side_data(f,ftypes[i]);
            const AVPacketSideData *ps=av_packet_side_data_get(p->is->codecpar->coded_side_data,p->is->codecpar->nb_coded_side_data,ptypes[i]);
            const uint8_t *data=fs?fs->data:ps?ps->data:NULL;
            size_t size=fs?fs->size:ps?ps->size:0;
            if(data && size && size<65536){
                AVPacketSideData *copy=av_packet_side_data_new(&p->os->codecpar->coded_side_data,&p->os->codecpar->nb_coded_side_data,ptypes[i],size,0);
                if(!copy)return AVERROR(ENOMEM);
                memcpy(copy->data,data,size);
            }
        }
    }
    uint8_t *b=av_malloc(32768);if(!b)return AVERROR(ENOMEM);
    p->oio=avio_alloc_context(b,32768,1,&p->dst,NULL,write_mem,NULL);
    if(!p->oio){av_free(b);return AVERROR(ENOMEM);}
    p->out->pb=p->oio;
    if(p->encode==2) {
        av_opt_set(p->out->priv_data,"movflags","empty_moov+frag_custom+default_base_moof+skip_trailer",0);
        av_opt_set(p->out->priv_data,"video_track_timescale","90000",0);
        av_opt_set(p->out->priv_data,"use_editlist","0",0);
    } else {
        av_opt_set(p->out->priv_data,"mpegts_copyts","1",0);
        av_opt_set(p->out->priv_data,"mpegts_flags","resend_headers",0);
    }
    return avformat_write_header(p->out,NULL);
}
static int encode_frame(Proc *p,AVFrame *f) {
    int ret=avcodec_send_frame(p->enc,f);
    if(ret<0)return ret;
    while((ret=avcodec_receive_packet(p->enc,p->epkt))>=0) {
        if(halted(&p->src))return AVERROR_EXIT;
        if(p->encode==2 && p->epkt->pts!=AV_NOPTS_VALUE)p->epkt->dts=p->epkt->pts; // No B frames: decode order == presentation order.
        av_packet_rescale_ts(p->epkt,p->enc->time_base,p->os->time_base);
        p->epkt->stream_index=p->os->index;
        ret=av_interleaved_write_frame(p->out,p->epkt);
        av_packet_unref(p->epkt);
        if(ret<0)return ret;
    }
    return (ret==AVERROR(EAGAIN)||ret==AVERROR_EOF)?0:ret;
}
static int consume(Proc *p) {
    AVFrame *f=p->frame;
    if(p->preroll && (!f->opaque_ref || f->opaque_ref->size!=1))return AVERROR_INVALIDDATA;
    if(p->preroll && !f->opaque_ref->data[0])return 0;
    if(halted(&p->src))return AVERROR_EXIT;
    if(f->flags&AV_FRAME_FLAG_CORRUPT || f->decode_error_flags || f->width<=0 || f->height<=0 ||
       (int64_t)f->width*f->height>p->limit || p->stats->frames>=4096)return AVERROR_INVALIDDATA;
    int64_t pts=f->best_effort_timestamp;
    if(pts==AV_NOPTS_VALUE)pts=f->pts;
    if(pts==AV_NOPTS_VALUE)return AVERROR_INVALIDDATA;
    int hdr=f->color_trc==AVCOL_TRC_SMPTE2084||f->color_trc==AVCOL_TRC_ARIB_STD_B67;
    if(p->stats->frames && p->hdr!=hdr)return AVERROR_INVALIDDATA;
    p->hdr=hdr;
    if(hdr && p->encode==1)return AVERROR(ENOTSUP);
#if !defined(__APPLE__) || !TARGET_OS_IOS
    if(hdr && p->encode)return AVERROR(ENOTSUP); // host's MPEG2 fixture encoder is 8-bit
#endif
    if(f->format==AV_PIX_FMT_VIDEOTOOLBOX) {
        av_frame_unref(p->copied);
        int r=av_hwframe_transfer_data(p->copied,f,0); if(r<0)return r;
        r=av_frame_copy_props(p->copied,f); if(r<0)return r;
        f=p->copied;
    }
    if(!p->converted) {
        p->converted=av_frame_alloc();if(!p->converted)return AVERROR(ENOMEM);
        p->converted->format=p->hdr?AV_PIX_FMT_P010LE:AV_PIX_FMT_YUV420P;p->converted->width=f->width;p->converted->height=f->height;
        int ret=av_frame_get_buffer(p->converted,32);if(ret<0)return ret;
    }
    AVFrame *c=p->converted;
    if(c->width!=f->width || c->height!=f->height)return AVERROR_INVALIDDATA;
    int r=av_frame_make_writable(c);if(r<0)return r;
    p->scale=sws_getCachedContext(p->scale,f->width,f->height,f->format,f->width,f->height,
                                  c->format,SWS_BILINEAR,NULL,NULL,NULL);
    if(!p->scale)return AVERROR(ENOMEM);
    if(sws_scale(p->scale,(const uint8_t *const *)f->data,f->linesize,0,f->height,c->data,c->linesize)!=f->height)return AVERROR_INVALIDDATA;
    int64_t us=av_rescale_q(pts,p->is->time_base,AV_TIME_BASE_Q);
    if(p->stats->frames && us<p->stats->last_us)return AVERROR_INVALIDDATA;
    if(!p->stats->frames){p->stats->first_us=us;p->stats->width=f->width;p->stats->height=f->height;p->stats->transfer=f->color_trc;}
    p->stats->last_us=us;
    if(p->sink && p->sink(p->src.ctx,c->width,c->height,us,c->data[0],c->linesize[0],
                          c->data[1],c->linesize[1],c->data[2],c->linesize[2],p->hdr))return AVERROR_EXIT;
    if(p->encode) {
        if(!p->enc) {
            if(f->duration>0 && (double)p->is->time_base.den / ((double)p->is->time_base.num*f->duration) <= 240
              && f->duration<INT_MAX && p->is->time_base.num>0) {
                AVRational guess;
                av_reduce(&guess.num,&guess.den,p->is->time_base.den,(int64_t)p->is->time_base.num*f->duration,1000000);
                if(av_q2d(guess)>=1.0)p->fps=guess;
            }
            if((r=start_enc(p,f))<0)return r;
        }
        c->pts=av_rescale_q(pts,p->is->time_base,p->enc->time_base);
        c->duration=FFMAX(1,av_rescale_q(f->duration,p->is->time_base,p->enc->time_base));
        c->pict_type=p->stats->frames?AV_PICTURE_TYPE_NONE:AV_PICTURE_TYPE_I;
        if((r=encode_frame(p,c))<0)return r;
    }
    p->stats->frames++; return 0;
}
static int decode_packet(Proc *p,const AVPacket *pkt) {
    int ret=avcodec_send_packet(p->dec,pkt); if(ret<0)return ret;
    while((ret=avcodec_receive_frame(p->dec,p->frame))>=0) {
        ret=consume(p); av_frame_unref(p->frame);if(ret<0)return ret;
    }
    return (ret==AVERROR(EAGAIN)||ret==AVERROR_EOF)?0:ret;
}
void pl_free_video(uint8_t *d) { av_free(d); }
int32_t pl_decode_video(const uint8_t *init,int32_t isize,const uint8_t *media,int32_t msize,
    int64_t offset,int64_t target,int32_t mode,int32_t limit,int32_t encode,void *ctx,
    PLDecodeCancelled cancel,PLFrameSink cb,PLDecodedVideo *st,uint8_t **output,int32_t *outsize,
    char *err,int32_t errlen) {
    int ret=AVERROR(EINVAL),index=-1,packets=0; AVBufferRef *hw=NULL; AVDictionary *opts=NULL;
    Proc p={0};
    if(err && errlen>0)err[0]=0;
    if(output)*output=NULL;if(outsize)*outsize=0;if(st)memset(st,0,sizeof(*st));
    if(!init || !media || !st || !output || !outsize || isize<8 || isize>4*MB || msize<8 ||
       msize>48*MB || offset<isize || offset>512LL*1024*MB || target<offset ||
       target>=offset+msize || limit<1 || limit>8192*4608 || (mode!=PL_SOFTWARE && mode!=PL_VT_COPY))goto done;
    Src *s=&p.src;
    s->init=init;s->media=media;s->i=isize;s->m=msize;s->base=offset;s->ctx=ctx;s->cancel=cancel;s->deadline=av_gettime_relative()+45000000;
    if(halted(s)){ret=AVERROR_EXIT;goto done;}
    int64_t gap=offset-isize;
    if(gap>0 && gap<8){s->base=isize;}
    else if(gap) {
        s->padlen=gap>UINT32_MAX?16:8;put_u64(s->pad,gap>UINT32_MAX?1:(uint64_t)gap,4);
        memcpy(s->pad+4,"free",4);if(gap>UINT32_MAX)put_u64(s->pad+8,(uint64_t)gap,8);
    }
    s->total=s->base+msize;s->target=s->base+(target-offset);p.preroll=target!=offset;
    p.limit=limit;p.encode=encode;p.stats=st;p.dst.src=s;p.sink=cb;
    p.in=avformat_alloc_context(); if(!p.in){ret=AVERROR(ENOMEM);goto done;}
    uint8_t *buf=av_malloc(32768);if(!buf){ret=AVERROR(ENOMEM);goto done;}
    p.io=avio_alloc_context(buf,32768,0,s,read_mem,NULL,seek_mem);
    if(!p.io){av_free(buf);ret=AVERROR(ENOMEM);goto done;}
    p.in->pb=p.io;p.in->flags|=AVFMT_FLAG_CUSTOM_IO;p.in->max_streams=8;p.in->probesize=2*MB;
    p.in->interrupt_callback=(AVIOInterruptCB){halted,s};p.in->io_open=reject_external;
    av_dict_set(&opts,"enable_drefs","0",0); av_dict_set(&opts,"use_absolute_path","0",0);
    const AVInputFormat *mov=av_find_input_format("mov");if(!mov){ret=AVERROR_DEMUXER_NOT_FOUND;goto done;}
    if((ret=avformat_open_input(&p.in,NULL,mov,&opts))<0)goto done;
    for(unsigned i=0;i<p.in->nb_streams;i++)if(p.in->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_VIDEO){index=(int)i;break;}
    if(index<0){ret=AVERROR_STREAM_NOT_FOUND;goto done;}
    p.is=p.in->streams[index];AVCodecParameters *par=p.is->codecpar;
    if(par->codec_tag==MKTAG('e','n','c','v') || av_packet_side_data_get(par->coded_side_data,par->nb_coded_side_data,AV_PKT_DATA_ENCRYPTION_INIT_INFO)){ret=AVERROR(EPERM);goto done;}
    const char *name=NULL;
    switch(par->codec_id){case AV_CODEC_ID_H264:name="h264";break;case AV_CODEC_ID_HEVC:name="hevc";break;
      case AV_CODEC_ID_VP9:name="vp9";break;case AV_CODEC_ID_AV1:name=mode==PL_SOFTWARE?"libdav1d":"av1";break;
      default:ret=AVERROR_DECODER_NOT_FOUND;goto done;}
    const AVCodec *codec=avcodec_find_decoder_by_name(name);
    if(!codec){ret=AVERROR_DECODER_NOT_FOUND;goto done;}
    p.dec=avcodec_alloc_context3(codec);
    if(!p.dec){ret=AVERROR(ENOMEM);goto done;}
    if((ret=avcodec_parameters_to_context(p.dec,par))<0)goto done;
    if(par->width<=0 || par->height<=0 || (int64_t)par->width*par->height>limit){ret=AVERROR(EFBIG);goto done;}
    p.dec->pkt_timebase=p.is->time_base;p.dec->thread_count=2;p.dec->max_pixels=limit;
    p.dec->err_recognition|=AV_EF_EXPLODE;p.dec->flags|=AV_CODEC_FLAG_COPY_OPAQUE;
    if(mode==PL_VT_COPY){
        if((ret=av_hwdevice_ctx_create(&hw,AV_HWDEVICE_TYPE_VIDEOTOOLBOX,NULL,NULL,0))<0)goto done;
        p.dec->hw_device_ctx=av_buffer_ref(hw);if(!p.dec->hw_device_ctx){ret=AVERROR(ENOMEM);goto done;}
        p.dec->get_format=vt_format;
    }
    if((ret=avcodec_open2(p.dec,codec,NULL))<0)goto done;
    p.fps=av_guess_frame_rate(p.in,p.is,NULL);
    if(p.fps.num<=0 || p.fps.den<=0 || av_q2d(p.fps)>240 || av_q2d(p.fps)<1)p.fps=(AVRational){30,1};
    p.pkt=av_packet_alloc();p.epkt=av_packet_alloc();p.frame=av_frame_alloc();p.copied=av_frame_alloc();
    if(!p.pkt||!p.epkt||!p.frame||!p.copied){ret=AVERROR(ENOMEM);goto done;}
    while((ret=av_read_frame(p.in,p.pkt))>=0){
        if(halted(s)){ret=AVERROR_EXIT;goto done;}
        if(p.pkt->stream_index==index){
            if(!packets && !(p.pkt->flags&AV_PKT_FLAG_KEY)){ret=PL_NEEDS_KEYFRAME;goto done;}
            if(++packets>12000 || av_packet_get_side_data(p.pkt,AV_PKT_DATA_ENCRYPTION_INFO,NULL)){ret=AVERROR_INVALIDDATA;goto done;}
            if(p.preroll){
                if(p.pkt->pos<0){ret=AVERROR_INVALIDDATA;goto done;}
                av_buffer_unref(&p.pkt->opaque_ref);p.pkt->opaque_ref=av_buffer_alloc(1);
                if(!p.pkt->opaque_ref){ret=AVERROR(ENOMEM);goto done;}
                p.pkt->opaque_ref->data[0]=p.pkt->pos>=s->target;
            }
            if((ret=decode_packet(&p,p.pkt))<0)goto done;
        }
        av_packet_unref(p.pkt);
    }
    if(ret!=AVERROR_EOF)goto done;
    if((ret=decode_packet(&p,NULL))<0)goto done;
    if(!st->frames){ret=AVERROR_INVALIDDATA;goto done;}
    if(encode){
        if((ret=encode_frame(&p,NULL))<0 || (ret=av_write_trailer(p.out))<0)goto done;
        avio_flush(p.oio); if(p.oio->error<0){ret=p.oio->error;goto done;}
        if(!p.dst.len){ret=AVERROR_INVALIDDATA;goto done;}
        if(encode==2 && (st->first_us<0 || set_clock(p.dst.bytes,p.dst.len,(uint64_t)av_rescale_q(st->first_us,AV_TIME_BASE_Q,(AVRational){1,90000}),0)!=1)){
            ret=AVERROR_INVALIDDATA;goto done;
        }
        *output=p.dst.bytes;*outsize=p.dst.len;p.dst.bytes=NULL;
    }
    ret=0;
done:
    if(ret<0 && err && errlen>0)av_strerror(ret,err,errlen);
    av_dict_free(&opts);av_packet_free(&p.pkt);av_packet_free(&p.epkt);
    av_frame_free(&p.frame);av_frame_free(&p.converted);av_frame_free(&p.copied);
    sws_freeContext(p.scale);avcodec_free_context(&p.dec);avcodec_free_context(&p.enc);av_buffer_unref(&hw);
    avformat_free_context(p.out);avformat_close_input(&p.in);
    if(p.io){av_freep(&p.io->buffer);avio_context_free(&p.io);}
    if(p.oio){av_freep(&p.oio->buffer);avio_context_free(&p.oio);}
    av_free(p.dst.bytes);return ret;
}
