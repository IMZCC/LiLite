#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin=$(mktemp)
trap 'rm -f "$bin"' EXIT
swiftc Sources/PiliNative/Network/ServiceError.swift Sources/PiliNative/Social/{ReplyComposeRules,ReplyFiltering,ReplyDraft,ReplyMathGlyphs,ReplyMath,ReplyArchive}.swift Checks/ReplyDomainAudit.swift -o "$bin"
"$bin"
