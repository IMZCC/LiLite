#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
src="$root/Sources/PiliNative"
swiftc "$src"/Library/{CreatorQueueDomain,CreatorArchiveCatalog,CreatorPlaybackCursor,LibraryQueueState,CloudLibrarySource,MediaPageWindow}.swift \
  "$src"/Network/{ServiceID,ArchiveNumber}.swift "$src"/Account/{AccountRole,AccountServices}.swift "$src"/Playback/VideoRepeat.swift \
  "$root"/Checks/{CreatorPlaylistFixtures,CreatorPlaylistCheck}.swift -o "$stage/check"
"$stage/check"
