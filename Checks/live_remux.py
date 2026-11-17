"""Offline video/audio equivalence, pinned FFmpeg C bridge, window retention and cancellation.
PILI_QA_FFMPEG may name a host ffmpeg CLI with libx264 and AAC for synthetic fixtures.
"""
import os, re, shutil, subprocess, tempfile
from pathlib import Path

native=Path(__file__).resolve().parents[1]
kit=native/"MediaKit"; source=kit/"Sources/CLiveRemux"
ff=os.environ.get("PILI_QA_FFMPEG") or shutil.which("ffmpeg") or next((str(p) for p in [Path.home()/".cache/piliplus-native/tools/live-qa/ffmpeg"] if p.is_file()),None)
if not ff:raise SystemExit("Set PILI_QA_FFMPEG to a host ffmpeg with libx264; this is a fixture tool, not an app dependency")
pref=Path(subprocess.check_output(["bash",str(kit/"build-ffmpeg.sh"),"host"],text=True).strip())
def run(cmd,**kwargs):
    result=subprocess.run(list(map(str,cmd)),**kwargs)
    if result.returncode:
        if result.stderr: print(result.stderr.decode(errors="replace")[-2000:],flush=True)
        result.check_returncode()
    return result
def clip(path,sec):
    run([ff,"-v","error","-f","lavfi","-i","testsrc2=s=128x72:r=12","-f","lavfi","-i","sine=frequency=440:sample_rate=44100","-t",sec,"-c:v","libx264","-preset","ultrafast","-g",12,"-bf",2,"-sc_threshold",0,"-c:a","aac","-f","flv",path])
def hashes(path,kind):
    s=run([ff,"-v","error","-i",path,"-map","0:"+kind+":0","-f","framemd5","-"],stdout=subprocess.PIPE).stdout.decode()
    return [line.rsplit(",",1)[-1].strip() for line in s.splitlines() if line and not line.startswith("#")]
with tempfile.TemporaryDirectory(prefix="pili-remux-") as tmp:
    root=Path(tmp); exe=root/"remux"
    run(["cc","-std=c11","-Werror=implicit-function-declaration","-O2","-I"+str(pref/"include"),"-I"+str(source/"include"),source/"LiveRemux.c",kit/"Checks/remux_file.c","-L"+str(pref/"lib"),"-lavformat","-lavcodec","-lswresample","-lavutil","-ldav1d","-lm","-lpthread","-o",exe])
    f=root/"input.flv";clip(f,"7"); out=root/"short";out.mkdir()
    run([exe,f,out],stderr=subprocess.PIPE)
    playlist=out/"index.m3u8"; manifest=playlist.read_text()
    assert '#EXT-X-MAP:URI="init.mp4"' in manifest and "#EXT-X-INDEPENDENT-SEGMENTS" in manifest and "#EXT-X-ENDLIST" in manifest
    original=hashes(f,"v"); playable=hashes(playlist,"v");assert len(original)==84 and original==playable,(len(original),len(playable))
    orig_audio=hashes(f,"a"); audio=hashes(playlist,"a")
    assert len(audio)>260 and abs(len(orig_audio)-len(audio))<=4 and audio[4:-4]==orig_audio[orig_audio.index(audio[4]):][:len(audio)-8],(len(orig_audio),len(audio))
    for name,encoder,opts in [("hevc","libx265",["-preset","ultrafast","-x265-params","log-level=error:pools=1:frame-threads=1"]),("av1","libaom-av1",["-cpu-used","8","-threads","2"])]:
        ef=root/(name+".flv"); eo=root/name;eo.mkdir()
        run([ff,"-v","error","-f","lavfi","-i","testsrc2=s=112x64:r=10","-f","lavfi","-i","sine=sample_rate=44100","-t","3","-c:v",encoder,*opts,"-g",10,"-c:a","aac","-f","flv",ef])
        run([exe,ef,eo],stderr=subprocess.PIPE)
        frames=hashes(eo/"index.m3u8","v")
        assert len(frames)==30 and frames==hashes(ef,"v") and len(hashes(eo/"index.m3u8","a"))>100,name
        print(f"Enhanced FLV {name}: {len(frames)} decoded frames match")
    radio=root/"radio.flv"; ro=root/"radio";ro.mkdir()
    run([ff,"-v","error","-f","lavfi","-i","sine=sample_rate=44100","-t","3","-c:a","aac","-f","flv",radio])
    run([exe,radio,ro],stderr=subprocess.PIPE)
    track=hashes(ro/"index.m3u8","a");assert len(track)>100 and track[4:-4]==hashes(radio,"a")[4:-4]
    print(f"Audio-only FLV: {len(track)} AAC frames")
    long=root/"long.flv";clip(long,"23"); window=root/"window";window.mkdir()
    run([exe,long,window],stderr=subprocess.PIPE)
    m=(window/"index.m3u8").read_text(); segments=re.findall(r"^part[0-9]{8}\.m4s$",m,re.M)
    assert len(segments)==6 and int(re.search(r"#EXT-X-MEDIA-SEQUENCE:(\d+)",m)[1])>0
    assert all((window/n).is_file() for n in segments) and len(list(window.glob("*.m4s")))<=9
    cancelled=root/"cancel";cancelled.mkdir();r=subprocess.run([exe,f,cancelled,"4096"],capture_output=True)
    assert r.returncode!=0 and not (cancelled/"index.m3u8").exists()
    print(f"FLV to fMP4 HLS: {len(playable)} matching decoded video frames, {len(audio)} AAC frames, {len(segments)} rolling segments, cancellation passed")
