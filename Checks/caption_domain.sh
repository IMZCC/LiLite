#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
s="$root/Sources/PiliNative"
d=$(mktemp -d);trap 'rm -rf "$d"' EXIT
swiftc "$s"/Playback/{SubtitleDocument,SubtitleSession,SubtitlePreference}.swift "$s"/Network/ServiceError.swift "$s"/Danmaku/{DMProto,Danmaku,SpecialBullet,BulletReceipts}.swift "$root/Checks/CaptionDomainCheck.swift" -o "$d/check"
"$d/check" "$@"
