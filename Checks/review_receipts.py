"""Capture and verify release prerequisites. Does not sign, install or access account credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
import plistlib

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT/"Native"
DEFAULT = NATIVE/"dist/final-review"
CAPTURE = {
    "host": [["bash", "Checks/run.sh"]],
    "media": [["python3", "Checks/"+f+".py"] for f in ("live_remux","live_decode","native_decode","audio_segments","presentation_timing","legacy_durl")]
             + [["bash","Checks/storage_locations.sh"], ["python3","Checks/backup_recovery.py"],
                ["python3","Checks/subtitle_raster.py","--ios"], ["python3","Checks/anime4k.py"]],
    "unsigned": [["bash", "build.sh", "--release-personal"]],
}
WITNESSES = {
    "discovery": ("discovery-search-audit.md","retained-discovery.md","reaudit-2026-11-13-surface.md"),
    "playback": ("archive-detail-signoff.json","player-key-gestures.json","reaudit-2026-11-13-media.md"),
    "series-courses": ("season-catalog-audit.md","season-course-detail.md"),
    "audio": ("listener-audio-audit.md","offline-listening-signoff.json"),
    "danmaku-subtitles": ("danmaku-subtitles.json","danmaku-subtitles-audit.md"),
    "accounts": ("account-messages-signoff.json","account-grant-scope.json","reaudit-2026-11-13-data.md","reaudit-2026-11-13-session.md","reaudit-2026-11-13-cookies.md"),
    "library": ("personal-library-signoff.json",),
    "social-messages": ("social-reading-signoff.json","account-messages-signoff.json"),
    "creator": ("creator-sections.md","personal-library-signoff.json"),
    "live": ("live-room-controls.md","live-room-header.md","community-and-live-emotes.md"),
    "offline": ("offline-listening-signoff.json","offline-files-audit.md"),
    "settings-backup": ("backup-restore-audit.md","interface-signoff.json","reaudit-custom-services.md"),
    "ios-integration": ("media-system-signoff.json","interface-signoff.json","reaudit-2026-11-13-interface.md"),
    "package": ("personal-device-signing.md","reaudit-2026-11-13-overview.md"),
}
SKIP = {".build",".swiftpm",".git","__pycache__"}
STAMP = "PiliNativeSourceRevision"
def require(ok, why):
    if not ok: raise ValueError(why)
def obj(pairs):
    d=dict(pairs);require(len(d)==len(pairs),"Duplicate JSON keys in release evidence");return d
def load(path):
    return json.loads(path.read_text(encoding="utf-8"),object_pairs_hook=obj)
def git(*args):
    return subprocess.check_output(["git","-C",str(ROOT),*args])
def is_review_input(p):
    parts=Path(p).parts
    if any(s in SKIP for s in parts) or p.endswith(".pyc"):return False
    if p=="ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png":return True
    if len(parts)<2 or parts[0]!="Native":return False
    if len(parts)==2:return parts[1] in {"parity.json","Package.swift","Package.resolved","xtool.yml","build.sh","build.cmd"}
    if parts[1] == "Acceptance":return parts[2]=="evidence"
    if parts[1]=="MediaKit" and "Vendor" in parts:return False
    return parts[1] in {"Sources","Resources","Checks","Tools","Wire","ArchiveKit","ColorKit","MediaKit"}
def sha_file(p):
    h=hashlib.sha256()
    with p.open("rb") as f:
        for block in iter(lambda:f.read(1024*1024),b""):h.update(block)
    return h.hexdigest()
def is_hash(value):
    return isinstance(value,str) and re.fullmatch(r"[0-9a-f]{64}",value) is not None
def canonical(data):
    if b"\0" not in data:
        try:data.decode("utf-8")
        except UnicodeDecodeError:pass
        else:return data.replace(b"\r\n",b"\n")
    return data
def fingerprint_rows(rows):
    h=hashlib.sha256()
    for name,raw in rows:
        h.update(name.encode()+b"\0"+hashlib.sha256(canonical(raw)).digest())
    return h.hexdigest()
def current_fingerprint():
    # Include tracked deletions via comparison with the frozen commit, AND new untracked build inputs.
    roots = [NATIVE/n for n in ("Sources","Resources","Checks","Tools","Acceptance/evidence","Wire","ArchiveKit","ColorKit","MediaKit")]
    paths = [f for f in NATIVE.iterdir() if f.is_file() and is_review_input(f.relative_to(ROOT).as_posix())]
    paths.append(ROOT/"ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png")
    for base in roots:
        for dirpath,dirs,files in os.walk(base):
            dirs[:] = [d for d in dirs if d not in SKIP and not (base==NATIVE/"MediaKit" and d=="Vendor")]
            for d in dirs:require(not (Path(dirpath)/d).is_symlink(),"External source directory: "+str(Path(dirpath)/d))
            for name in files:
                p=Path(dirpath)/name
                if is_review_input(p.relative_to(ROOT).as_posix()):paths.append(p)
    for p in paths:require(not p.is_symlink() and p.resolve().is_relative_to(ROOT.resolve()),"External build input: "+str(p))
    return fingerprint_rows((p.relative_to(ROOT).as_posix(),p.read_bytes()) for p in sorted(paths,key=lambda p:p.relative_to(ROOT).as_posix()))
def revision(v):
    require(isinstance(v,str) and re.fullmatch(r"[0-9a-f]{40}",v),"Invalid full source revision")
    require(git("rev-parse","--verify",v+"^{commit}").decode().strip()==v,"Unknown source commit")
    return v
def revision_fingerprint(rev):
    revision(rev)
    tree=git("ls-tree","-rz","--full-tree",rev,"--","Native","ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png")
    pairs=[]
    for entry in tree.split(b"\0"):
        if not entry:continue
        meta,path=entry.split(b"\t",1);file=path.decode()
        if not is_review_input(file):continue
        mode,ty,oid=meta.split()
        require(ty==b"blob" and mode in (b"100644",b"100755"),"Unexpected Git build input: "+file)
        pairs.append((file,oid))
    pairs.sort()
    from io import BytesIO
    all_data=BytesIO(subprocess.check_output(["git","-C",str(ROOT),"cat-file","--batch"],input=b"".join(oid+b"\n" for _,oid in pairs)))
    def rows():
        for file,oid in pairs:
            oid2,ty,n=all_data.readline().split()
            require(oid==oid2 and ty==b"blob","Git blob mismatch")
            b=all_data.read(int(n));require(len(b)==int(n) and all_data.readline()==b"\n","Truncated Git blob");yield file,b
    return fingerprint_rows(rows())
def checkout(rev):
    expected=revision_fingerprint(rev)
    require(current_fingerprint()==expected,"Worktree differs from frozen source, checks or evidence in "+rev)
    return expected
def file_at(folder, name):
    require(isinstance(name,str) and name and "\\" not in name and not PurePosixPath(name).is_absolute()
            and str(PurePosixPath(name))==name and ".." not in PurePosixPath(name).parts,"Invalid artifact name")
    p=folder/name
    require(p.resolve().is_relative_to(folder.resolve()) and not p.is_symlink() and p.is_file() and p.stat().st_size>0,"Missing reviewed artifact: "+name)
    return p
def info(ipa):
    with zipfile.ZipFile(ipa) as z:
        names=z.namelist()
        matches=[x for x in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist",x)]
        require(len(matches)==1 and len(names)==len(set(names)),"Ambiguous IPA bundle")
        p=matches[0].rsplit("/",1)[0]+"/"
        return plistlib.loads(z.read(matches[0])),p
def unsigned_check(ipa,rev,discovery="personal"):
    require(discovery=="personal","Final personal build uses personal discovery")
    subprocess.run(["python3",str(NATIVE/"Checks/inspect_ipa.py"),"--discovery",discovery,str(ipa)],check=True,stdout=sys.stderr)
    i,p=info(ipa);require(i.get(STAMP)==rev,"Unsigned package source revision differs")
    with zipfile.ZipFile(ipa) as z:
        require(p+"embedded.mobileprovision" not in z.namelist(),"A development-signed package was presented as the unsigned build")
        from apple_seal import commands,parts
        b=z.read(p+i["CFBundleExecutable"])
        try: _,sig=commands(b)
        except ValueError as err:
            if str(err)!="Missing executable signature":raise
        else:require(0x10000 not in parts(sig),"Unsigned review does not accept development CMS")
def capture(kind,rev,folder):
    rev=revision(rev);frozen=checkout(rev)
    # Prevent inherited shell/Swift overrides from turning the normal verification into an unrelated command.
    env=os.environ.copy()
    for k in ("BASH_ENV","ENV","PYTHONPATH","PILI_PUBLIC_QUALITY","PILI_WIRE_PUBLIC"):env.pop(k,None)
    env.update(PILI_SOURCE_REV=rev,SOURCE_DATE_EPOCH=git("show","-s","--format=%ct",rev).decode().strip(),PYTHONDONTWRITEBYTECODE="1")
    folder.mkdir(parents=True,exist_ok=True)
    require(not folder.is_relative_to(ROOT) or not is_review_input((folder/"artifact").relative_to(ROOT).as_posix()),
            "Receipt output would alter the reviewed source tree")
    # A failed rerun must not leave a prior successful receipt looking current.
    (folder/(kind+".json")).unlink(missing_ok=True)
    print("Capturing",kind,"at",rev,flush=True)
    with tempfile.TemporaryDirectory(prefix=kind+"-",dir=folder) as stage:
        tmp=Path(stage);log=tmp/(kind+".log")
        try:
            with log.open("wb") as out:
                for command in CAPTURE[kind]:
                    print("  "+" ".join(command),flush=True)
                    out.write(("$ "+" ".join(command)+"\n").encode());out.flush()
                    subprocess.run(command,stdout=out,stderr=subprocess.STDOUT,check=True,cwd=NATIVE,env=env)
                    out.write(b"$ exit 0\n");out.flush()
            data=dict(kind=kind,schema=1,revision=rev,fingerprint=frozen,commands=CAPTURE[kind],logSHA256=sha_file(log))
            if kind=="unsigned":
                ipa=tmp/"unsigned.ipa";shutil.copyfile(NATIVE/"dist/PiliNative-personal-unsigned.ipa",ipa)
                unsigned_check(ipa,rev);data.update(ipaSHA256=sha_file(ipa),discovery="personal")
            require(current_fingerprint()==frozen,"Source or evidence changed while capturing "+kind)
        except BaseException:
            if log.is_file():shutil.copyfile(log,folder/(kind+".failed.log"))
            raise
        receipt=tmp/(kind+".json");receipt.write_text(json.dumps(data,indent=2,sort_keys=True)+"\n",encoding="utf-8")
        for item in (("unsigned.ipa",) if kind=="unsigned" else ())+ (kind+".log",kind+".json"):
            (tmp/item).replace(folder/item)
    print(kind+" receipt SHA-256: "+sha_file(folder/(kind+".json")),flush=True)
def validate(review, folder):
    rev=revision(review.get("sourceRevision"));frozen=checkout(rev)
    require(review.get("fingerprint")==frozen,"Review source fingerprint mismatch")
    refs=review.get("receipts")
    require(isinstance(refs,dict) and set(refs)==set(CAPTURE),"Require host, media and unsigned personal receipts")
    for k,digest in refs.items():
        p=file_at(folder,k+".json")
        require(is_hash(digest) and sha_file(p)==digest,"Reviewed receipt SHA-256 mismatch: "+k)
        v=load(p)
        require(v.get("schema")==1 and v.get("kind")==k and v.get("commands")==CAPTURE[k] and v.get("revision")==rev and v.get("fingerprint")==frozen,"Stale, incomplete or unrelated execution receipt: "+k)
        log=file_at(folder,k+".log")
        require(is_hash(v.get("logSHA256")) and sha_file(log)==v["logSHA256"],"Execution log digest mismatch: "+k)
        with log.open("rb") as f:
            ran=[line.decode("utf-8","strict").rstrip("\r\n")[2:] for line in f if line.startswith(b"$ ")]
        expected=[]
        for cmd in CAPTURE[k]:expected.extend([" ".join(cmd),"exit 0"])
        require(ran==expected,"Missing checked command or successful exit in frozen log: "+k)
        if k=="unsigned":
            ipa=file_at(folder,"unsigned.ipa")
            require(v.get("discovery")=="personal" and is_hash(v.get("ipaSHA256")) and v["ipaSHA256"]==sha_file(ipa),"Unsigned artifact digest mismatch")
            unsigned_check(ipa,rev)
    return rev,frozen

def draft(rev,folder):
    """Generate a PENDING review structure after capturing all three execution receipts."""
    rev=revision(rev)
    review={"status":"pending","scope":"all-feasible-ios",
            "baseline":"d9e9626f1a3f89cd9ca85e18f61aaba02634e12a",
            "sourceRevision":rev,"fingerprint":checkout(rev),
            "issuerDependent":[],
            "sourceNotes":sorted(["upstream:feat/其他","upstream:opt/其他","upstream:fix/bugs"]),
            "receipts":{k:sha_file(file_at(folder,k+".json")) for k in CAPTURE},
            "domains":{k:{"result":"pending","evidence":["Acceptance/evidence/"+f for f in values]} for k,values in WITNESSES.items()}}
    validate(review,folder)
    return review

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest="cmd",required=True)
    cmd=sub.add_parser("capture");cmd.add_argument("kind",choices=CAPTURE);cmd.add_argument("--revision",required=True);cmd.add_argument("--artifacts",type=Path,default=DEFAULT)
    cmd=sub.add_parser("draft");cmd.add_argument("--revision",required=True);cmd.add_argument("--artifacts",type=Path,default=DEFAULT)
    a=p.parse_args()
    try:
        if a.cmd=="capture":capture(a.kind,a.revision,a.artifacts.resolve())
        else:print(json.dumps(draft(a.revision,a.artifacts.resolve()),indent=2,ensure_ascii=False))
    except (ValueError,OSError,subprocess.CalledProcessError) as exc:raise SystemExit(str(exc))
