#!/usr/bin/env bash
set -euo pipefail
n=$(cd "$(dirname "$0")/.." && pwd);s="$n/Sources/PiliNative"
d=$(mktemp -d);trap 'rm -rf "$d"' EXIT
swiftc "$s"/Playback/{PlayerKeySequence,PlaybackSocialRequest,VideoEngagement,ViewportPolicy,FullscreenPolicy}.swift "$s"/Danmaku/BulletPauseClock.swift "$s"/Network/{ServiceError,ArchiveNumber}.swift "$n/Checks/PlayerKeySequenceCheck.swift" -o "$d/check"
"$d/check"
python3 "$n/Checks/player_key_manifest.py"
