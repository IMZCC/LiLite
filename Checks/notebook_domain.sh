#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -f -- "$tmp/note"; rmdir -- "$tmp"' EXIT
s=Sources/PiliNative
swiftc "$s/Network/ServiceError.swift" "$s/Decoder/AudioFilterChoice.swift" "$s/Settings/DecodedSettingCache.swift" "$s/Library/RecommendationFilter.swift" "$s/Library/Video.swift" "$s/Library/GalleryPicture.swift" "$s/Discover/SharedLink.swift" "$s/Social/RichNodes.swift" "$s/Discover/ArticleBody.swift" "$s/Discover/NotebookDocument.swift" "$s/Discover/NotebookArticle.swift" Checks/NotebookContractCheck.swift -o "$tmp/note"
"$tmp/note" "$@"
