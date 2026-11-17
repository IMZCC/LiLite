#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d); trap 'rm -f -- "$work/run"; rmdir -- "$work"' EXIT
src=Sources/PiliNative
swiftc "$src/Network/ServiceError.swift" "$src/Social/UnreadTotals.swift" "$src/Settings/"{DecodedSettingCache,TouchPulseGate,NavigationRules,MotionPreferences,InterfacePresentation,TypefaceValue,AccountExitRequest,AboutResetPolicy,SettingSearchData,SettingSearchTerms,SettingSearchRow}.swift Checks/InterfaceAcceptanceCheck.swift -o "$work/run"
"$work/run"
python3 Checks/interface_signoff.py
