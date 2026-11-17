#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
n=$(cd "$(dirname "$0")/.." && pwd);s="$n/Sources/PiliNative"
t=$(mktemp -d);trap 'rm -rf "$t"' EXIT
f=${PILI_QA_FFMPEG:-$(command -v ffmpeg || true)}
[[ -n "$f" ]] || f="$HOME/.cache/piliplus-native/tools/live-qa/ffmpeg"
[[ -x "$f" ]] || { echo 'An ffmpeg with H.264 and AAC is required'; exit 1; }
"$f" -hide_banner -loglevel error -f lavfi -i testsrc2=size=96x64:rate=10:duration=1.5 -an -c:v libx264 -g 5 -bf 0 -pix_fmt yuv420p -movflags +faststart "$t/v.mp4"
"$f" -hide_banner -loglevel error -f lavfi -i sine=frequency=880:sample_rate=48000:duration=1.5 -vn -c:a aac -use_editlist 0 -movflags +faststart "$t/a.m4a"
swiftc "$s"/Playback/{ArchiveSharePoint,ArchiveAddressGrant,ArchiveResume,PlaybackMemory,VideoEngagement,InteractiveStory,SegmentIndex}.swift "$s"/Network/{ArchiveNumber,ServiceError}.swift "$s"/Settings/DecodedSettingCache.swift "$s"/Library/{Video,RecommendationFilter}.swift "$s"/Decoder/{AudioFilterChoice,LocalFragmentIndex,LocalMovieTable,LocalMovieFragments}.swift "$n/Checks/ArchiveDetailCheck.swift" -o "$t/check"
"$t/check" "$t/v.mp4" "$t/a.m4a" "$t"
hash_track(){ "$f" -hide_banner -loglevel error -i "$1" -map "$2" -f hash -hash sha256 -; }
[[ "$(hash_track "$t/v.mp4" 0:v:0)" == "$(hash_track "$t/v-out.mp4" 0:v:0)" ]]
[[ "$(hash_track "$t/a.m4a" 0:a:0)" == "$(hash_track "$t/a-out.mp4" 0:a:0)" ]]
echo 'Separate source files: decoded YUV and PCM match the independently reassembled fMP4 tracks'
python3 "$n/Checks/archive_detail_manifest.py"
