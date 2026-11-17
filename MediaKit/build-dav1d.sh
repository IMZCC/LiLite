#!/usr/bin/env bash
set -euo pipefail
version=1.5.4
digest=686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5
mode=${1:-ios}
case "$mode" in ios|host) ;; *) exit 2;; esac
base="${PILI_DECODER_CACHE:-$HOME/.cache/piliplus-native/tools/decoder-build}"
mkdir -p "$base"
archive="$base/dav1d-$version.tar.xz"
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
if [[ ! -f "$archive" ]]; then
  trial=$(mktemp "$base/dav1d.XXXXXX")
  trap 'rm -f -- "$trial"' EXIT
  curl --proto '=https' -fsSL --retry 2 --max-time 120 "https://downloads.videolan.org/pub/videolan/dav1d/$version/dav1d-$version.tar.xz" -o "$trial"
  [[ $(sum "$trial") == "$digest" ]]
  mv -- "$trial" "$archive"
fi
[[ $(sum "$archive") == "$digest" ]] || { echo 'dav1d digest mismatch' >&2; exit 1; }
src="$base/dav1d-$version"
if [[ ! -f "$src/meson.build" ]]; then tar -xf "$archive" -C "$base"; fi
key=$(sum "$0")
out="$base/outputs/$mode-${key:0:12}"
if [[ ! -f "$out/.ready" ]]; then
  if [[ -x "$base/hosttools/usr/bin/meson" ]]; then
    export PATH="$base/hosttools/usr/bin:$PATH" PYTHONPATH="$base/hosttools/usr/lib/python3/dist-packages:${PYTHONPATH:-}"
  fi
  for tool in meson ninja; do command -v "$tool" >/dev/null || { echo "Install Meson and Ninja to rebuild dav1d" >&2; exit 1; }; done
  mkdir -p "$out/vendor"
  options=(-Ddefault_library=static -Db_staticpic=true -Denable_tests=false -Denable_tools=false -Denable_examples=false -Denable_docs=false -Dbuildtype=release --libdir=lib --prefix="$out/vendor")
  if [[ "$mode" == ios ]]; then
    if [[ $(uname -s) == Darwin ]]; then sdk=$(xcrun --sdk iphoneos --show-sdk-path); cc=$(xcrun -f clang); ar=$(xcrun -f ar); strip=$(xcrun -f strip); ldargs=''
    else sdk="${PILI_IOS_SDK:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk}"; cc=$(command -v clang); ar=$(command -v llvm-ar); strip=$(command -v llvm-strip || command -v true)
      linker="${PILI_IOS_LINKER:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/toolset/bin/ld64.lld}"
      sdkversion=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["Version"])' "$sdk/SDKSettings.json")
      ldargs=", '--ld-path=$linker', '-Wl,-platform_version,ios,17.0,$sdkversion'"
    fi
    cat >"$out/cross.ini" <<EOF
[binaries]
c = '$cc'
ar = '$ar'
strip = '$strip'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
c_args = ['-target','arm64-apple-ios17.0','-isysroot','$sdk']
c_link_args = ['-target','arm64-apple-ios17.0','-isysroot','$sdk'$ldargs]
EOF
    options+=(--cross-file "$out/cross.ini")
  elif ! command -v nasm >/dev/null; then options+=(-Denable_asm=false); fi
  if [[ ! -f "$out/build/build.ninja" ]]; then meson setup "$out/build" "$src" "${options[@]}" >&2; fi
  ninja -C "$out/build" -j"${PILI_MEDIA_JOBS:-8}" install >&2
  test -s "$out/vendor/lib/libdav1d.a"
  touch "$out/.ready"
fi
printf '%s\n' "$out/vendor"
