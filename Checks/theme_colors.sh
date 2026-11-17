#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
cache="$HOME/.cache/piliplus-native/color-check"
swift build --package-path ColorKit --scratch-path "$cache" -c release
bin=$(swift build --package-path ColorKit --scratch-path "$cache" -c release --show-bin-path)
if test -d "$bin/MaterialColorUtilities.build"; then
  objects=("$bin"/MaterialColorUtilities.build/*.o)
else
  mapfile -d "" objects < <(find "$cache/out/Intermediates.noindex/ColorKit.build" -path "*/MaterialColorUtilities-t.build/Objects-normal/*/*.o" -print0)
fi
test "${#objects[@]}" -gt 0
swiftc -O -I "$bin" -I "$bin/Modules" "${objects[@]}" Sources/PiliNative/Settings/ThemeSeeds.swift Sources/PiliNative/Settings/ThemeToneRecipes.swift Checks/ThemeColorsCheck.swift -o "$cache/theme-check"
"$cache/theme-check"
