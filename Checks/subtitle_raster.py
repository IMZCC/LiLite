"""Exercise the actual libass rasterizer at known times; no network access after the source build."""
from pathlib import Path
import ctypes as C, subprocess as S, os, tempfile, sys, hashlib, json, shutil
n=Path(__file__).resolve().parents[1];k=n/'MediaKit';cl=k/'Sources/CLiveRemux';inc=cl/'include'
script=r"""[Script Info]
ScriptType: v4.00+
PlayResX: 320
PlayResY: 180
ScaledBorderAndShadow: yes
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,26,&H000000FF,&H0000FF00,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:02.00,Default,,0,0,0,,{\p1\an7\move(20,20,180,20,0,1000)\bord0\shad0\1c&H0000FF&}m 0 0 l 40 0 40 20 0 20
Dialogue: 1,0:00:02.00,0:00:04.00,Default,,0,0,0,,{\pos(30,100)\kf100}Test{\kf100}ing
Dialogue: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,{\p1\an7\pos(25,30)\1a&H80&}m 0 0 l 40 0 40 20 0 20
""".encode()
class Frame(C.Structure):
 _fields_=[(v,C.c_int) for v in ['x','y','w','h','stride']]+[('pixels',C.c_void_p)]
with tempfile.TemporaryDirectory(prefix='pili-caption-raster-') as workspace:
 d=Path(workspace)
 def vendor(mode):
  return Path(S.check_output([sys.executable,k/'build-subtitles.py',mode],text=True).strip())
 host=vendor('host')
 S.run(['cc','-O2','-shared','-fPIC','-I'+str(inc),'-I'+str(host/'include'),cl/'PiliASS.c','-L'+str(host/'lib'),'-lass','-lharfbuzz','-lfreetype','-lfribidi','-lstdc++','-lz','-lm','-o',d/'render.so'],check=True)
 lib=C.CDLL(str(d/'render.so'));lib.pili_ass_open.restype=C.c_void_p;lib.pili_ass_open.argtypes=[C.c_char_p,C.c_size_t,C.c_char_p]
 lib.pili_ass_render.argtypes=[C.c_void_p,C.c_int,C.c_int,C.c_int,C.c_int,C.c_int64,C.POINTER(Frame)]
 lib.pili_ass_free.argtypes=[C.c_void_p];lib.pili_ass_events.argtypes=[C.c_void_p]
 fonts=sorted(Path('/usr/share/fonts').rglob('*.ttf'));assert fonts,'Install a system font for the host text-cue check'
 p=lib.pili_ass_open(script,len(script),os.fsencode(fonts[0]));assert p and lib.pili_ass_events(p)==3
 def draw(ms,w=320,h=180):
  f=Frame();r=lib.pili_ass_render(p,w,h,320,180,ms,C.byref(f));data=C.string_at(f.pixels,f.stride*f.h) if f.pixels else b''
  if not data:return r,(0,0,0,0),data
  visible=[(i%f.w,i//f.w) for i,v in enumerate(data[3::4]) if v]
  if not visible:return r,(0,0,0,0),b''
  xs,ys=zip(*visible);x0,x1=min(xs),max(xs)+1;y0,y1=min(ys),max(ys)+1
  cropped=b''.join(data[y*f.stride+x0*4:y*f.stride+x1*4] for y in range(y0,y1))
  return r,(f.x+x0,f.y+y0,x1-x0,y1-y0),cropped
 try:
  r,b0,p0=draw(0);assert r==1 and b0==(20,20,40,20),b0
  assert p0.count(b'\xff\x00\x00\xff')>=700
  assert draw(0)[0]==0
  r,b5,p5=draw(500);assert b5[0]==100 and b5[1:]==b0[1:] and p5==p0
  r,b1,p1=draw(1100);assert b1[0]==180 and b1[1:]==b0[1:]
  _,_,k0=draw(2020);_,_,k1=draw(2900);assert k0 and k1 and hashlib.sha256(k0).digest()!=hashlib.sha256(k1).digest()
  _,bf,fade=draw(4500);assert any(124<=fade[i]<=128 and fade[i]==fade[i+3] for i in range(0,len(fade),4))
  r,_,empty=draw(5500);assert r==1 and empty==b''
  r,b2,p2=draw(500);assert b2==b5 and p2==p5
  _,b3,scaled=draw(500,640,360);assert b3==(200,40,80,40) and len(scaled)==80*40*4
  print('libass 0.17.5: exact 40 x 20 red vector at x=20/100/180; static frame reuse, progressive karaoke color, premultiplied transparency, end, backward seek and 2x scaling passed')
 finally:lib.pili_ass_free(p)
 if '--ios' in sys.argv:
  ios=vendor('ios')
  sdk=Path(os.environ.get('PILI_IOS_SDK',Path.home()/'.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk'))
  linker=os.environ.get('PILI_IOS_LINKER',str(Path.home()/'.swiftpm/swift-sdks/darwin.artifactbundle/toolset/bin/ld64.lld'))
  version=json.loads((sdk/'SDKSettings.json').read_text())['Version']
  (d/'check.c').write_text('#include "PiliASS.h"\nint main(void){PiliASSFrame f;return pili_ass_render(0,1,1,1,1,0,&f);}\n')
  S.run(['clang','-target','arm64-apple-ios17.0','-isysroot',str(sdk),'--ld-path='+linker,'-Wl,-platform_version,ios,17.0,'+version,'-I'+str(inc),'-I'+str(ios/'include'),d/'check.c',cl/'PiliASS.c','-L'+str(ios/'lib'),'-lass','-lharfbuzz','-lfreetype','-lfribidi','-liconv','-lz','-lc++','-framework','CoreText','-framework','CoreFoundation','-o',d/'check'],check=True)
  assert 'Mach-O 64-bit arm64' in S.check_output(['file',d/'check'],text=True)
  print('iPhone arm64 Mach-O links the adapter, four fixed static libraries, CoreText and platform SDK; no simulator or device run')
