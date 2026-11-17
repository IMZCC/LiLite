#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -f -- "$tmp/check" "$tmp/draft"; rmdir -- "$tmp"' EXIT
src=Sources/PiliNative
swiftc "$src/Network/ServiceError.swift" "$src/Decoder/AudioFilterChoice.swift" "$src/Library/Video.swift" "$src/Settings/DecodedSettingCache.swift" "$src/Library/RecommendationFilter.swift" "$src/Library/GalleryPicture.swift" "$src/Discover/SharedLink.swift" "$src/Social/RichNodes.swift" "$src/Social/DynamicModules.swift" "$src/Social/ReplyDraft.swift" "$src/Social/DynamicRevision.swift" "$src/Social/MomentResources.swift" "$src/Social/DynamicDraftFile.swift" Checks/MomentDomainCheck.swift -o "$tmp/check"
"$tmp/check"
swiftc "$src/Network/ServiceError.swift" "$src/Social/ReplyDraft.swift" "$src/Social/DynamicRevision.swift" "$src/Social/DynamicDraftFile.swift" Checks/DynamicDraftCheck.swift -o "$tmp/draft"
"$tmp/draft"
