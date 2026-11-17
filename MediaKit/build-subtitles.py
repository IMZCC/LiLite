#!/usr/bin/env python3
"""Build the same static ASS renderer from fixed upstream sources on the host and iOS."""
from pathlib import Path
import fcntl, hashlib, json, os, shutil, subprocess, sys, tarfile, tempfile, urllib.request
from contextlib import contextmanager
mode=sys.argv[1] if len(sys.argv)==2 else 'ios'
if mode not in ('host','ios'): raise SystemExit('usage: build-subtitles.py host|ios')
kit=Path(__file__).resolve().parent
base=Path(os.environ.get('PILI_SUBTITLE_CACHE',Path.home()/'.cache/piliplus-native/tools/subtitle'))
# Explicit local relink: keep the default/pinned build and its cache untouched.
relink=os.environ.get('PILI_SUBTITLE_RELINK_PREFIX')
if relink:
 prefix=Path(relink).expanduser().resolve()
 if not (prefix/'include/ass/ass.h').is_file() or not all((prefix/'lib'/('lib'+name+'.a')).is_file() for name in ('ass','harfbuzz','freetype','fribidi')):
  raise SystemExit('PILI_SUBTITLE_RELINK_PREFIX must be a complete alternate subtitle prefix')
 print(prefix);sys.exit(0)
base.mkdir(parents=True,exist_ok=True)
sources=[
 ('freetype','2.15.0','https://download-mirror.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz','93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5',['-Dharfbuzz=disabled','-Dtests=disabled']),
 ('fribidi','1.0.18','https://github.com/fribidi/fribidi/releases/download/v1.0.18/fribidi-1.0.18.tar.xz','1de5e8073d035388b71d0b2d452b1da1f8caeea8a7702997b401fe1b6250727f',['-Ddocs=false','-Dbin=false','-Dtests=false']),
 ('harfbuzz','15.1.0','https://github.com/harfbuzz/harfbuzz/releases/download/15.1.0/harfbuzz-15.1.0.tar.xz','0fc7c565443a5f4be7da65ac5ee5bd737d9b158dc908708b7689a0a5796b0c8d',['-Dfreetype=enabled','-Dtests=disabled','-Dutilities=disabled','-Dsubset=disabled','-Draster=disabled','-Dvector=disabled','-Dgpu=disabled']),
 ('libass','0.17.5','https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz','2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc',['-Dcoretext='+('enabled' if mode=='ios' else 'disabled'),'-Drequire-system-font-provider='+('true' if mode=='ios' else 'false')])
]
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for d in iter(lambda:f.read(512*1024),b''):h.update(d)
 return h.hexdigest()
@contextmanager
def lock(p):
 with p.open('a+b') as f:
  fcntl.flock(f,fcntl.LOCK_EX)
  yield
def source(name,version,url,sha):
 dest=base/(name+'-'+version)
 with lock(base/'sources.lock'):
  archive=base/url.rsplit('/',1)[1]
  if not archive.is_file():
   with tempfile.TemporaryDirectory(dir=base) as tmp:
    p=Path(tmp)/'download'
    with urllib.request.urlopen(url,timeout=120) as res,p.open('wb') as f:shutil.copyfileobj(res,f)
    if digest(p)!=sha:raise ValueError(name+' source checksum mismatch')
    p.replace(archive)
  if digest(archive)!=sha:raise ValueError(name+' source checksum mismatch')
  if not (dest/'meson.build').is_file():
   with tempfile.TemporaryDirectory(dir=base) as tmp:
    with tarfile.open(archive) as t:
     if hasattr(tarfile,'data_filter'):t.extractall(tmp,filter='data')
     else:
      if any(v.name.startswith('/') or '..' in Path(v.name).parts for v in t):raise ValueError('invalid source archive')
      t.extractall(tmp)
    (Path(tmp)/dest.name).replace(dest)
 return dest
def tool(name):
 path=shutil.which(name)
 if not path:raise RuntimeError('Install '+name+' or run the MediaKit tool bootstrap before rebuilding subtitles')
 return path
with lock(base/(mode+'.lock')):
 key=digest(Path(__file__))[:12]
 out=base/('build-'+mode+'-'+key);out.mkdir(exist_ok=True)
 prefix=out/'vendor'
 if not (prefix/'.ready').exists():
  if not shutil.which('meson') or not shutil.which('ninja'):
   bundle=Path(os.environ.get('PILI_DECODER_CACHE',Path.home()/'.cache/piliplus-native/tools/decoder-build'))/'hosttools/usr'
   os.environ['PATH']=str(bundle/'bin')+os.pathsep+os.environ['PATH']
   os.environ['PYTHONPATH']=str(bundle/'lib/python3/dist-packages')+os.pathsep+os.environ.get('PYTHONPATH','')
  meson,ninja=tool('meson'),tool('ninja')
  pc=prefix/'lib/pkgconfig';os.environ['PKG_CONFIG_PATH']=str(pc)
  opts=['-Ddefault_library=static','-Db_staticpic=true','-Dauto_features=disabled','--wrap-mode=nofallback','--buildtype=release','--libdir=lib','--prefix='+str(prefix)]
  if mode=='ios':
   ismac=sys.platform=='darwin'
   def apple(name):return subprocess.check_output(['xcrun','--sdk','iphoneos','-f',name],text=True).strip() if ismac else tool(name)
   def afile(s):return "'"+str(s).replace("'","\\'")+"'"
   sdk=os.environ.get('PILI_IOS_SDK') or (subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip() if ismac else str(Path.home()/'.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk'))
   args=['-target','arm64-apple-ios17.0','-isysroot',sdk]
   ld=args[:] if ismac else args+['--ld-path='+os.environ.get('PILI_IOS_LINKER',str(Path.home()/'.swiftpm/swift-sdks/darwin.artifactbundle/toolset/bin/ld64.lld')),'-Wl,-platform_version,ios,17.0,'+json.loads((Path(sdk)/'SDKSettings.json').read_text())['Version']]
   cfg=out/'cross.ini';cfg.write_text("[binaries]\nc="+afile(apple('clang'))+"\ncpp="+afile(apple('clang++'))+"\nar="+afile(apple('ar' if ismac else 'llvm-ar'))+"\npkg-config="+afile(tool('pkg-config'))+"\n[host_machine]\nsystem='darwin'\ncpu_family='aarch64'\ncpu='aarch64'\nendian='little'\n[properties]\nneeds_exe_wrapper=true\npkg_config_libdir="+afile(pc)+"\n[built-in options]\nc_args="+repr(args)+"\ncpp_args="+repr(args)+"\nc_link_args="+repr(ld)+"\ncpp_link_args="+repr(ld)+"\n")
   os.environ['PKG_CONFIG_LIBDIR']=str(pc);opts+=['--cross-file',str(cfg)]
  for n,v,url,sha,options in sources:
   src=source(n,v,url,sha);build=out/n
   if not (build/'build.ninja').exists():subprocess.run([meson,'setup',str(build),str(src),*opts,*options],stdout=sys.stderr,check=True)
   subprocess.run([ninja,'-C',str(build),'-j'+os.environ.get('PILI_SUBTITLE_JOBS','6'),'install'],stdout=sys.stderr,check=True)
  for name in ['ass','fribidi','harfbuzz','freetype']:
   if not (prefix/'lib'/('lib'+name+'.a')).is_file():raise ValueError('missing '+name)
  (prefix/'.ready').touch()
 print(prefix)
