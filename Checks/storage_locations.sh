#!/usr/bin/env bash
# The iOS app uses system CryptoKit. Linux QA builds the same framing against Apple's Swift Crypto.
set -euo pipefail
cd "$(dirname "$0")/.."
src=Sources/PiliNative
files=("$src/Network/ServiceError.swift" "$src/Library/FolderAccessIO.swift" "$src/Library/FolderExport.swift" "$src/Offline/LegacyMediaComponents.swift" "$src/Offline/OfflinePackage.swift" "$src/Offline/OfflineSealedTrack.swift" Checks/StorageLocationsCheck.swift)
if [[ $(uname -s) == Darwin ]]; then
  work=$(mktemp -d)
  trap 'rm -f -- "$work/check"; rmdir "$work"' EXIT
  swiftc "${files[@]}" -o "$work/check"; "$work/check"
  exit
fi
cache="$HOME/.cache/piliplus-native/tools/crypto-storage"
package="$cache/fixture"
mkdir -p "$package/Sources/Fixture"
if [[ ! -d "$cache/swift-crypto/.git" ]]; then
  git clone --quiet --depth 1 --branch 3.15.1 https://github.com/apple/swift-crypto.git "$cache/swift-crypto"
fi
test "$(git -C "$cache/swift-crypto" rev-parse HEAD)" = 95ba0316a9b733e92bb6b071255ff46263bbe7dc
cp -f "${files[@]}" "$package/Sources/Fixture/"
cat >"$package/Package.swift" <<'SWIFT'
// swift-tools-version: 5.10
import PackageDescription
let package = Package(name:"Fixture", dependencies:[.package(path:"../swift-crypto")], targets:[
  .executableTarget(name:"Fixture",dependencies:[.product(name:"Crypto",package:"swift-crypto")])
])
SWIFT
swift run --package-path "$package" -j 5 Fixture
