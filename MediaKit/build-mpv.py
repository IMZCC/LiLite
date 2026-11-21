#!/usr/bin/env python3
"""Pinned LGPL libmpv + libplacebo, static arm64 iOS, built natively on macOS."""
from pathlib import Path
import fcntl, hashlib, json, os, shutil, subprocess, sys, tarfile, tempfile, urllib.request

kit = Path(__file__).resolve().parent
# ios (device, default) or iossim (arm64 iOS Simulator).
mode = sys.argv[1] if len(sys.argv) == 2 else 'ios'
if mode not in ('ios', 'iossim'): raise SystemExit('usage: build-mpv.py [ios|iossim]')
sdkname = 'iphonesimulator' if mode == 'iossim' else 'iphoneos'
triple = 'arm64-apple-ios17.0-simulator' if mode == 'iossim' else 'arm64-apple-ios17.0'
base = Path(os.environ.get('PILI_MPV_CACHE', Path.home()/'.cache/piliplus-native/tools/mpv'))
base.mkdir(parents=True, exist_ok=True)

def run(args):
    subprocess.run([str(v) for v in args], check=True, stdout=sys.stderr)

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def source(name, version, url, sha):
    archive = base/(name+'-'+version+'.tar.gz')
    if not archive.exists():
        tmp = archive.with_suffix('.download')
        run(['curl', '--proto', '=https', '-fL', '--retry', '3', '--connect-timeout', '20', '--max-time', '600', url, '-o', tmp])
        if digest(tmp) != sha:
            raise RuntimeError(name+' source checksum mismatch')
        tmp.replace(archive)
    if digest(archive) != sha:
        raise RuntimeError(name+' source checksum mismatch')
    dest = base/(name+'-'+version)
    if not dest.exists():
        with tempfile.TemporaryDirectory(dir=base) as folder:
            with tarfile.open(archive) as tar:
                # Xcode's bundled Python 3.9 predates extraction filters; archives are pinned by SHA-256.
                if hasattr(tarfile, 'data_filter'): tar.extractall(folder, filter='data')
                else: tar.extractall(folder)
            children = list(Path(folder).iterdir())
            if len(children) != 1:
                raise RuntimeError('invalid archive root')
            children[0].replace(dest)
    return dest

with (base/(mode+'.lock')).open('a+b') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    ff = Path(subprocess.check_output(['bash', str(kit/'build-ffmpeg.sh'), mode], text=True).strip())
    ass = Path(subprocess.check_output(['python3', str(kit/'build-subtitles.py'), mode], text=True).strip())
    ismac = sys.platform == 'darwin'
    sdk = Path((mode == 'ios' and os.environ.get('PILI_IOS_SDK')) or (subprocess.check_output(['xcrun', '--sdk', sdkname, '--show-sdk-path'], text=True).strip() if ismac else str(Path.home()/'.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk')))
    patches = [kit/'patches/mpv-0.41.0-ios-chroma.patch', kit/'patches/mpv-0.41.0-render-caps.patch']
    key = hashlib.sha256((digest(__file__)+"".join(digest(p) for p in patches)+str(ff)+str(ass)+str(sdk)).encode()).hexdigest()[:16]
    out = base/(mode+'-'+key)
    prefix = out/'vendor'
    if (prefix/'.ready').exists():
        print(prefix)
        sys.exit(0)
    out.mkdir(parents=True, exist_ok=True)
    bundle = Path(os.environ.get('PILI_DECODER_CACHE', Path.home()/'.cache/piliplus-native/tools/decoder-build'))/'hosttools/usr'
    os.environ['PATH'] = str(bundle/'bin')+os.pathsep+os.environ['PATH']
    os.environ['PYTHONPATH'] = str(bundle/'lib/python3/dist-packages')+os.pathsep+os.environ.get('PYTHONPATH', '')
    def tool(name):
        value = shutil.which(name)
        if not value: raise RuntimeError('Missing build tool '+name)
        return value
    def apple(name):
        return subprocess.check_output(['xcrun','--sdk',sdkname,'-f',name], text=True).strip() if ismac else tool(name)
    floats = source('fast_float','8.0.2','https://codeload.github.com/fastfloat/fast_float/tar.gz/refs/tags/v8.0.2','e14a33089712b681d74d94e2a11362643bd7d769ae8f7e7caefe955f57f7eacd')
    vulkan = source('vulkan-headers','1.4.321','https://codeload.github.com/KhronosGroup/Vulkan-Headers/tar.gz/refs/tags/v1.4.321','7c1874f9186d9e7d5245e279cdccaa77a66ed8f52871b428630aeb771dc7623c')
    args = ['-target',triple,'-isysroot',str(sdk),'-I'+str(floats/'include'),'-I'+str(vulkan/'include')]
    ld = args[:] if ismac else args+['--ld-path='+os.environ.get('PILI_IOS_LINKER',str(Path.home()/'.swiftpm/swift-sdks/darwin.artifactbundle/toolset/bin/ld64.lld')),'-Wl,-platform_version,ios,17.0,'+json.loads((sdk/'SDKSettings.json').read_text())['Version']]
    pc = [str(p/'lib/pkgconfig') for p in (prefix, ff, ass)]
    os.environ['PKG_CONFIG_LIBDIR'] = os.pathsep.join(pc)
    os.environ['PKG_CONFIG_PATH'] = os.pathsep.join(pc)
    cross = out/'cross.ini'
    cross.write_text("[binaries]\nc="+repr(apple('clang'))+"\ncpp="+repr(apple('clang++'))+"\nobjc="+repr(apple('clang'))+"\nar="+repr(apple('ar' if ismac else 'llvm-ar'))+"\npkg-config="+repr(tool('pkg-config'))+"\n[host_machine]\nsystem='darwin'\ncpu_family='aarch64'\ncpu='aarch64'\nendian='little'\n[properties]\nneeds_exe_wrapper=true\npkg_config_libdir="+repr(pc)+"\n[built-in options]\nc_args="+repr(args)+"\ncpp_args="+repr(args)+"\nobjc_args="+repr(args)+"\nc_link_args="+repr(ld)+"\ncpp_link_args="+repr(ld)+"\nobjc_link_args="+repr(ld)+"\n")
    upstream_mpv = source('mpv','0.41.0','https://codeload.github.com/mpv-player/mpv/tar.gz/refs/tags/v0.41.0','ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209')
    mpv = out/'mpv-src'
    if not mpv.exists():
        with tempfile.TemporaryDirectory(dir=out) as staging:
            tree = Path(staging)/'mpv'
            shutil.copytree(upstream_mpv, tree)
            for patch in patches:
                run(['patch','-d',tree,'-p1','-i',patch])
            # Upstream enables ObjC through macOS/Cocoa checks disabled in the iOS build.
            manifest = tree/'meson.build'
            text = manifest.read_text()
            manifest.write_text(text.replace("project('mpv',\n        'c',", "project('mpv',\n        'c', 'objc',"))
            tree.replace(mpv)
    placebo = source('libplacebo','7.360.1','https://codeload.github.com/haasn/libplacebo/tar.gz/refs/tags/v7.360.1','d05fdf90bea2f629eaa2d115e909fd356388ac639e54f77b87a018a6d76224bd')
    common = ['--cross-file',cross,'--prefix='+str(prefix),'--libdir=lib','--buildtype=release','--wrap-mode=nofallback','-Ddefault_library=static','-Db_staticpic=true','-Dauto_features=disabled']
    recipes = [
        ('placebo',placebo,['-Ddemos=false','-Dtests=false','-Dvulkan=disabled','-Dopengl=disabled','-Dshaderc=disabled','-Dglslang=disabled']),
        ('mpv',mpv,['-Dgpl=false','-Dcplayer=false','-Dlibmpv=true','-Dbuild-date=false','-Dgl=enabled','-Dplain-gl=enabled','-Dios-gl=enabled','-Daudiounit=enabled','-Diconv=enabled','-Dzlib=enabled','-Dlua=disabled'])
    ]
    for name, src, flags in recipes:
        build = out/name
        if not (build/'build.ninja').exists():
            run([tool('meson'),'setup',build,src,*common,*flags])
        run([tool('ninja'),'-C',build,'-j'+os.environ.get('PILI_MPV_JOBS','8'),'install'])
    for name in ['mpv','placebo']:
        if not (prefix/'lib'/('lib'+name+'.a')).is_file(): raise RuntimeError('missing '+name)
    config = (out/'mpv/config.h').read_text()
    for feature in ['HAVE_IOS_GL','HAVE_AUDIOUNIT','HAVE_GL']:
        if '#define '+feature+' 1' not in config: raise RuntimeError('missing '+feature)
    if '#define HAVE_GPL 0' not in config: raise RuntimeError('expected LGPL build')
    (prefix/'build-receipt.json').write_text(json.dumps({'mpv':'0.41.0','libplacebo':'7.360.1','ffmpeg':str(ff),'subtitles':str(ass),'sdk':str(sdk),'options':[(n,f) for n,s,f in recipes]},indent=2)+'\n')
    (prefix/'.ready').touch()
    print(prefix)
