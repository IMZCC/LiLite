"""Verify the pinned original-to-Swift crosswalk, in addition to the executable state checks."""
from pathlib import Path
import json
import re

native = Path(__file__).resolve().parents[1]
root = native.parent
swift = native / "Sources/PiliNative"
rows = json.loads((native / "Acceptance/evidence/player-key-gestures.json").read_text())["rows"]
parity = json.loads((native / "parity.json").read_text())
errors = []
seen = set()
actual_keys = set()
for row in rows:
    id_ = row["id"]
    if id_ in seen or (id_.startswith(("page:", "route:", "preference:")) and id_ not in parity):
        errors.append("missing or duplicate ID: " + id_)
    seen.add(id_)
    if id_.startswith("key:"):
        actual_keys.add(id_[4:])
    for side, directory in [("native", swift), ("upstream", root)]:
        for ref in row[side]:
            file, anchor = ref.split("#", 1)
            path = directory / file
            content = path.read_text(encoding="utf-8") if path.is_file() else ""
            if not anchor or re.sub(r"\s+", "", anchor) not in re.sub(r"\s+", "", content):
                errors.append(f"{id_}: {side} anchor missing: {ref}")
    if row["proof"] not in ("source+sdk", "state-machine+sdk", "platform-scope"):
        errors.append(id_ + ": unknown proof")
expected = set("Q-tap Q-hold R-tap R-hold QR-live W E T V G Enter Space F Shift-F D M S L left right up down Shift-1 Shift-2 previous next comma period P".split())
if actual_keys != expected:
    errors.append("key matrix changed: " + str(sorted(expected ^ actual_keys)))
pref = set(k.split("/")[-1] for k in seen if k.startswith("preference:"))
needed = set("btmProgressBehavior enableAutoLongPressSpeed enableLongShowControl enableQuickDouble enableScrollVolume enableShrinkVideoSize enableSlideFS enableSlideVolumeBrightness enableTapDm fastForBackwardDuration fullScreenGestureReverse fullScreenMode keyboardControl removeSafeArea showBatteryLevel showFSActionItem showFsLockBtn showFsScreenshotBtn showSeekPreview sliderDuration useRelativeSlide enableAutoEnter enableAutoExit feedBackEnable playerVolume enableVerticalExpand tempPlayerConf enableShowDanmaku enableShowLiveDanmaku enableQuickFav quickFavId coinWithLike showViewPoints showDmChart enableDragSubtitle cacheVideoFit longPressSpeedDefault playSpeedDefault speedsList maxVolume angleDegrees setSystemBrightness".split())
if needed != pref:
    errors.append("preference matrix changed: " + str(sorted(needed ^ pref)))
if errors:
    raise SystemExit("\n".join(errors))
print(f"{len(rows)} keyboard/touch rows resolved: {len(pref)} preferences, {len(actual_keys)} key paths, {len(rows)-len(pref)-len(actual_keys)} route, gesture and focus paths")
