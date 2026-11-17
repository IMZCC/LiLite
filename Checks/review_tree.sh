#!/usr/bin/env bash
set -euo pipefail
: "${target:?}" "${job:?}" "${dest:?}"
[[ $(git rev-parse HEAD) == "$target" ]]
export PILI_SOURCE_REV="$target"
export SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD)
echo "Checking $target ($job)"
if [[ $job == host || $job == all ]]; then
  bash Checks/run.sh 2>&1 | tee "$dest/host.log"
fi
if [[ $job == ios || $job == all ]]; then
  bash build.sh --release 2>&1 | tee "$dest/ios.log"
  cp dist/PiliNative-release-unsigned.ipa "$dest/PiliNative-unsigned.ipa"
  (cd "$dest"; sha256sum PiliNative-unsigned.ipa > ipa.sha256)
fi
if [[ $job == personal ]]; then
  bash build.sh --release-personal 2>&1 | tee "$dest/personal.log"
  cp dist/PiliNative-personal-unsigned.ipa "$dest/PiliNative-personal-unsigned.ipa"
  (cd "$dest"; sha256sum PiliNative-personal-unsigned.ipa > personal.sha256)
fi
if [[ $job == sign-personal ]]; then
  bash build.sh --sign-personal 2>&1 | tee "$dest/sign-personal.log"
  cp dist/PiliNative-signed.ipa "$dest/PiliNative-signed.ipa"
  (cd "$dest"; sha256sum PiliNative-signed.ipa > signed.sha256)
fi
if [[ $job == media || $job == all ]]; then
  (
    set -e
    python3 Checks/live_remux.py
    python3 Checks/live_decode.py
    python3 Checks/native_decode.py
    python3 Checks/audio_segments.py
    python3 Checks/presentation_timing.py
    bash Checks/storage_locations.sh
    python3 Checks/backup_recovery.py
    python3 Checks/subtitle_raster.py --ios
    PYTHONDONTWRITEBYTECODE=1 python3 Checks/anime4k.py
  ) 2>&1 | tee "$dest/media.log"
fi
echo "Checked $target ($job); artifacts: $dest"
