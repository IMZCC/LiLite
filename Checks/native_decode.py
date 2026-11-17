"""Validate compressed input -> decoded pixel planes and time-preserving local output, offline."""
import contextlib
import ctypes as C
import hashlib
import http.server
import threading
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

native=Path(__file__).resolve().parents[1]
kit=native/"MediaKit"
source=kit/"Sources/CLiveRemux"
if not (source/"SoftVideo.c").exists(): source=kit/"DecoderCore"
ff=os.environ.get("PILI_QA_FFMPEG") or shutil.which("ffmpeg") or str(Path.home()/".cache/piliplus-native/tools/live-qa/ffmpeg")
pref=Path(subprocess.check_output(["bash",str(kit/"build-decoder-libs.sh"),"host"],text=True).strip())
def call(*args):
    result=subprocess.run(list(map(str,args)),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if result.returncode:
        print(result.stderr.decode(errors="replace")[-1200:],flush=True)
        result.check_returncode()
    return result.stdout
def boxes(data):
    i=0
    while i+8<=len(data):
        n=int.from_bytes(data[i:i+4],"big")
        if n==1:n=int.from_bytes(data[i+8:i+16],"big")
        if n==0:n=len(data)-i
        assert 8<=n<=len(data)-i
        yield (i,n,data[i+4:i+8]);i+=n

def elementary(ts):
    assert ts and len(ts)%188==0
    stream=bytearray();pid=None;timestamps=[]
    for i in range(0,len(ts),188):
        p=ts[i:i+188];assert p[0]==0x47
        current=(p[1]&31)*256+p[2];mode=(p[3]>>4)&3
        if not mode&1:continue
        j=4+(1+p[4] if mode&2 else 0);data=p[j:]
        if p[1]&64 and data[:3]==bytes([0,0,1]) and 224<=data[3]<=239:
            pid=current
            if data[7]&128:
                pts=data[9:14]
                ticks=((pts[0]&14)<<29)|(pts[1]<<22)|((pts[2]&254)<<14)|(pts[3]<<7)|(pts[4]>>1)
                timestamps.append(ticks*1000000/90000)
            data=data[9+data[8]:]
        if current==pid:stream.extend(data)
    return stream,timestamps

class Stats(C.Structure):
    _fields_=[("frames",C.c_int32),("w",C.c_int32),("h",C.c_int32),("transfer",C.c_int32),("first",C.c_int64),("last",C.c_int64)]
sink_type=C.CFUNCTYPE(C.c_int32,C.c_void_p,C.c_int32,C.c_int32,C.c_int64,C.c_void_p,C.c_int32,C.c_void_p,C.c_int32,C.c_void_p,C.c_int32,C.c_int32)
cancel_type=C.CFUNCTYPE(C.c_int32,C.c_void_p)

debug=os.environ.get("PILI_DECODER_FIXTURES")
if debug: Path(debug).mkdir(parents=True,exist_ok=True)
with (contextlib.nullcontext(debug) if debug else tempfile.TemporaryDirectory(prefix="pili-soft-video-")) as temp:
    tmp=Path(temp);so=tmp/"software.so"
    call("cc","-std=c11","-Werror=implicit-function-declaration","-shared","-fPIC","-Wl,-Bsymbolic","-O2","-I"+str(pref/"include"),"-I"+str(source/"include"),source/"SoftVideo.c","-L"+str(pref/"lib"),"-lavformat","-lavcodec","-lswresample","-lswscale","-lavutil","-ldav1d","-lpthread","-lm","-o",so)
    lib=C.CDLL(str(so))
    lib.pl_decode_video.argtypes=[C.c_void_p,C.c_int,C.c_void_p,C.c_int,C.c_int64,C.c_int64,C.c_int,C.c_int,C.c_int,C.c_void_p,cancel_type,sink_type,C.POINTER(Stats),C.POINTER(C.c_void_p),C.POINTER(C.c_int),C.c_char_p,C.c_int]
    lib.pl_free_video.argtypes=[C.c_void_p]
    def transform(init,buf,offset,target,stop=False,encode=True):
        frames=[];stats=Stats();out=C.c_void_p();n=C.c_int();error=C.create_string_buffer(256)
        @sink_type
        def sink(_,w,h,pts,y,sy,u,su,v,sv,ten):
            md5=hashlib.md5()
            planes=([(y,sy,w*2,h),(u,su,((w+1)//2)*4,(h+1)//2)] if ten else [(y,sy,w,h),(u,su,(w+1)//2,(h+1)//2),(v,sv,(w+1)//2,(h+1)//2)])
            for ptr,step,width,ht in planes:
                for row in range(ht):md5.update(C.string_at(ptr+row*step,width))
            frames.append((pts,md5.hexdigest()));return 0
        @cancel_type
        def cancel(_):return int(stop)
        code=lib.pl_decode_video(init,len(init),buf,len(buf),offset,target,0,4096*2160,encode,None,cancel,sink,C.byref(stats),C.byref(out),C.byref(n),error,256)
        data=C.string_at(out,n.value) if out else b""
        if out:lib.pl_free_video(out)
        return code,error.value,frames,data
    containercheck=tmp/"containercheck"
    swift=native/"Sources/PiliNative/Decoder"
    call("swiftc",swift/"DecoderFragment.swift",swift/"DecoderPreference.swift",native/"Checks/DecoderContainerCheck.swift","-o",containercheck)
    mod=tmp/"CLiveRemux";mod.mkdir(exist_ok=True)
    (mod/"module.modulemap").write_text('module CLiveRemux { header "'+str(source/"include/CLiveRemux.h")+'" export * }')
    obj=tmp/"soft.o";playback=tmp/"swift-playback"
    call("cc","-std=c11","-O2","-I"+str(pref/"include"),"-I"+str(source/"include"),"-c",source/"SoftVideo.c","-o",obj)
    call("swiftc","-I"+str(mod),swift/"DecoderSegment.swift",swift/"DecoderFragment.swift",swift/"DecoderPreference.swift",
         native/"Checks/DecoderPlaybackCheck.swift",obj,"-L"+str(pref/"lib"),"-lavformat","-lavcodec","-lswresample","-lswscale","-lavutil","-ldav1d","-lm","-lpthread","-o",playback)
    localcheck=tmp/"local-verify"
    call("swiftc","-I"+str(mod),swift/"LocalFragmentIndex.swift",native/"Sources/PiliNative/Playback/SegmentIndex.swift",
         swift/"DecoderSegment.swift",swift/"DecoderFragment.swift",swift/"DecoderPreference.swift",native/"Checks/LocalDecoderCheck.swift",
         obj,"-L"+str(pref/"lib"),"-lavformat","-lavcodec","-lswresample","-lswscale","-lavutil","-ldav1d","-lm","-lpthread","-o",localcheck)
    moviecheck=tmp/"movie-verify"
    call("swiftc","-I"+str(mod),swift/"LocalMovieTable.swift",swift/"LocalMovieFragments.swift",swift/"LocalFragmentIndex.swift",
         native/"Sources/PiliNative/Playback/SegmentIndex.swift",swift/"DecoderSegment.swift",swift/"DecoderFragment.swift",swift/"DecoderPreference.swift",
         native/"Checks/LocalMovieCheck.swift",obj,"-L"+str(pref/"lib"),"-lavformat","-lavcodec","-lswresample","-lswscale","-lavutil","-ldav1d","-lm","-lpthread","-o",moviecheck)
    remotecheck=tmp/"http-verify"
    playback_dir=native/"Sources/PiliNative/Playback"
    relay=next((native/"Sources/PiliNative").rglob("RelayRange.swift"))
    call("swiftc","-I"+str(mod),swift/"RemoteMovieMetadata.swift",swift/"LocalMovieTable.swift",swift/"LocalMovieFragments.swift",swift/"LocalFragmentIndex.swift",
         native/"Sources/PiliNative/Network/ServerCertificatePolicy.swift",playback_dir/"RangeTransport.swift",playback_dir/"MediaRange.swift",relay,playback_dir/"SegmentIndex.swift",swift/"DecoderSegment.swift",
         swift/"DecoderFragment.swift",swift/"DecoderPreference.swift",native/"Checks/RemoteMovieCheck.swift",obj,
         "-L"+str(pref/"lib"),"-lavformat","-lavcodec","-lswresample","-lswscale","-lavutil","-ldav1d","-lm","-lpthread","-o",remotecheck)
    audio_file=tmp/"audio.m4a"
    call(ff,"-y","-v","error","-f","lavfi","-i","sine=frequency=660:sample_rate=44100","-t","2","-c:a","aac","-frag_duration","500000","-movflags","+empty_moov+default_base_moof+dash+skip_trailer",audio_file)
    for name,encoder,args in [("AVC","libx264",["-preset","veryfast","-bf","2","-x264-params","scenecut=0"]),
                             ("HEVC","libx265",["-preset","ultrafast","-x265-params","log-level=error:scenecut=0:pools=2"]),
                             ("AV1","libaom-av1",["-cpu-used","8","-row-mt","1","-lag-in-frames","0"]),
                             ("VP9","libvpx-vp9",["-deadline","realtime","-cpu-used","8","-lag-in-frames","0"])]:
        video=tmp/(name+".mp4")
        call(ff,"-y","-v","error","-f","lavfi","-i","testsrc2=s=128x72:r=24","-frames:v","36","-pix_fmt","yuv420p","-threads","2","-g","12","-force_key_frames","expr:gte(t,n_forced*0.5)","-c:v",encoder,*args,"-movflags","+empty_moov+default_base_moof+frag_keyframe+dash+skip_trailer",video)
        data=video.read_bytes();struct=list(boxes(data));moov=next(x for x in struct if x[2]==b"moov")
        init=data[:moov[0]+moov[1]]
        frags=[(p,struct[i+1][0]+struct[i+1][1]) for i,(p,n,t) in enumerate(struct) if t==b"moof" and struct[i+1][2]==b"mdat"]
        assert len(frags)>=2
        if name in ("AV1","HEVC"):
            bare=bytearray(data)
            for pos,_,tag in struct:
                if tag==b"sidx":bare[pos+4:pos+8]=b"free"
            noindex=tmp/"no-sidx.mp4";noindex.write_bytes(bare)
            guarded=bytearray(data);marks=[data.find(tag,moov[0],moov[0]+moov[1]) for tag in (b"av01",b"hvc1",b"hev1")];at=next(p for p in marks if p>=0);guarded[at:at+4]=b"encv"
            encrypted=tmp/"encrypted-entry.mp4";encrypted.write_bytes(guarded)
            localvideo=tmp/"offline-video.mp4";localaudio=tmp/"offline-audio.mp4"
            print(call(localcheck,video,noindex,audio_file,encrypted,localvideo,localaudio).decode().strip(),flush=True)
            for local,kind in [(localvideo,"v"),(localaudio,"a")]:
                display=call(ff,"-v","error","-i",local,"-map","0:"+kind+":0","-f","framemd5","-").decode()
                assert any(line and line[0]!="#" for line in display.splitlines())

            # Compare compressed AAC data and packet PTS with the independent original demux.
            def packet_hashes(file):
                text=call(ff,"-v","error","-copyts","-i",file,"-map","0:a","-c","copy","-f","framehash","-").decode()
                return [tuple(v.strip() for v in line.split(",")) for line in text.splitlines() if line and line[0]!="#"]
            original=packet_hashes(audio_file);middle=packet_hashes(localaudio)
            first=next(i for i,p in enumerate(original) if p[5]==middle[0][5]);assert first>0 and original[first:first+len(middle)]==middle
            # Mixed/legacy single-file caches: interleaved input, moov at front or tail.
            movie=tmp/("mixed-"+name+".mp4")
            call(ff,"-y","-v","error","-f","lavfi","-i","testsrc2=s=128x72:r=24","-f","lavfi","-i","sine=frequency=440:sample_rate=44100","-t","6.4","-c:v",encoder,*args,"-pix_fmt","yuv420p","-threads","2","-g","24","-c:a","aac",*(["-movflags","+faststart"] if name=="HEVC" else []),movie)
            # Use real compact stz2 and co64 tables in the tail-moov AV1 fixture; media offsets
            # preceding the rewritten moov are unchanged. Independent FFmpeg also reads this file.
            if name=="AV1":
                def transform_boxes(data):
                    result=bytearray()
                    for at,size,tag in boxes(data):
                        body=data[at+8:at+size]
                        if tag in (b"moov",b"trak",b"mdia",b"minf",b"stbl"): body=transform_boxes(body)
                        elif tag==b"stco":
                            tag=b"co64";body=body[:8]+b"".join(b"\x00"*4+body[j:j+4] for j in range(8,len(body),4))
                        elif tag==b"stsz" and body[4:8]==b"\x00"*4:
                            values=[int.from_bytes(body[j:j+4],"big") for j in range(12,len(body),4)]
                            assert all(v<65536 for v in values)
                            tag=b"stz2";body=body[:4]+b"\x00\x00\x00\x10"+body[8:12]+b"".join(v.to_bytes(2,"big") for v in values)
                        result+=(8+len(body)).to_bytes(4,"big")+tag+body
                    return bytes(result)
                orig=movie.read_bytes();assert next(t for t in reversed(list(boxes(orig))))[2]==b"moov"
                movie.write_bytes(transform_boxes(orig))
            mb=movie.read_bytes(); tb=list(boxes(mb));mo=next(b for b in tb if b[2]==b"moov")
            entry=next(at for tag in (b"av01",b"hvc1",b"hev1") if (at:=mb.find(tag,mo[0],mo[0]+mo[1]))>=0)
            guarded=bytearray(mb);guarded[entry:entry+4]=b"encv"; bad=tmp/"protected-movie.mp4";bad.write_bytes(guarded)
            ext=bytearray(mb);mark=mb.index(b"url ",mo[0],mo[0]+mo[1]);ext[mark+7]=0;external=tmp/"external-movie.mp4";external.write_bytes(ext)
            conv=tmp/"movie-converted.mp4"; middle=tmp/"movie-mid.mp4"; vf=tmp/"movie-v.mp4"; af=tmp/"movie-a.m4a"
            print(call(moviecheck,movie,conv,middle,vf,af,bad,external).decode().strip(),flush=True)
            spans=[]
            class ServeRanges(http.server.BaseHTTPRequestHandler):
                def log_message(self,*args):pass
                def do_GET(self):
                    m=re.fullmatch(r"bytes=(\d+)-(\d+)",self.headers.get("Range",""));assert m and self.path=="/movie"
                    a,b=map(int,m.groups());assert 0<=a<=b<len(mb) and b-a<512*1024;spans.append((a,b))
                    self.send_response(206);self.send_header("Content-Range",f"bytes {a}-{b}/{len(mb)}")
                    self.send_header("Content-Length",str(b-a+1));self.end_headers();self.wfile.write(mb[a:b+1])
            server=http.server.ThreadingHTTPServer(("127.0.0.1",0),ServeRanges)
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            netclip=tmp/"remote-mid.mp4"
            try: print(call(remotecheck,"http://127.0.0.1:"+str(server.server_port)+"/movie",movie,netclip).decode().strip(),flush=True)
            finally: server.shutdown();server.server_close();thread.join()
            assert spans and all(b-a+1<len(mb) for a,b in spans) and len(spans)<80,(name,spans)
            def content(file,kind,copy=False):
                return [tuple(x.strip() for x in line.split(",")) for line in call(ff,"-v","error","-copyts","-i",file,"-map","0:"+kind,
                  *(["-c","copy"] if copy else ["-fps_mode","passthrough","-enc_time_base","1:90000"] if kind=="v" else []),"-f","framemd5","-").decode().splitlines() if line and line[0]!="#"]
            for out,kind in [(vf,"v"),(af,"a")]:
                expected=content(movie,kind);got=content(out,kind)
                assert expected==got,(name,"full movie",kind,len(expected),len(got),next(((a,b) for a,b in zip(expected,got) if a!=b),None))
            chosen=content(middle,"v"); expected=content(movie,"v");converted=content(conv,"v")
            assert converted==content(netclip,"v"),(name,"HTTP and local seek differ")
            origin=next(i for i,r in enumerate(expected) if r[-1]==chosen[0][-1])
            assert origin>0 and expected[origin:origin+len(chosen)]==chosen,(name,"remux seek",expected[origin],chosen[0])
            assert len(converted)==len(chosen) and all(abs(int(a[2])-int(b[2]))<=1 for a,b in zip(converted,chosen)),(name,"decoded middle seek",chosen[0],converted[0])
        if name=="AV1":
            lo,hi=frags[1]
            (tmp/"init.bin").write_bytes(init);(tmp/"media.bin").write_bytes(data[lo:hi]);reassembled=tmp/"swift-hls.mp4"
            print(call(playback,tmp/"init.bin",tmp/"media.bin",str(lo),reassembled).decode().strip(),flush=True)
            actual=call(ff,"-v","error","-i",reassembled,"-fps_mode","passthrough","-f","framemd5","-").decode()
            assert any(line and line[0]!="#" for line in actual.splitlines())
        if name in ("AVC","HEVC"):
            first=tmp/(name+"-source-fragment.mp4")
            first.write_bytes(init+data[frags[0][0]:frags[0][1]])
            print(call(containercheck,first,"avc1." if name=="AVC" else "hvc1.").decode().strip(),flush=True)
        allframes=[];used=[]
        for i,(lo,hi) in enumerate(frags):
            code,error,frames,ts=transform(init,data[lo:hi],lo,lo)
            assert code==0 and frames and ts[:1]==b"\x47",(name,i,code,error,len(frames))
            used.append(frames)
            code,error,fmp4frames,fmp4=transform(init,data[lo:hi],lo,lo,encode=2)
            assert code==0 and fmp4frames==frames,(name,"fmp4",code,error)
            boxes_out=list(boxes(fmp4));cut=next(p for p,n,t in boxes_out if t==b"moof")
            assert any(t==b"moov" for _,_,t in boxes_out) and len(fmp4)>cut
            mp4=tmp/(name+str(i)+"-converted.mp4");mp4.write_bytes(fmp4)
            timeline=call(ff,"-v","error","-copyts","-i",mp4,"-fps_mode","passthrough","-enc_time_base","1:90000","-f","framemd5","-").decode()
            timed=[line for line in timeline.splitlines() if line and line[0]!="#"]
            num,den=map(int,re.search(r"#tb 0: (\d+)/(\d+)",timeline).groups())
            assert len(timed)==len(frames) and all(abs(int(l.split(",")[2])*num*1000000/den-f[0])<1000000/24+1 for l,f in zip(timed,frames)),(name,"fMP4 timestamps",[(int(l.split(",")[2])*num*1000000/den,f[0]) for l,f in zip(timed,frames)][:4])
            tsfile=tmp/(name+str(i)+".ts");tsfile.write_bytes(ts)
            payload,pes=elementary(ts)
            es=tmp/(name+str(i)+".m2v");es.write_bytes(payload)
            check=call(ff,"-v","error","-f","mpegvideo","-i",es,"-map","0:v:0","-fps_mode","passthrough","-f","framemd5","-").decode()
            encoded=[line for line in check.splitlines() if line and line[0]!="#"]
            assert len(encoded)==len(frames) and len(pes)==len(frames),(name,len(encoded),len(frames),len(pes))
            assert all(abs(pts-f[0])<=1000000/24+1 for pts,f in zip(pes,frames)),(name,i,pes,frames[0])
            allframes+=frames
        decoded=call(ff,"-v","error","-i",video,"-map","0:v:0","-fps_mode","passthrough","-pix_fmt","yuv420p","-f","framemd5","-").decode()
        reference=[line.split(",")[-1].strip() for line in decoded.splitlines() if line and line[0]!="#"]
        assert [v[1] for v in allframes]==reference,(name,len(reference),len(allframes))
        assert all(a[0]<b[0] for a,b in zip(allframes,allframes[1:])),(name,[a[0] for a in allframes])
        lo=frags[0][0];target,hi=frags[1]
        code,error,selected,_=transform(init,data[lo:hi],lo,target,encode=False)
        assert code==0 and selected==used[1],(name,"preroll",code,error,len(selected),len(used[1]))
        assert transform(init,data[lo:hi],lo,target,stop=True)[0]<0
        print(f"{name}: {len(allframes)} software-decoded picture hashes matched; {len(frags)} independently playable segments; seek/preroll and time checked",flush=True)
    for transfer in ("smpte2084","arib-std-b67"):
        video=tmp/(transfer+".mp4")
        call(ff,"-y","-v","error","-f","lavfi","-i","testsrc2=s=128x72:r=24","-frames:v","12","-pix_fmt","yuv420p10le","-threads","2","-c:v","libx265","-preset","ultrafast","-color_primaries","bt2020","-color_trc",transfer,"-colorspace","bt2020nc","-x265-params","log-level=error:pools=2","-movflags","+empty_moov+default_base_moof+frag_keyframe+dash+skip_trailer",video)
        content=video.read_bytes();tree=list(boxes(content))
        moov=next(x for x in tree if x[2]==b"moov");init=content[:moov[0]+moov[1]]
        lo=next(x[0] for x in tree if x[2]==b"moof")
        code,msg,frames,_=transform(init,content[lo:],lo,lo,encode=False)
        reference=call(ff,"-v","error","-i",video,"-pix_fmt","p010le","-f","framemd5","-").decode()
        hashes=[line.split(",")[-1].strip() for line in reference.splitlines() if line and line[0]!="#"]
        assert code==0 and len(frames)==12 and [f[1] for f in frames]==hashes,(transfer,msg,len(frames))
        print(f"{transfer}: all 12 ten-bit P010 image hashes matched",flush=True)
