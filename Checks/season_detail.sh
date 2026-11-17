#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -f -- "$tmp/check"; rmdir -- "$tmp"' EXIT
src=Sources/PiliNative
swiftc "$src/Network/ServiceError.swift" "$src/Network/ArchiveNumber.swift" "$src/Library/Video.swift" "$src/Settings/DecodedSettingCache.swift" "$src/Library/RecommendationFilter.swift" "$src/Playback/VODLine.swift" "$src/Decoder/AudioFilterChoice.swift" "$src/Playback/DashModels.swift" "$src/Playback/LegacyDURLTypes.swift" "$src/Playback/EpisodeClips.swift" "$src/Discover/SeasonModels.swift" "$src/Discover/SeasonReviewPolicy.swift" "$src/Discover/EpisodePlayPayload.swift" "$src/Offline/EpisodeCachePolicy.swift" Checks/SeasonDetailCheck.swift -o "$tmp/check"
"$tmp/check" "$@"
