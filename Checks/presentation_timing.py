"""Real fMP4 picture timestamps, exact PCM32, seek windows and RT clock output (offline)."""
from pathlib import Path
import ctypes as c,math,os,re,shutil,struct,subprocess,tempfile
root=Path(__file__).resolve().parents[1];src=root/'MediaKit/Sources/CLiveRemux';inc=src/'include'
def run(*args):
    p=subprocess.run(list(map(str,args)),capture_output=True)
    if p.returncode:raise RuntimeError((p.stdout+p.stderr).decode(errors='replace')[-3800:])
    return p.stdout
ff=os.environ.get('PILI_QA_FFMPEG') or shutil.which('ffmpeg') or str(Path.home()/'.cache/piliplus-native/tools/live-qa/ffmpeg')
pref=Path(os.environ.get('PILI_AUDIO_QA_VENDOR') or run('bash',root/'MediaKit/build-decoder-libs.sh','host').decode().strip())
def boxes(data):
    i=0
    while i<len(data):
        n=int.from_bytes(data[i:i+4],'big');assert 8<=n<=len(data)-i
        yield i,i+n,data[i+4:i+8];i+=n
class PCM(c.Structure):
    _fields_=[(k,c.c_int32) for k in ('rate','channels','frames')]+[('layout',c.c_int32*8),('start',c.c_int64),('video',c.c_double)]
with tempfile.TemporaryDirectory(prefix='pili-presentation-') as temp:
    d=Path(temp);so=d/'clock.so'
    libs=['-L'+str(pref/'lib'),'-lavformat','-lavfilter','-lavcodec','-lswresample','-lswscale','-lavutil','-ldav1d','-lpthread','-lm']
    run('cc','-std=c11','-O2','-shared','-fPIC','-Wl,-Bsymbolic','-I'+str(inc),'-I'+str(pref/'include'),src/'AudioSegment.c',src/'TimingRing.c',*libs,'-o',so)
    lib=c.CDLL(str(so));fn=lib.pl_audio_pcm
    fn.argtypes=[c.c_void_p,c.c_int32,c.c_void_p,c.c_int32,*([c.c_int64]*3),c.c_char_p,c.c_void_p,c.c_void_p,c.POINTER(PCM),c.POINTER(c.c_void_p),c.POINTER(c.c_int32),c.c_char_p,c.c_int32];lib.pl_free_audio.argtypes=[c.c_void_p]
    song=d/'stereo.m4a'
    run(ff,'-v','error','-f','lavfi','-i','aevalsrc=0.41*sin(2*PI*719*t)|0.14*sin(2*PI*440*t):s=48000','-t','8.2','-c:a','alac','-movflags','+empty_moov+default_base_moof+dash+skip_trailer','-frag_duration','1650000',song)
    full=run(ff,'-v','error','-i',song,'-c:a','pcm_s32le','-f','s32le','-')
    media=song.read_bytes();tops=list(boxes(media));pre=media[:next(b for a,b,k in tops if k==b'moov')];spans=[(a,tops[n+1][1]) for n,(a,b,k) in enumerate(tops) if k==b'moof']
    mono=d/'mono';mono.write_bytes(b''.join(full[n:n+4] for n in range(0,len(full),8)))
    for i in [3,0,2,1,len(spans)-1]:
        a,b=spans[i];lo,hi=spans[max(0,i-1)][0],spans[min(len(spans)-1,i+1)][1];desc=PCM();out=c.c_void_p();size=c.c_int32();error=c.create_string_buffer(96)
        rc=fn(pre,len(pre),media[lo:hi],hi-lo,lo,a,b-1,b'volume=volume=1',None,None,c.byref(desc),c.byref(out),c.byref(size),error,96)
        assert rc==0,(rc,error.value)
        try:raw=c.string_at(out,size.value)
        finally:lib.pl_free_audio(out)
        assert (desc.rate,desc.channels,list(desc.layout)[:2])==(48000,2,[0,1]) and desc.start>=0
        assert len(raw)==desc.frames*8 and raw==full[desc.start*8:desc.start*8+len(raw)],(i,desc.start,size.value)
        print(f'Random seek segment {i}: both channels bit-exact, source frames {desc.start}..{desc.start+desc.frames-1}')
    # Verify the exact audio copied by the real-time callback, including wrap and sequence changes.
    ring=lib.pl_clock_ring;ring.argtypes=[c.c_int32,c.c_int32,c.c_int32,c.c_int64];ring.restype=c.c_void_p
    put=lib.pl_clock_write;put.argtypes=[c.c_void_p,c.c_void_p,c.c_int32]
    render=lib.pl_clock_render;render.argtypes=[c.c_void_p,c.c_int32,c.POINTER(c.POINTER(c.c_float)),c.c_double]
    control=lib.pl_clock_control;control.argtypes=[c.c_void_p,c.c_double,c.c_int32];lib.pl_clock_destroy.argtypes=[c.c_void_p]
    def emitted(r,n,t):
        buf=(c.c_float*n)();planes=(c.POINTER(c.c_float)*1)(c.cast(buf,c.POINTER(c.c_float)));assert render(r,n,planes,t)==n
        return list(buf)
    r=ring(48000,1,8192,0);wave=list(struct.unpack('<'+str(len(full)//4)+'i',full))[::2];pos=0
    for group in range(10):
        chunk=wave[pos:pos+4800];source=(c.c_int32*len(chunk))(*chunk);assert put(r,source,len(chunk))==4800
        original=emitted(r,2304,group)
        if group in (2,5,8):
            control(r,1,-1);duplicate=emitted(r,1024,group+.01);assert duplicate==original[-1024:]
            control(r,1,1);start=2304+1024;rest=emitted(r,4800-start,group+.02)
        else:start=2304;rest=emitted(r,4800-start,group+.02)
        assert all(abs(a-b/2**31)<2e-7 for a,b in zip(rest,chunk[start:]));pos+=4800
    lib.pl_clock_destroy(r)
    # Apply the production fractional resampler, then measure output pitch against the known 719 Hz channel.
    r=ring(48000,1,96000,0);source=(c.c_int32*50000)(*wave[:50000]);assert put(r,source,50000)==50000
    control(r,1.01,0);heard=emitted(r,48000,0);lib.pl_clock_destroy(r)
    zero=[i+(0-heard[i])/(heard[i+1]-heard[i]) for i in range(len(heard)-1) if heard[i]<0<=heard[i+1]]
    fundamental=(len(zero)-1)*48000/(zero[-1]-zero[0]);assert abs(fundamental-719*1.01)<0.05
    print(f'PCM ring: repeated/dropped exactly 1024 frames across wrap, resampling 719 Hz → {fundamental:.3f} Hz')
    tempo=lib.pl_clock_tempo;tempo.argtypes=[c.c_void_p,c.c_double]
    buffered=lib.pl_clock_buffered;buffered.argtypes=[c.c_void_p]
    for factor in (0.5,1.01,2.0):
        r=ring(48000,1,160000,0);source=(c.c_int32*120000)(*wave[:120000]);assert put(r,source,120000)==120000
        tempo(r,factor);heard=emitted(r,48000,0)
        consumed=120000-buffered(r);lib.pl_clock_destroy(r)
        zero=[i-heard[i]/(heard[i+1]-heard[i]) for i in range(2048,len(heard)-1) if heard[i]<0<=heard[i+1]]
        hz=(len(zero)-1)*48000/(zero[-1]-zero[0]);assert abs(hz-719)<1.6,(factor,hz)
        rms=math.sqrt(sum(x*x for x in heard)/len(heard));assert 0.26<rms<0.31,(factor,rms)
        assert abs(consumed-48000*factor)<=2,(factor,consumed)
        print(f'Pitch-preserving {factor}x: {consumed} source frames → 48000 output, {hz:.3f} Hz, RMS {rms:.4f}')
    movie=d/'film.mp4'
    run(ff,'-v','error','-f','lavfi','-i','testsrc2=size=160x90:rate=24000/1001','-t','8','-c:v','libx264','-preset','ultrafast','-bf','2',movie)
    hashed=run(ff,'-v','error','-copyts','-i',movie,'-map','0:v:0','-f','framemd5','-').decode()
    a,b=map(int,re.search(r'#tb 0: (\d+)/(\d+)',hashed).groups());pictures=[s.split(',') for s in hashed.splitlines() if s and not s.startswith('#')]
    assert len({f[-1] for f in pictures})==len(pictures)
    idx=d/'frames';idx.write_text(''.join(f'{int(row[2])*a/b:.10f}\n' for row in pictures))
    (d/'module.modulemap').write_text('module CLiveRemux { header "'+str(inc/'TimingRing.h')+'" export * }')
    run('cc','-std=c11','-O2','-I'+str(inc),'-c',src/'TimingRing.c','-o',d/'ring.o')
    run('swiftc','-I'+str(d),root/'Sources/PiliNative/Timing/PresentationClock.swift',root/'Checks/PresentationClockCheck.swift',d/'ring.o','-o',d/'schedule')
    print(run(d/'schedule',idx,mono).decode())

    # Use the actual dated live playlist format emitted by both native muxers. Inject an audio
    # delay before muxing and check the decoded sample timestamps across independent item epochs.
    live=d/'live';live.mkdir()
    run(ff,'-v','error','-f','lavfi','-i','testsrc2=size=160x90:rate=24','-itsoffset','0.208','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','6.3','-c:v','libx264','-preset','ultrafast','-g','24','-keyint_min','24','-sc_threshold','0','-bf','0','-c:a','aac','-hls_time','1','-hls_list_size','0','-hls_segment_type','fmp4','-hls_fmp4_init_filename','init.mp4','-hls_segment_filename',live/'part%08d.m4s','-hls_flags','program_date_time+independent_segments','-f','hls',live/'index.m3u8')
    (d/'module.modulemap').write_text('module CLiveRemux { header "'+str(inc/'AudioSegment.h')+'" export * }')
    run('cc','-std=c11','-O2','-I'+str(inc),'-I'+str(pref/'include'),'-c',src/'AudioSegment.c','-o',d/'audio.o')
    (d/'module.modulemap').write_text('module CLiveRemux { header "'+str(inc/'AudioSegment.h')+'" header "'+str(inc/'TimingRing.h')+'" export * }')
    run('swiftc','-I'+str(d),root/'Sources/PiliNative/Timing/ClockPCM.swift',root/'Sources/PiliNative/Timing/ClockAudioFeed.swift',root/'Sources/PiliNative/Playback/SegmentIndex.swift',root/'Checks/ClockAudioFeedCheck.swift',d/'audio.o',d/'ring.o',*libs,'-o',d/'audio-feed')
    print(run(d/'audio-feed').decode())
    run('swiftc','-I'+str(d),root/'Sources/PiliNative/Timing/ClockPCM.swift',root/'Sources/PiliNative/Timing/LiveTimingSource.swift',root/'Sources/PiliNative/Playback/SegmentIndex.swift',root/'Checks/LiveTimingCheck.swift',d/'audio.o',*libs,'-o',d/'live-clock')
    print(run(d/'live-clock',live).decode())
    early=d/'early';early.mkdir()
    run(ff,'-v','error','-itsoffset','0.250','-f','lavfi','-i','testsrc2=size=160x90:rate=24','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','6.3','-fps_mode','passthrough','-c:v','libx264','-preset','ultrafast','-g','24','-keyint_min','24','-sc_threshold','0','-bf','0','-c:a','aac','-hls_time','1','-hls_list_size','0','-hls_segment_type','fmp4','-hls_fmp4_init_filename','init.mp4','-hls_segment_filename',early/'part%08d.m4s','-hls_flags','program_date_time+independent_segments','-f','hls',early/'index.m3u8')
    print(run(d/'live-clock',early,'negative').decode())
