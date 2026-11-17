#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin=$(mktemp)
trap 'rm -f -- "$bin"' EXIT
swiftc Sources/PiliNative/Discover/{SharedLink,MusicContent}.swift Checks/MusicContentCheck.swift -o "$bin"
"$bin" "$@"
