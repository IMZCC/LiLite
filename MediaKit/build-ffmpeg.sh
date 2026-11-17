#!/usr/bin/env bash
set -euo pipefail
exec bash "$(dirname "$0")/build-decoder-libs.sh" "$@"
