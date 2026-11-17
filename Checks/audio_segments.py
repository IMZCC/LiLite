"""Offline PCM gain, actual FFmpeg normalization, random seek clocks and guarded inputs."""
import contextlib,ctypes as C, hashlib, math, os, re, shutil, struct, subprocess, tempfile
from pathlib import Path
native=Path(__file__).resolve().parents[1];kit=native/'MediaKit';source=kit/'Sources/CLiveRemux'
ff=os.environ.get('PILI_QA_FFMPEG') or shutil.which('ffmpeg') or str(Path.home()/'.cache/piliplus-native/tools/live-qa/ffmpeg')
def run(*args):
    p=subprocess.run(list(map(str,args)),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode: raise RuntimeError(p.stderr.decode(errors='replace')[-1500:])
    return p.stdout
pref=Path(os.environ.get('PILI_AUDIO_QA_VENDOR') or run('bash',kit/'build-decoder-libs.sh','host').decode().strip())
def boxes(d):
    at=0
    while at<len(d):
        n=int.from_bytes(d[at:at+4],'big');assert 8<=n<=len(d)-at
        yield at,at+n,d[at+4:at+8];at+=n
stoptype=C.CFUNCTYPE(C.c_int32,C.c_void_p)
with tempfile.TemporaryDirectory(prefix='pili-audio-filter-') as temp:
    td=Path(temp);lib=td/'segment.so'
    run('cc','-std=c11','-Werror=implicit-function-declaration','-O2','-shared','-fPIC','-Wl,-Bsymbolic','-I'+str(pref/'include'),'-I'+str(source/'include'),source/'AudioSegment.c','-L'+str(pref/'lib'),'-lavformat','-lavfilter','-lavcodec','-lswresample','-lswscale','-lavutil','-ldav1d','-lpthread','-lm','-o',lib)
    sw=native/'Sources/PiliNative/Decoder'
    module=td/'CLiveRemux';module.mkdir();(module/'module.modulemap').write_text('module CLiveRemux { header "'+str(source/'include/CLiveRemux.h')+'" export * }')
    objects=[]
    for c in ['AudioSegment','SoftVideo']:
        obj=td/(c+'.o');objects.append(obj)
        run('cc','-std=c11','-O2','-I'+str(pref/'include'),'-I'+str(source/'include'),'-c',source/(c+'.c'),'-o',obj)
    swift=td/'rendition'
    run('swiftc','-I'+str(module),sw/'AudioFilterChoice.swift',sw/'AudioSegment.swift',sw/'DecoderSegment.swift',sw/'DecoderFragment.swift',sw/'DecoderPreference.swift',native/'Sources/PiliNative/Playback/SegmentIndex.swift',native/'Checks/AudioRenditionCheck.swift',*objects,'-L'+str(pref/'lib'),'-lavformat','-lavfilter','-lavcodec','-lswresample','-lswscale','-lavutil','-ldav1d','-lm','-lpthread','-o',swift)
    m=C.CDLL(str(lib));m.pl_free_audio.argtypes=[C.c_void_p];m.pl_audio_segment.argtypes=[C.c_void_p,C.c_int32,C.c_void_p,C.c_int32,C.c_int64,C.c_int64,C.c_int64,C.c_char_p,C.c_void_p,stoptype,C.POINTER(C.c_void_p),C.POINTER(C.c_int32),C.c_char_p,C.c_int32]
    def work(prefix,media,offset,first,last,graph,cancel=False):
        out=C.c_void_p();size=C.c_int32();err=C.create_string_buffer(192)
        @stoptype
        def stop(_):return int(cancel)
        rc=m.pl_audio_segment(prefix,len(prefix),media,len(media),offset,first,last,graph.encode(),None,stop,C.byref(out),C.byref(size),err,len(err))
        d=C.string_at(out,size.value) if out else b''
        if out:m.pl_free_audio(out)
        return rc,d,err.value
    def pcm(file,filters=None):
        return run(ff,'-v','error','-i',file,'-map','0:a:0',*(['-af',filters] if filters else []),'-ar','48000','-ac','1','-c:a','pcm_s24le','-f','s24le','-')
    def values(data):
        return [int.from_bytes(data[i:i+3],'little',signed=True) for i in range(0,len(data),3)]
    for codec in ('alac','aac','flac'):
        media=td/(codec+'.m4a')
        run(ff,'-y','-v','error','-f','lavfi','-i',"aevalsrc=0.13*sin(2*PI*330*t)*(0.25+0.75*sin(0.45*t)*sin(0.45*t)):s=48000",'-t','12','-c:a',codec,'-strict','experimental','-movflags','+empty_moov+default_base_moof+dash+skip_trailer','-frag_duration','2000000','-f','mp4',media)
        d=media.read_bytes();top=list(boxes(d));prefix=d[:next(x[1] for x in top if x[2]==b'moov')]
        seg=[(lo,top[i+1][1]) for i,(lo,hi,kind) in enumerate(top) if kind==b'moof'];assert len(seg)>=5
        lo,hi=seg[0][0],seg[-1][1];ref=pcm(media);selected=2;first,end=seg[selected]
        basepts=None
        for chain in ('volume=volume=1','volume=volume=2','volume=volume=3','dynaudnorm=f=250:g=5:p=0.5:r=0.9','loudnorm=I=-16:LRA=11:TP=-1.5','loudnorm=I=-16:LRA=11:TP=-1.5:offset=0:linear=1:measured_I=-25:measured_LRA=5:measured_TP=-6:measured_thresh=-35'):
            rc,out,error=work(prefix,d[lo:hi],lo,first,end-1,chain)
            assert rc==0 and out,(codec,chain,rc,error)
            clip=td/'selected.mp4';clip.write_bytes(out)
            clock=run(ff,'-v','error','-copyts','-i',clip,'-map','0:a','-f','framehash','-').decode()
            scale=re.search(r'#tb 0: (\d+)/(\d+)',clock)
            firstline=next(line for line in clock.splitlines() if line and not line.startswith('#'))
            pts=round(int(firstline.split(',')[2])*int(scale[1])*48000/int(scale[2]))
            if basepts is None:basepts=pts
            assert pts==basepts and pts>0
            heard=pcm(clip)
            wanted=pcm(media,chain)
            compare=wanted[3*pts:3*pts+len(heard)]
            assert len(heard)==len(compare) and len(heard)>3*48000,(codec,chain,len(heard),len(compare))
            va,vb=values(heard),values(compare)
            delta=math.sqrt(sum((x-y)**2 for x,y in zip(va,vb))/len(va))
            assert delta<28,(codec,chain,delta,max(abs(x-y) for x,y in zip(va,vb)))
            print(f'{codec} / {chain.split("=")[0]}: {len(heard)//3} samples, PTS {pts}, RMS difference {delta:.2f} PCM24 units',flush=True)
        for edge in (0,len(seg)-1):
            a,b=seg[edge]
            left=max(0,edge-2);right=min(len(seg)-1,edge+2);pos,stop=seg[left][0],seg[right][1]
            rc,clip,err=work(prefix,d[pos:stop],pos,a,b-1,'volume=volume=2')
            assert rc==0 and clip,(codec,'boundary',edge,err)
        if codec=='aac':
            i=td/'init';buf=td/'payload';output=td/'swift.m4a';i.write_bytes(prefix);buf.write_bytes(d[lo:hi])
            run(swift,i,buf,str(lo),str(first)+'-'+str(end-1),output)
            want=pcm(media,'dynaudnorm=f=250:g=5:p=0.5:r=0.9,volume=volume=2')
            heard=pcm(output);start=basepts*3
            v,w=values(heard),values(want[start:start+len(heard)])
            assert len(v)==len(w) and math.sqrt(sum((a-b)**2 for a,b in zip(v,w))/len(v))<28
            print('Swift: server/fallback/custom preferences and five coalesced requests produced matching, playable audio',flush=True)
        for bad in ('amovie=other','loudnorm=stats_file=1','volume=volume=1;anull','dynaudnorm=f=1000:g=301'):
            assert work(prefix,d[lo:hi],lo,first,end-1,bad)[0]<0
        assert work(prefix,d[lo:hi],lo,first,end-1,'volume=volume=2',cancel=True)[0]<0

    stereo=td/'stereo.m4a'
    run(ff,'-y','-v','error','-f','lavfi','-i',"aevalsrc=0.8*sin(2*PI*400*t)|0.05*sin(2*PI*727*t):s=96000",'-t','5','-c:a','alac','-movflags','+empty_moov+default_base_moof+dash+skip_trailer','-frag_duration','1000000',stereo)
    d=stereo.read_bytes();top=list(boxes(d));pre=d[:next(b for a,b,t in top if t==b'moov')]
    spans=[(a,top[k+1][1]) for k,(a,b,t) in enumerate(top) if t==b'moof'];base=spans[0][0];a,b=spans[2]
    rc,out,err=work(pre,d[base:spans[-1][1]],base,a,b-1,'volume=volume=3');assert rc==0,(rc,err)
    clipped=td/'stereo-boosted.m4a';clipped.write_bytes(out)
    data=run(ff,'-v','error','-i',clipped,'-f','s24le','-c:a','pcm_s24le','-')
    samples=values(data);left,right=samples[::2],samples[1::2]
    assert min(left)==-8388608 and max(left)==8388607 and max(abs(v) for v in right)<1400000
    clock=run(ff,'-v','error','-copyts','-i',clipped,'-f','framehash','-').decode()
    assert '#sample_rate 0: 96000' in clock and '#channel_layout_name 0: stereo' in clock
    print('96 kHz stereo / 300%: original channels and rate, both clipping rails and quiet channel amplitude verified')
