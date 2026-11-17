#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Checks/setting_search.py
python3 Tools/SettingsIndex/terms.py
work=$(mktemp -d)
trap 'rm -f -- "$work/check"; rmdir -- "$work"' EXIT
src=Sources/PiliNative/Settings
swiftc "$src/SettingSearchData.swift" "$src/SettingSearchTerms.swift" "$src/SettingSearchRow.swift" Checks/SettingSearchCheck.swift -o "$work/check"
"$work/check"
