#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -f -- "$tmp/check"; rmdir -- "$tmp"' EXIT
swiftc Sources/PiliNative/Network/ServiceError.swift Sources/PiliNative/Playback/InteractiveStory.swift Checks/InteractiveStoryCheck.swift -o "$tmp/check"
"$tmp/check"
