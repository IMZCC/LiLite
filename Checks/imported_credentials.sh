#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -f -- "$work/check"; rmdir -- "$work"' EXIT
swiftc Sources/PiliNative/Network/ServiceError.swift Sources/PiliNative/Account/ImportedCredentialProof.swift Checks/ImportedCredentialCheck.swift -o "$work/check"
"$work/check"
python3 Checks/imported_accounts.py
