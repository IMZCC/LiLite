"""Check the personal library action ledger against its pinned upstream and real consumers."""
from functools import lru_cache
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "Native"
BASE = "d9e9626f1a3f89cd9ca85e18f61aaba02634e12a"

def unique(pairs):
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError("duplicate acceptance key")
    return result

def read(path):
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)

def safe(root, rel):
    assert rel and not Path(rel).is_absolute() and ".." not in Path(rel).parts, rel
    result = (root / rel).resolve()
    assert result.is_relative_to(root.resolve()), rel
    return result

@lru_cache
def original(rel):
    if (ROOT / ".git").exists():
        return subprocess.check_output(["git", "-C", str(ROOT), "show", BASE + ":" + rel], encoding="utf-8")
    file = safe(ROOT, rel)
    return file.read_text(encoding="utf-8") if file.is_file() else None

manifest = read(NATIVE / "parity.json")
report = read(NATIVE / "Acceptance/evidence/personal-library-signoff.json")
assert report["baseline"] == BASE and report["domain"] == "personal-library-spaces"
records = report["records"]
pages = ("blacklist contact fan fav fav_create fav_detail fav_folder_sort fav_panel fav_search fav_sort follow "
         "follow_search follow_tag_sort follow_type group_panel history history_search later later_search member member_article "
         "member_audio member_cheese member_coin_arc member_comic member_contribute member_dynamics member_favorite member_guard "
         "member_home member_like_arc member_opus member_pgc member_profile member_search member_season_series member_shop "
         "member_upower_rank member_video member_video_web mine space_setting subscription subscription_detail").split()
routes = ("blackListPage createFav fan fav favDetail favSearch follow followSearch followed history historySearch later laterSearch "
          "member memberDynamics memberGuard memberSearch sameFollowing spaceSetting subscription subDetail upowerRank videoWeb").split()
screens = ("fav/article fav/cheese fav/note fav/pgc fav/topic fav/video follow_type/follow_same follow_type/followed member_search/child "
           "member_video_web/archive member_video_web/base member_video_web/season_series video/member").split()
for prefix, keys in (("page:", pages), ("route:/", routes), ("screen:", screens)):
    assert {prefix+k for k in keys} == {k for k in records if k.startswith(prefix)}
assert records.keys() <= manifest.keys()
for key, row in records.items():
    assert set(row) == {"upstream","consumers","behavior","verdict","evidence","device_or_remaining"}, key
    assert row["verdict"] in {"verified","implemented","cross-domain","partial"}
    assert len(row["behavior"]) >= 15 and row["evidence"] and row["consumers"], key
    src = row["upstream"]
    declared = manifest[key]["source"]
    assert src["file"] == declared or src["file"].startswith(declared.rstrip("/")+"/"), key
    safe(ROOT, src["file"])
    txt = original(src["file"])
    if txt is not None:
        assert src["symbol"] and src["symbol"] in txt, (key, src)
    for place in row["consumers"]:
        p = safe(NATIVE, place["file"])
        assert p.is_file() and place["symbol"] and place["symbol"] in p.read_text(encoding="utf-8"), (key, place)
    assert all(safe(NATIVE, evidence).is_file() for evidence in row["evidence"]), key
    if row["verdict"] in {"cross-domain","partial"}:
        assert row["device_or_remaining"], key
print(f"Personal library: {len(records)} ID-keyed records; {len(pages)} pages, {len(routes)} routes, {len(screens)} nested views, all consumer and evidence anchors valid")
