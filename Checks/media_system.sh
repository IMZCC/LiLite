#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -f -- "$tmp/check"; rmdir -- "$tmp"' EXIT
src=Sources/PiliNative
swiftc "$src"/Network/ServiceError.swift "$src"/Playback/{VODLine,MediaPreferences,SystemPiPLifecycle}.swift \
  "$src"/Decoder/{DecoderPreference,AudioFilterChoice}.swift "$src"/Settings/DecodedSettingCache.swift "$src"/Library/{Video,GalleryPicture,ArtworkCacheRules,RecommendationFilter}.swift Checks/MediaSystemCheck.swift -o "$tmp/check"
"$tmp/check"
python3 Checks/media_system_signoff.py
