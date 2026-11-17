"""Non-seekable FLV / enhanced-FLV -> actual video decode + rolling HLS, original audio."""
import contextlib, hashlib, os, re, shutil, subprocess, tempfile
from pathlib import Path
native=Path(__file__).resolve().parents[1];kit=native/'MediaKit';source=kit/'Sources/CLiveRemux'
ff=os.environ.get('PILI_QA_FFMPEG') or shutil.which('ffmpeg') or str(Path.home()/'.cache/piliplus-native/tools/live-qa/ffmpeg')
def run(*a):
    q=subprocess.run(list(map(str,a)),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if q.returncode: raise RuntimeError(q.stderr.decode(errors='replace')[-1800:])
    return q.stdout
pref=Path(run('bash',kit/'build-decoder-libs.sh','host').decode().strip())
location=os.environ.get('PILI_LIVE_DECODER_FIXTURES')
if location:Path(location).mkdir(exist_ok=True,parents=True)
with (contextlib.nullcontext(location) if location else tempfile.TemporaryDirectory(prefix="pili-live-video-")) as temp:
    td=Path(temp);exe=td/'decode'
    run('cc','-std=c11','-O2','-Werror=implicit-function-declaration','-I'+str(pref/'include'),'-I'+str(source/'include'),source/'LiveDecoder.c',source/'LivePairCore.c',kit/'Checks/live_decode_file.c','-L'+str(pref/'lib'),'-lavformat','-lavcodec','-lswscale','-lswresample','-lavutil','-ldav1d','-lpthread','-lm','-o',exe)
    for name,enc,flags,n in [('avc','libx264',['-preset','veryfast','-bf','2'],1),('hevc','libx265',['-preset','ultrafast','-x265-params','log-level=error:pools=1:frame-threads=1'],2),('av1','libaom-av1',['-cpu-used','8','-row-mt','1','-lag-in-frames','0'],3)]:
        original=td/(name+'.flv');out=td/(name+'-out');out.mkdir(exist_ok=True)
        run(ff,'-y','-v','error','-f','lavfi','-i','testsrc2=s=144x80:r=12','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','5.5','-pix_fmt','yuv420p','-c:v',enc,*flags,'-threads','2','-g','12','-c:a','aac','-f','flv',original)
        stats=list(map(int,run(exe,original,out,0,n,-1).split()))
        assert stats[0]==66 and stats[3]>190 and stats[4:]==[144,80,0],(name,stats)
        manifest=out/'index.m3u8';txt=manifest.read_text()
        assert '#EXT-X-ENDLIST' in txt and len(re.findall(r'^part\d{8}\.m4s$',txt,re.M))>=2
        def movie(url):return run(ff,'-v','error','-i',url,'-map','0:v','-pix_fmt','yuv420p','-fps_mode','passthrough','-f','rawvideo','-')
        a,b=movie(original),movie(manifest);assert len(a)==len(b)==144*80*3//2*66
        rms=(sum((v-w)**2 for v,w in zip(a,b))/len(a))**0.5;assert rms<9,(name,rms)
        def packets(url,kind,copy=False):
            text=run(ff,'-v','error','-copyts','-i',url,'-map','0:'+kind,*( ['-c','copy'] if copy else ['-enc_time_base','1:90000','-fps_mode','passthrough']),'-f','framehash','-').decode()
            tb=re.search(r'#tb 0: (\d+)/(\d+)',text);unit=int(tb[1])/int(tb[2]);lines=[l.split(',') for l in text.splitlines() if l and not l.startswith('#')]
            return [(int(l[2])*unit,l[5].strip()) for l in lines]
        audio0,audio1=packets(original,'a',True),packets(manifest,'a',True)
        i=next(i for i,x in enumerate(audio0) if x[1]==audio1[0][1]);assert [x[1] for x in audio1]==[x[1] for x in audio0[i:i+len(audio1)]]
        picture0,picture1=packets(original,'v'),packets(manifest,'v')
        # Containers may move the common origin. Video and unmodified AAC must move by the SAME amount.
        shift=audio1[0][0]-audio0[i][0]
        assert all(abs(v[0]-w[0]-shift)<1/12+0.002 for v,w in zip(picture1,picture0)),(name,shift,picture0[:2],picture1[:2])
        print(f'FLV {name}: {stats[0]} true CPU frames; RMS {rms:.2f}/255; {len(audio1)} original AAC packets and shared A/V timeline',flush=True)
        if name=='avc':
            for mode,kind,budget in [(0,2,-1),(1,1,-1),(0,1,4096)]:
                invalid=td/('reject-'+str(mode)+'-'+str(kind)+'-'+str(budget));invalid.mkdir(exist_ok=True)
                r=subprocess.run([str(exe),str(original),str(invalid),str(mode),str(kind),str(budget)],capture_output=True)
                assert r.returncode!=0 and not (invalid/'index.m3u8').exists()
    print('Incorrect promised codec, unavailable hardware copy, and mid-stream cancellation rejected')

    hcheck=td/'hls-source'
    sw=native/'Sources/PiliNative';run('swiftc',*[sw/'Live'/f for f in ['LiveHLSFeed.swift','LiveHLSFetch.swift','LiveHLSPlaylist.swift','LivePackedAudio.swift']],
       sw/'Network/ServerCertificatePolicy.swift',*[sw/'Playback'/f for f in ['MediaRange.swift','SegmentIndex.swift','RelayRange.swift']],native/'Checks/LiveHLSFeedCheck.swift','-o',hcheck)
    for fmt,tag in [('fmp4',1),('mpegts',2)]:
        src=td/('input-'+fmt);src.mkdir(exist_ok=True);playlist=src/'index.m3u8'
        run(ff,'-y','-v','error','-i',td/'avc.flv','-c','copy','-hls_time','2','-hls_segment_type',fmt,'-hls_flags','single_file','-hls_list_size','0','-f','hls',playlist)
        joined=td/(fmt+'.media');print(run(hcheck,src,joined,tag).decode().strip(),flush=True)
        if fmt=='mpegts':assert joined.read_bytes()==(src/'index.ts').read_bytes()
        out=td/('out-'+fmt);out.mkdir(exist_ok=True);stats=list(map(int,run(exe,joined,out,0,1,-1,tag).split()))
        assert stats[0]==66 and stats[3]>190,(fmt,stats)
        r0,r1=movie(td/'avc.flv'),movie(out/'index.m3u8');assert len(r0)==len(r1)==144*80*3//2*66
        diff=(sum((x-y)**2 for x,y in zip(r0,r1))/len(r0))**0.5;assert diff<9
        # TS carries ADTS headers, CMAF does not; compare decoded PCM from the same AAC packets.
        def pcm(a):return run(ff,'-v','error','-i',a,'-map','0:a','-f','s16le','-c:a','pcm_s16le','-')
        aa=pcm(td/'avc.flv');bb=pcm(out/'index.m3u8');q=aa.find(bb[16384:16384+4096]);assert q>=0 and bb[16384:-8192]==aa[q:q+len(bb)-24576]
        print(f'Live HLS {fmt}: original audio and {stats[0]} converted pictures (RMS {diff:.2f}/255)')
        direct=td/('direct-'+fmt);direct.mkdir(exist_ok=True)
        st=list(map(int,run(exe,joined,direct,2,1,-1,tag).split()))
        priv=direct/'index.m3u8';assert st[0]==66 and '#EXT-X-PROGRAM-DATE-TIME:' in priv.read_text()
        def slices(p):
            d=run(ff,'-v','error','-i',p,'-map','0:v:0','-c:v','copy','-bsf:v','h264_mp4toannexb','-f','h264','-')
            return [n for n in re.split(b'\\x00\\x00(?:\\x00)?\\x01',d) if n and (n[0]&31) in (1,5)]
        assert slices(td/'avc.flv')==slices(priv) and movie(td/'avc.flv')==movie(priv)
        direct_pcm=pcm(priv);orig_pcm=pcm(td/'avc.flv');i=orig_pcm.find(direct_pcm[16384:20480])
        assert i>=0 and direct_pcm[16384:-8192]==orig_pcm[i:i+len(direct_pcm)-24576]
        print(f'System HLS {fmt}: all 66 original compressed AVC picture slices and original sound verified')
    radio=td/'radio.flv';run(ff,'-y','-v','error','-f','lavfi','-i','sine=sample_rate=44100','-t','3','-c:a','aac','-f','flv',radio)
    out=td/'radio-out';out.mkdir(exist_ok=True);stats=list(map(int,run(exe,radio,out,0,1,-1).split()))
    assert stats[0]==0 and stats[3]>100 and pcm(out/'index.m3u8')==pcm(radio)
    print('Audio-only broadcast: source AAC was preserved even with strict video decoding selected')

    long=td/'long.flv';run(ff,'-y','-v','error','-f','lavfi','-i','testsrc2=s=112x64:r=10','-f','lavfi','-i','sine=sample_rate=44100','-t','22','-c:v','libx264','-preset','ultrafast','-threads','2','-g','20','-c:a','aac','-f','flv',long)
    rolled=td/'rolled';rolled.mkdir(exist_ok=True);st=list(map(int,run(exe,long,rolled,0,1,-1).split()))
    manifest=(rolled/'index.m3u8').read_text();seq=int(re.search(r'#EXT-X-MEDIA-SEQUENCE:(\d+)',manifest)[1])
    assert st[0]==220 and seq>0 and len(re.findall(r'^part\d{8}\.m4s$',manifest,re.M))==6 and len(list(rolled.glob('*.m4s')))<=9
    print('22 second continuous decode: 220 frames; rolling sequence advanced, six published / at most nine on disk')
    d=bytearray((td/'fmp4.media').read_bytes());at=d.index(b'avc1',d.index(b'moov'));d[at:at+4]=b'encv'
    guarded=td/'protected.media';guarded.write_bytes(d);reject=td/'reject-cenc';reject.mkdir(exist_ok=True)
    r=subprocess.run([str(exe),str(guarded),str(reject),'0','1','-1','1'],capture_output=True)
    assert r.returncode!=0 and not (reject/'index.m3u8').exists()

    # Two external audio renditions with unrelated sequence numbers. Both lists slide once and
    # film/English/French use independent file clocks. PROGRAM-DATE-TIME anchors the real offset.
    paired=td/'paired';paired.mkdir(exist_ok=True)
    def install_sheet(key,clock,seq,offset_ms):
        full=paired/(key+'.m3u8')
        txt=full.read_text().splitlines()
        header=[r for r in txt if r.startswith(('#EXTM3U','#EXT-X-VERSION','#EXT-X-TARGETDURATION','#EXT-X-MAP'))]
        # Fast synthetic reload, whole original media retained.
        header=['#EXT-X-TARGETDURATION:1' if l.startswith('#EXT-X-TARGETDURATION') else l for l in header]
        pieces=[]
        for i,row in enumerate(txt):
            if row.startswith('#EXTINF:'):pieces.append((row,txt[i+1]))
        assert len(pieces)>=3
        from datetime import datetime,timedelta,timezone
        def sheet(path,first,last,end):
            date=datetime(2025,1,1,tzinfo=timezone.utc)+timedelta(milliseconds=offset_ms,seconds=sum(float(x[0][8:].split(',')[0]) for x in pieces[:first]))
            atom='#EXT-X-PROGRAM-DATE-TIME:'+date.isoformat(timespec='milliseconds').replace('+00:00','Z')
            path.write_text('\n'.join(header+['#EXT-X-MEDIA-SEQUENCE:'+str(seq+first),atom]+[v for pair in pieces[first:last] for v in pair]+(['#EXT-X-ENDLIST'] if end else []))+'\n')
        sheet(paired/('first-'+key+'.m3u8'),0,2,False);sheet(paired/('next-'+key+'.m3u8'),1,len(pieces),True)
    def playlist(source,key,kind,fmt,seq,offset):
        run(ff,'-y','-v','error','-i',source,'-map','0:'+kind,'-c','copy','-hls_time','2','-hls_segment_type',fmt,
            '-hls_fmp4_init_filename',key+'init.mp4','-hls_segment_filename',paired/(key+'%03d.'+('m4s' if fmt=='fmp4' else 'ts')),
            '-hls_list_size','0','-f','hls',paired/(key+'.m3u8'))
        install_sheet(key,None,seq,offset)
    playlist(td/'avc.flv','v','v','fmp4',420,0)
    for key,hz,fmt,seq,off in [('en',330,'fmp4',18,0),('fr',880,'mpegts',900,-250)]:
        original=paired/(key+'.m4a');run(ff,'-y','-v','error','-f','lavfi','-i',f'sine=frequency={hz}:sample_rate=48000','-t','5.55','-c:a','aac','-b:a','96k',original)
        playlist(original,key,'a',fmt,seq,off)
    (paired/'master.m3u8').write_text('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="lang",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="en.m3u8"\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="lang",NAME="Commentary",LANGUAGE="fr",DEFAULT=NO,URI="fr.m3u8"\n#EXT-X-STREAM-INF:CODECS="avc1.42E01F,mp4a.40.2",AUDIO="lang",BANDWIDTH=1200000\nv.m3u8\n')
    altcheck=td/'alt-source'
    run('swiftc',*[sw/'Live'/f for f in ['LiveHLSFeed.swift','LiveHLSFetch.swift','LiveHLSPlaylist.swift','LivePackedAudio.swift']],sw/'Network/ServerCertificatePolicy.swift',*[sw/'Playback'/f for f in ['MediaRange.swift','SegmentIndex.swift','RelayRange.swift']],native/'Checks/LiveAlternateCheck.swift','-o',altcheck)
    for key,fmt,delta in [('en',1,0),('fr',2,-250000)]:
        vv=paired/(key+'-video.bytes');aa=paired/(key+'-audio.bytes')
        print(run(altcheck,paired,'auto' if key=='en' else 'chosen',vv,aa,delta).decode().strip(),flush=True)
        out=paired/(key+'-result');out.mkdir(exist_ok=True)
        stats=list(map(int,run(exe,vv,out,0,1,-1,1,aa,fmt,delta).split()))
        assert stats[0]==66 and stats[3]>160,(key,stats)
        output=out/'index.m3u8';actual=packets(output,'a',True);reference=packets(paired/(key+'.m4a'),'a',True)
        ix=next(i for i,x in enumerate(reference) if x[1]==actual[0][1]);assert [x[1] for x in actual]==[x[1] for x in reference[ix:ix+len(actual)]],(key,ix)
        other=packets(paired/(('fr' if key=='en' else 'en')+'.m4a'),'a',True);assert actual[len(actual)//2][1] not in {x[1] for x in other}
        t0=packets(vv,'v')[0][0];vstart=packets(output,'v')[0][0]
        # For a track starting before video, packets prior to the first video key are excluded.
        # With a common wall clock, original sample spacing and the selected track's relative
        # arrival remain intact, including the initial AAC priming frame.
        observed=actual[0][0]-vstart
        expected=(reference[ix][0]-reference[0][0])+delta/1e6
        assert abs(observed-expected)<0.055,(key,observed,expected,ix,t0,vstart,actual[:1],reference[:1])
        cp=paired/(key+'-packet-copy');cp.mkdir(exist_ok=True)
        st=list(map(int,run(exe,vv,cp,2,1,-1,1,aa,fmt,delta).split()))
        original_video=slices(vv);repack=cp/'index.m3u8';assert st[0]==66 and slices(repack)==original_video
        ca=packets(repack,'a',True);start=next(i for i,x in enumerate(reference) if x[1]==ca[0][1])
        assert [x[1] for x in ca]==[x[1] for x in reference[start:start+len(ca)]]
        cp_lag=ca[0][0]-packets(repack,'v')[0][0]
        assert abs(cp_lag-(reference[start][0]-reference[0][0]+delta/1e6))<0.055,(key,cp_lag,delta,start)
        print(f'System alternate {key}: original compressed AVC plus {len(ca)} selected AAC packets, clock {cp_lag:.3f} s')
        more=paired/(key+'-reconnect');more.mkdir(exist_ok=True)
        offset,anchor=map(int,Path(str(vv)+'.clock').read_text().split(','))
        rvpath=str(vv)+'.again';rapath=str(aa)+'.again'
        stats2=list(map(int,run(exe,rvpath,more,0,1,-1,1,rapath,fmt,offset,anchor).split()))
        rs=packets(more/'index.m3u8','a',True);j=next(i for i,r in enumerate(reference) if r[1]==rs[0][1]);assert j>ix
        assert [r[1] for r in rs]==[r[1] for r in reference[j:j+len(rs)]] and 0<stats2[0]<stats[0]
        print(f'Reconnected {key}: later window, {stats2[0]} video frames and original chosen audio starting at packet {j}',flush=True)
        print(f'Selected {key} {fmt}: {stats[0]} real video frames, {len(actual)} original selected AAC packets and common-clock offset {observed:.4f}s',flush=True)

    packed=paired/'de.m4a';run(ff,'-y','-v','error','-f','lavfi','-i','sine=frequency=550:sample_rate=48000','-t','5.55','-c:a','aac','-b:a','96k',packed)
    adts=run(ff,'-v','error','-i',packed,'-map','0:a','-c','copy','-f','adts','-')
    frames=[];at=0
    while at<len(adts):
        assert adts[at]==255 and adts[at+1]&0xf6==0xf0
        n=((adts[at+3]&3)<<11)|(adts[at+4]<<3)|(adts[at+5]>>5);assert at+n<=len(adts) and n>7
        frames.append(adts[at:at+n]);at+=n
    videoTime=packets(paired/'en-video.bytes','v')[0][0]
    clock=round((videoTime+0.1875)*90000)
    def s32(n):return bytes((n>>v)&127 for v in (21,14,7,0))
    rows=[]
    for i in range(0,len(frames),94):
        clock90=(clock+round(i*1024*90000/48000))%(1<<33)
        priv=b'com.apple.streaming.transportStreamTimestamp\0'+clock90.to_bytes(8,'big')
        body=b'PRIV'+s32(len(priv))+b'\0\0'+priv
        payload=b'ID3\x04\0\0'+s32(len(body))+body+b''.join(frames[i:i+94])
        name='packed-'+str(i)+'.aac';(paired/name).write_bytes(payload)
        rows.extend([f'#EXTINF:{len(frames[i:i+94])*1024/48000:.8f},',name])
    (paired/'de.m3u8').write_text('\n'.join(['#EXTM3U','#EXT-X-TARGETDURATION:2']+rows+['#EXT-X-ENDLIST'])+'\n')
    install_sheet('de',None,809,0)
    for sheet in ('first-de.m3u8','next-de.m3u8'):
        p=paired/sheet;p.write_text('\n'.join(s for s in p.read_text().splitlines() if not s.startswith('#EXT-X-PROGRAM-DATE-TIME:'))+'\n')
    mas=paired/'master.m3u8';mas.write_text(mas.read_text().replace('#EXT-X-STREAM-INF:', '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="lang",NAME="Packed",LANGUAGE="de",DEFAULT=NO,URI="de.m3u8"\n#EXT-X-STREAM-INF:'))
    v=paired/'packed-v.bytes';a=paired/'packed-a.bytes';unknown=-(1<<63)
    print(run(altcheck,paired,'packed',v,a,unknown,clock).decode().strip(),flush=True)
    out=paired/'packed-result';out.mkdir(exist_ok=True)
    run(exe,v,out,0,1,-1,1,a,3,unknown,clock)
    actual=packets(out/'index.m3u8','a',True);reference=packets(packed,'a',True)
    ix=next(i for i,x in enumerate(reference) if x[1]==actual[0][1]);assert [x[1] for x in actual]==[x[1] for x in reference[ix:ix+len(actual)]]
    offset=actual[0][0]-packets(out/'index.m3u8','v')[0][0]
    assert abs(offset-(reference[ix][0]-reference[0][0]+0.1875))<0.055,(offset,ix,clock)
    print(f'Packed AAC / 33-bit ID3 PRIV clock: {len(actual)} original selected packets, {offset:.4f}s offset without program date',flush=True)

    # Other RFC 8216 packed renditions also keep their original compressed samples, including E-AC-3.
    from csv import reader as csv_rows
    for codec,demux in [('mp3',4),('ac3',5),('eac3',6)]:
        original=paired/('packed-source.'+codec)
        more=['-write_xing','0','-id3v2_version','0'] if codec=='mp3' else []
        run(ff,'-y','-v','error','-f','lavfi','-i','sine=frequency=720:sample_rate=48000','-t','5.55','-c:a','libmp3lame' if codec=='mp3' else codec,'-b:a','128k',*more,original)
        listing=paired/(codec+'.csv')
        run(ff,'-y','-v','error','-i',original,'-map','0:a','-c','copy','-f','segment','-segment_time','2',
            '-segment_list_type','csv','-segment_list',listing,'-segment_format',codec,*(['-segment_format_options','write_xing=0:id3v2_version=0'] if codec=='mp3' else []),paired/(codec+'-%03d.'+codec))
        entries=[]
        for name,start,end in csv_rows(listing.read_text().splitlines()):
            p=paired/Path(name).name;clock90=clock+round(float(start)*90000)
            priv=b'com.apple.streaming.transportStreamTimestamp\0'+clock90.to_bytes(8,'big')
            body=b'PRIV'+s32(len(priv))+b'\0\0'+priv;p.write_bytes(b'ID3\x04\0\0'+s32(len(body))+body+p.read_bytes())
            entries.extend([f'#EXTINF:{float(end)-float(start):.8f},',p.name])
        (paired/'de.m3u8').write_text('\n'.join(['#EXTM3U','#EXT-X-TARGETDURATION:2']+entries+['#EXT-X-ENDLIST'])+'\n');install_sheet('de',None,809,0)
        for sheet in ('first-de.m3u8','next-de.m3u8'):
            p=paired/sheet;p.write_text('\n'.join(l for l in p.read_text().splitlines() if not l.startswith('#EXT-X-PROGRAM-DATE-TIME:'))+'\n')
        v=paired/(codec+'-v.bytes');a=paired/(codec+'-a.bytes');run(altcheck,paired,'packed',v,a,unknown,clock)
        out=paired/(codec+'-result');out.mkdir(exist_ok=True)
        run(exe,v,out,0,1,-1,1,a,demux,unknown,clock)
        actual=packets(out/'index.m3u8','a',True);reference=packets(original,'a',True)
        ix=next(i for i,x in enumerate(reference) if x[1]==actual[0][1])
        assert [x[1] for x in actual]==[x[1] for x in reference[ix:ix+len(actual)]],codec
        offset=actual[0][0]-packets(out/'index.m3u8','v')[0][0]
        assert abs(offset-(reference[ix][0]-reference[0][0]+0.1875))<0.055,(codec,offset)
        print(f'Packed {codec.upper()}: {len(actual)} original samples and common-clock offset {offset:.4f}s')
