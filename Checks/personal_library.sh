#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -f -- "$work/check"; rmdir -- "$work"' EXIT
src=Sources/PiliNative
swiftc "$src"/Discover/SharedLink.swift "$src"/Network/{ServiceError,ArchiveNumber}.swift "$src"/Settings/DecodedSettingCache.swift "$src"/Library/{RecommendationFilter,ArchiveSeasonSubscription}.swift "$src"/Social/PersonalLibraryContracts.swift Checks/PersonalLibraryCheck.swift -o "$work/check"
"$work/check"
swiftc "$src"/Discover/SharedLink.swift "$src"/Social/CreatorSections.swift Checks/CreatorSectionsCheck.swift -o "$work/check"
"$work/check"
python3 Checks/personal_library_signoff.py
