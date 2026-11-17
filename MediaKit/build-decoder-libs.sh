#!/usr/bin/env bash
# Reproducible FFmpeg build for live remux and self-contained software video decoding.
set -euo pipefail
version=9.0.2
sha=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
mode=${1:-ios}
case "$mode" in ios|host) ;; *) echo 'usage: build-ffmpeg.sh ios|host' >&2;exit 2;; esac
base="${PILI_MEDIA_CACHE:-$HOME/.cache/piliplus-native/tools/ffmpeg-$version}"
mkdir -p "$base/download"
# Keep configure, make and install paired when verification and IPA packaging use one cache.
# Python/fcntl is also available on the Darwin host, where the flock CLI is not installed.
lock_file="$base/$mode.build.lock"
if [[ "${PILI_FFMPEG_LOCK_FILE:-}" != "$lock_file" ]]; then
  exec python3 - "$0" "$mode" "$lock_file" <<'PYLOCK'
import fcntl,os,sys
script,mode,lock=sys.argv[1:]
fd=os.open(lock,os.O_RDWR|os.O_CREAT,0o600)
fcntl.flock(fd,fcntl.LOCK_EX)
os.set_inheritable(fd,True)
os.environ["PILI_FFMPEG_LOCK_FILE"]=lock
os.execvp("bash",["bash",script,mode])
PYLOCK
fi
archive="$base/download/ffmpeg-$version.tar.xz"
sum() { if command -v sha256sum >/dev/null;then sha256sum "$1" | cut -d' ' -f1;else shasum -a 256 "$1" | cut -d' ' -f1;fi; }
if [[ ! -f "$archive" ]];then
  tmp=$(mktemp "$base/download/ffmpeg.XXXXXX")
  trap 'rm -f -- "$tmp"' EXIT
  curl --proto '=https' -fsSL --retry 2 --max-time 180 "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" -o "$tmp"
  [[ $(sum "$tmp") == "$sha" ]] || { echo "FFmpeg archive checksum mismatch" >&2;exit 1; }
  mv -- "$tmp" "$archive"
fi
[[ $(sum "$archive") == "$sha" ]] || { echo "FFmpeg archive checksum mismatch" >&2;exit 1; }
src="$base/ffmpeg-$version"
if [[ ! -f "$src/configure" ]];then tar -xf "$archive" -C "$base";fi
kit=$(cd "$(dirname "$0")" && pwd)
dav=$(bash "$kit/build-dav1d.sh" "$mode")
export PKG_CONFIG_LIBDIR="$dav/lib/pkgconfig"
export PKG_CONFIG_PATH="$dav/lib/pkgconfig"
config=(--disable-everything --disable-autodetect --enable-network --disable-doc --disable-programs
 --disable-avdevice --enable-avfilter --enable-swscale --enable-swresample --disable-debug
 --enable-filter=abuffer,abuffersink,aformat,aresample,volume,loudnorm,dynaudnorm,anull,asetpts,atempo,buffer,buffersink,format,null,scale --enable-encoder=alac,png,mjpeg
 --enable-static --disable-shared --enable-pic --disable-iconv --enable-zlib --disable-bzlib --disable-lzma
 --enable-libdav1d --enable-decoder=h264,hevc,vp9,libdav1d,aac,alac,flac,opus,mp3,ac3,eac3,ass,ssa,subrip,webvtt,png,mjpeg --enable-demuxer=flv,mov,mpegts,aac,mp3,ac3,eac3,hls,matroska,ogg,flac,ass,srt,webvtt --enable-muxer=hls,mp4,mpegts,image2 --enable-protocol=file,http,https,tcp,tls,crypto,data --enable-bsf=aac_adtstoasc,extract_extradata,h264_mp4toannexb
 --enable-parser=h264,hevc,aac,av1,vp9,mpegaudio,ac3,opus --pkg-config-flags=--static --extra-cflags="-I$dav/include" --extra-ldflags="-L$dav/lib")
if [[ "$mode" == ios ]];then
  config+=(--enable-securetransport)
  if [[ $(uname -s) == Darwin ]];then sdk=$(xcrun --sdk iphoneos --show-sdk-path);cc=$(xcrun -f clang);ar=$(xcrun -f ar);nm=$(xcrun -f nm);ranlib=$(xcrun -f ranlib)
  else sdk="${PILI_IOS_SDK:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk}";cc=$(command -v clang);ar=$(command -v llvm-ar);nm=$(command -v llvm-nm);ranlib=$(command -v llvm-ranlib);fi
  [[ -d "$sdk/usr/include" ]] || { echo "iOS SDK not found: $sdk" >&2;exit 1; }
  config+=(--enable-videotoolbox --enable-decoder=av1 --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,vp9_videotoolbox,av1_videotoolbox --enable-encoder=h264_videotoolbox,hevc_videotoolbox --enable-cross-compile --target-os=darwin --arch=aarch64 --cpu=generic --cc="$cc" --ar="$ar" --nm="$nm" --ranlib="$ranlib" --sysroot="$sdk" --extra-cflags="-target arm64-apple-ios17.0" --extra-ldflags="-target arm64-apple-ios17.0")
  if [[ $(uname -s) != Darwin ]];then
    iosld="${PILI_IOS_LINKER:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/toolset/bin/ld64.lld}"
    sdkversion=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["Version"])' "$sdk/SDKSettings.json")
    config+=(--extra-ldflags="--ld-path=$iosld -Wl,-platform_version,ios,17.0,$sdkversion")
  fi
else
  # A native LGPL encoder is used only by the Linux fixture runner. iOS produces H.264 via VideoToolbox.
  config+=(--enable-encoder=mpeg2video --disable-x86asm)
fi
# A changed recipe builds in a new directory; staged headers and libraries stay paired.
recipe=$(sum "$0")
dav_recipe=$(sum "$kit/build-dav1d.sh")
out="$base/outputs/$mode-${recipe:0:12}-${dav_recipe:0:8}"
if [[ ! -f "$out/.ready" ]];then
  mkdir -p "$out/build" "$out/vendor"
  (cd "$out/build"
   if [[ ! -f ffbuild/config.mak ]];then "$src/configure" --prefix="$out/vendor" "${config[@]}" >&2;fi
   make -j"${PILI_MEDIA_JOBS:-8}" >&2
   make install-headers install-libs >&2)
  grep -q "^#define CONFIG_HLS_MUXER 1" "$out/build/config_components.h"
  grep -q "^#define CONFIG_MP4_MUXER 1" "$out/build/config_components.h"
  for part in H264_DECODER HEVC_DECODER LIBDAV1D_DECODER VP9_DECODER MOV_DEMUXER MPEGTS_DEMUXER AAC_DEMUXER MP3_DEMUXER AC3_DEMUXER EAC3_DEMUXER MPEGTS_MUXER AAC_DECODER ALAC_ENCODER LOUDNORM_FILTER DYNAUDNORM_FILTER ARESAMPLE_FILTER; do
    grep -q "^#define CONFIG_$part 1" "$out/build/config_components.h"
  done
  grep -q "^#define CONFIG_GPL 0" "$out/build/config.h"
  grep -q "^#define CONFIG_NONFREE 0" "$out/build/config.h"
  test -s "$out/vendor/lib/libavformat.a"
  cp "$dav/lib/libdav1d.a" "$out/vendor/lib/"

  touch "$out/.ready"
fi
printf '%s\n' "$out/vendor"
