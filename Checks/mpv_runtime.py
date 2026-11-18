#!/usr/bin/env python3
"""Exercise the actual CMPV loader against pinned mpv on Linux; no device or account needed."""
from pathlib import Path
import hashlib, http.server, json, os, re, shutil, subprocess, tempfile, threading, urllib.parse

root = Path(__file__).resolve().parents[1]
base = Path(os.environ.get('PILI_MPV_CACHE', Path.home()/'.cache/piliplus-native/tools/mpv'))
def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)
ff = Path(subprocess.check_output(['bash',str(root/'MediaKit/build-ffmpeg.sh'),'host'],text=True).strip())
ass = Path(subprocess.check_output(['python3',str(root/'MediaKit/build-subtitles.py'),'host'],text=True).strip())
patch = root/'MediaKit/patches/mpv-0.41.0-render-caps.patch'
key = hashlib.sha256(patch.read_bytes()+str(ff).encode()+str(ass).encode()).hexdigest()[:16]
work = base/('runtime-check-'+key)
work.mkdir(parents=True, exist_ok=True)
mpv_source = work/'mpv-src'
if not mpv_source.is_dir():
    with tempfile.TemporaryDirectory(dir=work) as staging:
        tree = Path(staging)/'mpv'
        shutil.copytree(base/'mpv-0.41.0', tree)
        run(['patch','-d',tree,'-p1','-i',patch])
        tree.replace(mpv_source)
bundle = Path(os.environ.get('PILI_DECODER_CACHE',Path.home()/'.cache/piliplus-native/tools/decoder-build'))/'hosttools/usr'
os.environ['PATH'] = str(bundle/'bin')+os.pathsep+os.environ['PATH']
os.environ['PYTHONPATH'] = str(bundle/'lib/python3/dist-packages')+os.pathsep+os.environ.get('PYTHONPATH','')
os.environ['CC'] = '/usr/bin/gcc'
os.environ['CXX'] = '/usr/bin/g++'
os.environ['OBJC'] = shutil.which('clang')
prefix = work/'vendor'
os.environ['PKG_CONFIG_PATH'] = os.pathsep.join(str(p/'lib/pkgconfig') for p in [prefix,ff,ass])+':/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/share/pkgconfig'
os.environ['PKG_CONFIG_LIBDIR'] = os.environ['PKG_CONFIG_PATH']
options = ['--prefix='+str(prefix),'--libdir=lib','--buildtype=release','--wrap-mode=nofallback',
           '-Ddefault_library=static','-Dauto_features=disabled','-Db_staticpic=true']
for name,source,flags in [
    ('placebo','libplacebo-7.360.1',['-Ddemos=false','-Dtests=false',
      '-Dc_args=-I'+str(base/'vulkan-headers-1.4.321/include'),
      '-Dcpp_args=-I'+str(base/'fast_float-8.0.2/include')]),
    ('mpv','mpv-0.41.0',['-Dgpl=false','-Dcplayer=false','-Dlibmpv=true','-Dgl=disabled','-Dlua=disabled',
      '-Dbuild-date=false','-Diconv=enabled','-Dzlib=enabled']),
]:
    build = work/name
    if not (build/'build.ninja').exists(): run(['meson','setup',build,mpv_source if name == 'mpv' else base/source,*options,*flags])
    run(['ninja','-C',build,'-j4','install'])

fixture = work/'fixtures'
fixture.mkdir(exist_ok=True)
generator = os.environ.get('PILI_QA_FFMPEG',str(Path.home()/'.cache/piliplus-native/tools/live-qa/ffmpeg'))
for name,flags in [
    ('video.mp4',['-f','lavfi','-i','testsrc2=size=160x90:rate=24','-c:v','libx264','-pix_fmt','yuv420p','-an']),
    ('audio.m4a',['-f','lavfi','-i','sine=frequency=523:sample_rate=48000','-c:a','aac','-vn']),
]:
    if not (fixture/name).exists(): run([generator,'-hide_banner','-loglevel','error',*flags,'-t','12','-movflags','+faststart',fixture/name])
portrait = fixture/'rotated-white.mp4'
if not portrait.exists():
    white = fixture/'white.mp4'
    run([generator,'-v','error','-y','-f','lavfi','-i','color=white:s=160x90:r=24',
         '-t','2','-c:v','libx264',white])
    run([generator,'-v','error','-y','-display_rotation','90','-i',white,'-c','copy',portrait])
flags = subprocess.check_output(['pkg-config','--static','--cflags','--libs','mpv'],text=True).split()
binary = work/'mpv-check'
run(['/usr/bin/gcc','-std=c11','-D_DEFAULT_SOURCE','-I'+str(root/'MediaKit/Sources/CMPV/include'),
     root/'Checks/mpv_runtime.c',root/'MediaKit/Sources/CMPV/PiliMPV.c',*flags,'-lstdc++','-o',binary])

requests = []
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self,*args,**kwargs): super().__init__(*args,directory=str(fixture),**kwargs)
    def log_message(self,*args): pass
    def do_GET(self):
        requests.append((urllib.parse.urlparse(self.path).path,self.headers.get('Referer'),self.headers.get('User-Agent')))
        if self.headers.get('Referer') != 'https://www.bilibili.com/' or 'Mozilla/5.0' not in self.headers.get('User-Agent',''):
            self.send_error(403)
            return
        name = urllib.parse.urlparse(self.path).path.lstrip('/')
        if name not in ('video.mp4','audio.m4a'):
            self.send_error(404)
            return
        file = fixture/name
        size = file.stat().st_size
        begin, end = 0, size-1
        requested = self.headers.get('Range')
        if requested:
            match = re.fullmatch(r'bytes=(\d+)-(\d*)',requested)
            if not match or int(match[1]) >= size:
                self.send_error(416)
                return
            begin = int(match[1])
            end = min(end,int(match[2])) if match[2] else end
        self.send_response(206 if requested else 200)
        self.send_header('Accept-Ranges','bytes')
        self.send_header('Content-Type','video/mp4' if name.endswith('.mp4') else 'audio/mp4')
        self.send_header('Content-Length',str(end-begin+1))
        if requested: self.send_header('Content-Range',f'bytes {begin}-{end}/{size}')
        self.end_headers()
        try:
            with file.open('rb') as media:
                media.seek(begin)
                self.wfile.write(media.read(end-begin+1))
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
thread = threading.Thread(target=server.serve_forever,daemon=True)
thread.start()
try:
    address = 'http://127.0.0.1:'+str(server.server_port)
    result = subprocess.run([str(binary),address+'/video.mp4',address+'/audio.m4a?token=a:b,c'],capture_output=True,text=True,timeout=45)
    if result.returncode:
        print(result.stdout, flush=True)
        print(result.stderr, flush=True)
        result.check_returncode()
    print(result.stdout)
    assert {'/video.mp4','/audio.m4a'} <= {r[0] for r in requests}, requests
    receipt = {'result':'pass','checks':json.loads(result.stdout),'http_requests':len(requests),
               'headers':'Referer and User-Agent required for every video/audio request',
               'scope':'Linux headless pinned libmpv + production CMPV loader; iOS GL/audio output require device validation'}
    destination = root/'dist/mpv-runtime-check.json'
    destination.write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
    print(destination)
    pip_binary = work/'mpv-pip-check'
    run(['/usr/bin/gcc','-std=c11','-D_DEFAULT_SOURCE','-I'+str(root/'MediaKit/Sources/CMPV/include'),
         root/'Checks/mpv_pip_runtime.c',root/'MediaKit/Sources/CMPV/PiliMPV.c',*flags,'-lstdc++','-lpthread','-o',pip_binary])
    result = subprocess.run([str(pip_binary),address+'/video.mp4',address+'/audio.m4a?token=a:b,c',str(portrait)],capture_output=True,text=True,timeout=45)
    if result.returncode:
        print(result.stdout, flush=True)
        print(result.stderr, flush=True)
        result.check_returncode()
    print(result.stdout)
    (root/'dist/mpv-pip-runtime-check.json').write_text(json.dumps({'result':'pass','checks':json.loads(result.stdout),
        'scope':'Production CMPV software renderer and live context replacement on Linux; AVKit, IOSurface, GLES and VideoToolbox remain device checks'},indent=2)+'\n')
finally:
    server.shutdown()
    server.server_close()
