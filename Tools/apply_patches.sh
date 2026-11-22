#!/usr/bin/env bash
# 把 patches/*.patch 叠加到上游源码上（幂等，兼容 macOS 自带 bash 3.2）。
#   Tools/apply_patches.sh           应用所有尚未应用的补丁
#   Tools/apply_patches.sh --check   只校验能否干净应用，不改动文件
#   Tools/apply_patches.sh --regen   按当前工作区改动重新生成补丁
# PILI_SKIP_PATCHES=1 时直接跳过。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mode=${1:-apply}
[[ -z ${PILI_SKIP_PATCHES:-} ]] || { echo "apply_patches: skipped (PILI_SKIP_PATCHES)"; exit 0; }

applied() { git apply --reverse --check "$1" >/dev/null 2>&1; }
clean() { git apply --check "$1" >/dev/null 2>&1 || git apply --3way --check "$1" >/dev/null 2>&1; }
each() {
  found=0
  for p in patches/*.patch; do
    [[ -f $p ]] || continue
    found=1
    "$1" "$p"
  done
  [[ $found == 1 ]] || echo "apply_patches: no patches"
}

case "$mode" in
  apply)
    do_apply() {
      if applied "$1"; then
        echo "skip  $1 (already applied)"
      elif git apply --3way "$1" >/dev/null 2>&1 || git apply "$1"; then
        echo "apply $1"
      else
        echo "error: $1 无法应用；合并上游后运行 Tools/apply_patches.sh --regen" >&2
        exit 1
      fi
    }
    each do_apply
    ;;
  --check)
    bad=0
    do_check() {
      if applied "$1"; then echo "ok    $1 (already applied)"
      elif clean "$1"; then echo "ok    $1"
      else echo "fail  $1" >&2; bad=1
      fi
    }
    each do_check
    exit $bad
    ;;
  --regen)
    do_regen() {
      # 补丁出现过的路径即该补丁的归属范围。
      paths=$(grep -E '^diff --git a/.* b/' "$1" | sed -E 's#^diff --git a/(.*) b/.*#\1#' | sort -u)
      [[ -n $paths ]] || return 0
      for f in $paths; do
        [[ -e $f ]] || continue
        git ls-files --error-unmatch "$f" >/dev/null 2>&1 || git add -N "$f"
      done
      # shellcheck disable=SC2086
      git diff --no-color -- $paths > "$1"
      # shellcheck disable=SC2086
      git reset -q -- $paths 2>/dev/null || true
      echo "regen $1 ($(wc -l < "$1" | tr -d ' ') lines)"
    }
    each do_regen
    ;;
  *)
    echo "Usage: Tools/apply_patches.sh [--check|--regen]" >&2
    exit 2
    ;;
esac
