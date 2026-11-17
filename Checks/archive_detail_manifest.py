"""Verify every pinned video subpage and the entire pinned player source inventory."""
import hashlib,json,re,subprocess
from pathlib import Path

n=Path(__file__).resolve().parents[1]
root=n.parent
index=json.loads((n/"parity.json").read_text(encoding="utf-8"))
baseline="d9e9626f1a3f89cd9ca85e18f61aaba02634e12a"
fixed_cache={}
def fixed(file):
    if file not in fixed_cache:
        fixed_cache[file]=subprocess.check_output(["git","show",baseline+":"+file],cwd=root).decode("utf-8")
    return fixed_cache[file]
m=json.loads((n/"Acceptance/evidence/archive-detail-signoff.json").read_text(encoding="utf-8"))
rows=m["rows"];seen=set();problems=[]
required={id_ for id_ in index if id_.startswith("screen:video/")}|{"page:video","route:/videoV","route:/playSpeedSet","subsystem:plugin/pl_player"}
def anchor(base,ref):
    path,needle=ref.split("#",1);f=base/path
    if base == root and path.startswith("lib/"):
        return re.sub(r"\s+","",needle) in re.sub(r"\s+","",fixed(path))
    return f.is_file() and re.sub(r"\s+","",needle) in re.sub(r"\s+","",f.read_text(encoding="utf-8"))
for row in rows:
    k=row["id"]
    if k in seen or k not in index or not row["scope"]:
        problems.append(k+" duplicate/unknown row")
    seen.add(k)
    if not anchor(root,row["origin"]):problems.append(k+" original anchor "+row["origin"])
    for entry in row["native"]:
        if not anchor(n/"Sources/PiliNative",entry):problems.append(k+" Swift anchor "+entry)
    for item in row["evidence"]:
        if not (n/"Acceptance/evidence"/item).is_file():problems.append(k+" missing evidence "+item)
if required!=seen:problems.append("ID coverage differs: "+str(required^seen))
hashed=m["sourceSHA256"]
fixed_sources={p for p in subprocess.check_output(["git","ls-tree","-r","--name-only",baseline,
    "lib/pages/video","lib/plugin/pl_player"],cwd=root).decode("utf-8").splitlines() if p.endswith(".dart")}
fixed_sources|={"lib/pages/setting/pages/play_speed_set.dart","lib/router/app_pages.dart"}
if fixed_sources!=set(hashed):problems.append("unmapped fixed sources: "+str(fixed_sources^set(hashed)))
for f,h in hashed.items():
    raw=fixed(f).encode("utf-8").replace(b"\r\n",b"\n")
    if hashlib.sha256(raw).hexdigest()!=h:problems.append("baseline source changed: "+f)
for p in m.get("preferences",[]):
    if p["id"] not in index or not anchor(n/"Sources/PiliNative",p["native"]):problems.append("preference "+str(p))
if problems:raise SystemExit("\n".join(problems))
print(f"Archive detail audit: {len(rows)} mandatory pages/routes/subsystem, {len(hashed)} pinned Dart files and {len(m.get('preferences',[]))} additional preference consumers")


# The top-level parity ID and the README heading both matter ("其他" appears repeatedly).
readme=fixed("README.md").splitlines()
feature_manifest=json.loads((n/"Acceptance/evidence/readme-video-features.json").read_text(encoding="utf-8"))
assert feature_manifest["baselineRevision"]==baseline
features=feature_manifest["rows"]
feature_ids={v["id"] for v in features}
assert len(features)==len(feature_ids)
for row in features:
    id_=row["id"];num=row["line"];_,section,leaf=id_.replace("upstream:","upstream/").split("/",2)
    assert id_ in index and readme[num-1].strip()=="- [x] "+leaf,(id_,num)
    assert next(v for v in reversed(readme[:num]) if v.startswith("## ")).strip()=="## "+section,id_
    if row["kind"] in ("video","video-group"):
        assert anchor(root,row["upstream"]),(id_,row["upstream"])
        for entry in row["native"]:assert anchor(n/"Sources/PiliNative",entry),(id_,entry)
        for item in row["evidence"]:assert (n/"Acceptance/evidence"/item).is_file(),(id_,item)
    else:
        for target in row.get("implementation",[]):assert (n/target).is_file(),(id_,target)
        for target in row.get("evidence",[]):assert (n/target).is_file(),(id_,target)
    for child in row.get("children",[]):assert child in index,(id_,child)
    if id_ in ("upstream:功能/视频播放相关","upstream:功能/视频详情页相关"):
        assert set(row["children"])<=feature_ids,id_
print(f"{len(features)} exact README items: {sum(r['kind'] in ('video','video-group') for r in features)} directly audited video items, 14 already-reviewed child features, 2 cross-domain groups and 3 unspecified headings")
