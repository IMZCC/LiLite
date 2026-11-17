#!/usr/bin/env bash
# Verify exactly one Git tree in WSL, including its upstream baseline objects.
set -euo pipefail
repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
target=$(git -C "$repo" rev-parse --verify --end-of-options "${1:-HEAD}^{commit}")
job=${2:-host}
case "$job" in host|ios|media|all|personal|sign-personal) ;; *) echo "Usage: bash Checks/frozen.sh [revision] [host|ios|media|all|personal|sign-personal]" >&2; exit 2 ;; esac
dest="$repo/Native/dist/reviews/$target"
mkdir -p "$dest"
temp_base=$(realpath "${TMPDIR:-/tmp}")
scratch=$(mktemp -d "$temp_base/pili-native-review.XXXXXXXX")
cleanup() {
  local path
  path=$(realpath -e -- "$scratch") || return
  if [[ $(dirname -- "$path") == "$temp_base" && $(basename -- "$path") == pili-native-review.???????? ]]; then
    rm -rf -- "$path"
  fi
}
trap cleanup EXIT
git -c core.autocrlf=false clone --quiet --shared --no-checkout -- "$repo" "$scratch/source"
git -C "$scratch/source" -c core.autocrlf=false checkout --quiet --detach "$target"
cd "$scratch/source/Native"
[[ $(git rev-parse HEAD) == "$target" ]]
# Run the procedures stored at the requested commit. The caller's worktree may
# change while a long compilation is running.
export target job dest
if [[ $job == personal || $job == sign-personal ]]; then
  grep -qF 'build.sh --release-personal' Checks/review_tree.sh || { echo "Requested revision does not support personal signing configurations" >&2; exit 2; }
fi
if [[ -f Checks/review_tree.sh ]]; then
  bash Checks/review_tree.sh
else
  # The original runner kept the same job body inline after this marker.
  grep -q '^export PILI_SOURCE_REV=' Checks/frozen.sh
  { echo 'set -euo pipefail'; sed -n '/^export PILI_SOURCE_REV=/,$p' Checks/frozen.sh; } >"$scratch/job.sh"
  bash "$scratch/job.sh"
fi
