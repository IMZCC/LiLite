#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -f -- "$work/check"; rmdir -- "$work"' EXIT
src=Sources/PiliNative
swiftc "$src/Network/ServerCertificatePolicy.swift" "$src/Playback/ArchiveStreamGrant.swift" "$src/Decoder/AudioFilterChoice.swift" "$src/Network/ServiceError.swift" "$src/Settings/DecodedSettingCache.swift" "$src/Library/RecommendationFilter.swift" "$src/Library/Video.swift" "$src/Library/MobileFeed.swift" "$src/Network/ArchiveNumber.swift" "$src/Discover/SharedLink.swift" "$src/Discover/SeasonModels.swift" "$src/Live/LiveModels.swift" "$src/Live/LiveAreaModels.swift" "$src/Network/ServiceID.swift" "$src/Live/LiveSearchModels.swift" "$src/Playback/RangeTransport.swift" "$src/Playback/DashModels.swift" "$src/Playback/VODLine.swift" "$src/Playback/VODSpeedProbe.swift" "$src/Playback/SegmentIndex.swift" "$src/Playback/RelayRange.swift" "$src/Playback/MediaRange.swift" "$src/Network/WebQuery.swift" "$src/Discover/SearchModels.swift" Checks/PublicServiceCheck.swift -lcrypto -o "$work/check"
"$work/check"
