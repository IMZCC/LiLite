#!/usr/bin/env bash
# Native macOS build: Xcode project LiLite.xcodeproj around the PiliNative SwiftPM package.
#   ./build.sh --sim               Debug for the iOS Simulator, install + launch (PILI_SIM=<udid|name>, default: booted)
#   ./build.sh --prepare           build MediaKit libraries (device + simulator) and stage Firebase, then use Xcode
#   ./build.sh                     Debug, device, unsigned      -> dist/PiliNative.ipa
#   ./build.sh --release           Release, device, unsigned    -> dist/PiliNative-release-unsigned.ipa
#   ./build.sh --release-personal  Release, device, unsigned, personal-team discovery
#   ./build.sh --sign | --sign-personal | --sign-dev   Release, Xcode automatic signing (PILI_TEAM)
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
mode=${1:-}
case "$mode" in
    ""|--sim|--prepare|--release|--release-personal|--sign|--sign-personal|--sign-dev) ;;
    *) echo "Usage: build.sh [--sim | --prepare | --release | --release-personal | --sign | --sign-personal | --sign-dev]" >&2; exit 2 ;;
esac
[[ $(uname -s) == Darwin ]] || { echo "LiLite builds natively on macOS with Xcode." >&2; exit 1; }
export PATH="$PATH:$HOME/.local/bin"   # meson / ninja / pkg-config for the MediaKit libraries
mkdir -p "$root/build" "$root/dist"
# One build at a time: staging, DerivedData and dist/ are shared.
exec 9>"$root/build/.pili-build.lock"
python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)'
# Local features live in patches/*.patch; re-apply them after every upstream merge.
# PILI_SKIP_PATCHES=1 builds the unpatched tree.
bash "$root/Tools/apply_patches.sh"

# --- MediaKit C libraries -> MediaKit/Vendor/PiliMediaVendor.xcframework + Vendor/include.
# The device slice is always built (cached after the first run), so every build links a
# complete xcframework; --sim and --prepare add the simulator slice.
case "$mode" in
  --sim|--prepare) media_modes=(ios iossim) ;;
  *) media_modes=(ios) ;;
esac
vendor="$root/MediaKit/Vendor"
rm -rf "$vendor/lib"   # pre-xcframework layout
mkdir -p "$vendor/include"
for media in "${media_modes[@]}"; do
  sdkname=iphoneos; [[ $media == iossim ]] && sdkname=iphonesimulator
  ffmpeg_prefix=$(bash "$root/MediaKit/build-ffmpeg.sh" "$media")
  caption_prefix=$(python3 "$root/MediaKit/build-subtitles.py" "$media")
  mpv_prefix=$(python3 "$root/MediaKit/build-mpv.py" "$media")
  slice="$vendor/$sdkname"
  rm -rf "$slice"; mkdir -p "$slice"
  libs=()
  for prefix in "$ffmpeg_prefix" "$caption_prefix" "$mpv_prefix"; do
    # Same recipe, same arch: the headers are identical for both slices.
    rsync -a "$prefix/include/" "$vendor/include/"
    libs+=("$prefix"/lib/*.a)
  done
  libtool -static -no_warning_for_no_symbols -o "$slice/libPiliMediaVendor.a" "${libs[@]}"
  if [[ $media == ios ]]; then
    # LGPL relinking material shipped next to device releases.
    mkdir -p "$root/dist/MPV/include"
    cp "$mpv_prefix/lib/libmpv.a" "$mpv_prefix/lib/libplacebo.a" "$mpv_prefix/build-receipt.json" "$root/dist/MPV/"
    rsync -a "$mpv_prefix/include/mpv/" "$root/dist/MPV/include/mpv/"
  fi
done
slices=()
for sdkname in iphoneos iphonesimulator; do
  if [[ -f "$vendor/$sdkname/libPiliMediaVendor.a" ]]; then slices+=(-library "$vendor/$sdkname/libPiliMediaVendor.a"); fi
done
rm -rf "$vendor/PiliMediaVendor.xcframework"
xcodebuild -create-xcframework "${slices[@]}" -output "$vendor/PiliMediaVendor.xcframework" >/dev/null

# --- Firebase static frameworks (device + simulator slices) and resources -> FirebaseSDK/.
firebase=$(python3 "$root/Tools/firebase_sdk.py" "$root")
if [[ $mode == --prepare ]]; then
  echo "Prepared. Open LiLite.xcodeproj in Xcode, or run ./build.sh --sim."
  exit 0
fi

derived="$root/build/DerivedData"
xcode=(xcodebuild -project "$root/LiLite.xcodeproj" -scheme LiLite -derivedDataPath "$derived"
  -skipPackagePluginValidation -skipMacroValidation)

# --- Simulator: Debug build, install into the simulator and launch.
if [[ $mode == --sim ]]; then
  "${xcode[@]}" -configuration Debug -destination 'generic/platform=iOS Simulator' build
  app="$derived/Build/Products/Debug-iphonesimulator/PiliNative.app"
  sim=${PILI_SIM:-booted}
  if [[ $sim == booted ]] && ! xcrun simctl list devices booted | grep -q Booted; then
    sim=$(xcrun simctl list devices available | sed -n 's/^ *\(iPhone [^(]*\) (\([0-9A-F-]*\)).*/\2/p' | head -1)
    [[ -n $sim ]] || { echo "No iPhone simulator available; create one in Xcode > Window > Devices and Simulators." >&2; exit 1; }
    xcrun simctl boot "$sim"
    open -a Simulator
  fi
  bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
  xcrun simctl install "$sim" "$app"
  xcrun simctl terminate "$sim" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl launch "$sim" "$bundle"
  echo "Launched $bundle on simulator $sim"
  exit 0
fi

# --- Device builds.
configuration=Release; signed=0; discovery=full; outfile=PiliNative-release-unsigned.ipa
case "$mode" in
  "") configuration=Debug; outfile=PiliNative.ipa ;;
  --release-personal) discovery=personal; outfile=PiliNative-personal-unsigned.ipa ;;
  --sign) signed=1; outfile=PiliNative-signed.ipa ;;
  --sign-personal) signed=1; discovery=personal; outfile=PiliNative-signed.ipa ;;
  --sign-dev) signed=1; discovery=personal; outfile=PiliNative-dev-signed.ipa
    # Development-only device build: -O but parallel and incremental (see Package.swift).
    export PILI_FAST_BUILD=1 ;;
esac
staging="$root/build/staging/$discovery"
rm -rf "$staging"; mkdir -p "$staging/Resources"
cp "$root/Resources/Info.plist" "$root/Resources/PiliPlus.entitlements" "$staging/Resources/"
if [[ $discovery == personal ]]; then
  # Personal teams cannot hold the multicast entitlement: Bonjour + directed DLNA/IP discovery instead.
  python3 "$root/Tools/personal_profile.py" "$staging"
fi
settings=(INFOPLIST_FILE="$staging/Resources/Info.plist" CODE_SIGN_ENTITLEMENTS="$staging/Resources/PiliPlus.entitlements")
if [[ $signed == 1 ]]; then
  team=${PILI_TEAM:?Set PILI_TEAM to your Apple team ID and sign in to Xcode (Settings > Accounts)}
  # Personal-team builds keep the identifier of the app already installed on the phone.
  bundle=${PILI_BUNDLE_ID:-com.liuliuya.PiliNative}
  if [[ $mode == --sign-dev && -z ${PILI_BUNDLE_ID:-} ]]; then bundle="XTL-$team.com.liuliuya.PiliNative"; fi
  settings+=(DEVELOPMENT_TEAM="$team" PRODUCT_BUNDLE_IDENTIFIER="$bundle" CODE_SIGN_STYLE=Automatic)
  xcode+=(-allowProvisioningUpdates)
else
  settings+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
fi
xcode+=(-configuration "$configuration" -destination 'generic/platform=iOS')
archive=
if [[ $configuration == Debug ]]; then
  "${xcode[@]}" "${settings[@]}" build
  app="$derived/Build/Products/Debug-iphoneos/PiliNative.app"
else
  # Archive like Xcode's Product > Archive: stripped executable plus a matching dSYM.
  archive="$root/build/LiLite.xcarchive"
  rm -rf "$archive"
  "${xcode[@]}" -archivePath "$archive" "${settings[@]}" archive
  app="$archive/Products/Applications/PiliNative.app"
fi

# --- Package the .app as an IPA and verify it before it reaches dist/.
package="$root/build/package"
rm -rf "$package"; mkdir -p "$package/Payload"
ditto "$app" "$package/Payload/PiliNative.app"
(cd "$package" && zip -qry PiliNative.ipa Payload)
inspect=(python3 "$root/Tools/inspect_ipa.py" --firebase-plist "$firebase/GoogleService-Info.plist" --discovery "$discovery")
if [[ $signed == 1 ]]; then inspect+=(--signed); fi
"${inspect[@]}" "$package/PiliNative.ipa"
cp "$package/PiliNative.ipa" "$root/dist/$outfile"
if [[ -n $archive && -d "$archive/dSYMs/PiliNative.app.dSYM" ]]; then
  # Upload to Firebase Crashlytics (dSYM page) for symbolicated crash reports.
  rm -f "$root/dist/${outfile%.ipa}.dSYM.zip"
  ditto -c -k --keepParent "$archive/dSYMs/PiliNative.app.dSYM" "$root/dist/${outfile%.ipa}.dSYM.zip"
fi
echo "Built dist/$outfile"
