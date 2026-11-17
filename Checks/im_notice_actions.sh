#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -f -- "$tmp/check"; rmdir -- "$tmp"' EXIT
src=Sources/PiliNative
swiftc "$src/Network/ServiceError.swift" "$src/Decoder/AudioFilterChoice.swift" "$src/Network/ArchiveNumber.swift" "$src/Library/Video.swift" "$src/Settings/DecodedSettingCache.swift" "$src/Library/RecommendationFilter.swift" "$src/Library/GalleryPicture.swift" "$src/Discover/SharedLink.swift" "$src/Social/RichNodes.swift" "$src/Social/NoticeMarkup.swift" "$src/Social/UnreadTotals.swift" "$src/Social/IMForwardContent.swift" "$src/Social/IMShareCard.swift" Checks/IMNotificationCheck.swift -o "$tmp/check"
"$tmp/check"
