"""Check migration inventory against the immutable upstream baseline, not the port's README."""
import argparse
import json
import os
import re
import subprocess
from collections import Counter
from pathlib import Path
from review_receipts import (DEFAULT, WITNESSES, current_fingerprint, load, validate)

ROOT = Path(__file__).resolve().parents[2]
BASE = "d9e9626f1a3f89cd9ca85e18f61aaba02634e12a"
MANIFEST = ROOT / "Native" / "parity.json"
def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args]).decode()
def baseline():
    routes = git("show", BASE + ":lib/router/app_pages.dart")
    pages = git("ls-tree", "-d", "--name-only", BASE + ":lib/pages").splitlines()
    readme = git("show", BASE + ":README.md")
    items = {"page:" + name: "lib/pages/" + name for name in pages}
    items.update({"route:" + name: "lib/router/app_pages.dart" for name in re.findall(r"name:\s*'([^']+)'", routes)})
    prefs_path = "lib/utils/storage_key.dart"
    prefs = git("show", BASE + ":" + prefs_path)
    for group, body in re.findall(r"abstract final class (SettingBoxKey|VideoBoxKey) \{(.*?)\n\}", prefs, re.S):
        for key in re.findall(r"\b([A-Za-z_]\w*)\s*=\s*'[^']+'", body):
            items["preference:" + group + "/" + key] = prefs_path
    section = ""
    for line in readme.splitlines():
        if line.startswith("## "): section = line[3:].strip()
        m = re.match(r"\s*[-*] \[[xX]\] (.+)", line)
        if m and section in {"feat","功能","opt","fix"}:
            items["upstream:" + section + "/" + m[1].strip()] = "README.md"
    for name in ["plugin/pl_player","services/download","services/audio_handler.dart","grpc","tcp","utils/storage.dart","utils/accounts","utils/recommend_filter.dart"]:
        items["subsystem:" + name] = "lib/" + name
    tree = git("ls-tree", "-r", "--name-only", BASE, "lib/pages", "lib/services", "ios/Runner").splitlines()
    for path in tree:
        if re.fullmatch(r"lib/pages/[^/]+/.+/view\.dart", path):
            items["screen:" + path[len("lib/pages/"):-len("/view.dart")]] = path
        if path.startswith("lib/services/") and path.endswith(".dart"):
            items["subsystem:" + path[len("lib/"):]] = path
        if path in {"ios/Runner/AppDelegate.swift", "ios/Runner/SceneDelegate.swift", "ios/Runner/PipPlugin.swift", "ios/Runner/Info.plist"}:
            items["platform:" + path] = path
    return items
NATIVE = MANIFEST.parent
REVIEW = NATIVE / "Acceptance" / "final.json"
DOMAINS = ("discovery", "playback", "series-courses", "audio", "danmaku-subtitles",
           "accounts", "library", "social-messages", "creator", "live", "offline",
           "settings-backup", "ios-integration", "package")
def evidence_files(names, prefixes, suffix=None):
    if not isinstance(names, list) or not names: return False
    for name in names:
        if not isinstance(name, str) or "\\" in name or ".." in name.split("/") or not name.startswith(prefixes): return False
        f = NATIVE / name
        if not f.resolve().is_relative_to(NATIVE.resolve()) or f.is_symlink() or not f.is_file() or f.stat().st_size == 0: return False
        if suffix and f.suffix != suffix: return False
    return True

def fingerprint():
    return current_fingerprint()

def final_review(artifacts=DEFAULT):
    review=load(REVIEW)
    if review.get("status")!="passed" or review.get("baseline") != BASE or review.get("fingerprint")!=fingerprint():
        raise SystemExit("Final review is missing, pending or refers to different source")
    if set(review.get("domains",{}))!=set(DOMAINS): raise SystemExit("Final review omits domains")
    for name,row in review["domains"].items():
        if row.get("result")!="passed" or not evidence_files(row.get("evidence"),("Acceptance/evidence/",)):
            raise SystemExit("Missing final review evidence for "+name)
        if not {"Acceptance/evidence/"+f for f in WITNESSES[name]} <= set(row["evidence"]):
            raise SystemExit("Final review omits the required domain-specific evidence for "+name)
    rev,frozen=validate(review,artifacts.resolve())
    return review,rev,frozen

SOURCE_NOTES={"upstream:feat/其他":(120,"feat","- [x] 其他"),
              "upstream:opt/其他":(136,"opt","- [x] 其他"),
              "upstream:fix/bugs":(141,"fix","- [x] bugs")}

def source_notes(current,require_all=False):
    marked={k for k,v in current.items() if v["state"]=="source-note"}
    if not marked <= SOURCE_NOTES.keys() or (require_all and marked!=SOURCE_NOTES.keys()):
        raise SystemExit("Only the three unspecified README lines may be source notes")
    if not marked:return []
    attachment="Acceptance/evidence/common-readme-scope.json"
    ledger=load(NATIVE/attachment)
    if ledger.get("baseline")!=BASE:raise SystemExit("Source-note baseline mismatch")
    lines=git("show",BASE+":README.md").splitlines()
    for key in marked:
        number,section,literal=SOURCE_NOTES[key]
        row=ledger["entries"][key]
        last_section=next(line for line in reversed(lines[:number]) if line.startswith("## "))[3:]
        if not (row.get("file")=="README.md" and row.get("line")==number and row.get("literal")==literal
                and row.get("section")==section==last_section and lines[number-1]==literal
                and row.get("disposition")=="unspecified-summary" and row.get("eligible") is False
                and row.get("children")==[] and number<len(lines) and not lines[number].startswith(("  -","  *"))):
            raise SystemExit("Source note is not an unspecified fixed README line: "+key)
        blame=git("blame","--line-porcelain","-L",f"{number},{number}",BASE,"--","README.md").splitlines()[0].split()[0]
        if blame!=row.get("introduced_by_blame") or blame!="33b9a936207b977a06def52993083e8274ea48be":
            raise SystemExit("Source-note provenance mismatch: "+key)
        if not evidence_files(current[key].get("evidence"),("Acceptance/evidence/",)) or attachment not in current[key]["evidence"]:
            raise SystemExit("Missing source-note evidence: "+key)
    return sorted(marked)

def account_implementation(current):
    # The pinned client's AppSign is public source code. Login/device-list requests are ordinary
    # client work and must not be excused as issuer-only capabilities.
    unresolved=sorted(k for k,v in current.items() if v["state"] in {"partial","pending"})
    if unresolved:raise SystemExit("Unresolved native work; no partial exceptions: "+repr(unresolved))
    expected={"page:login","route:/loginPage","page:login_devices"}
    src=load(NATIVE/"Acceptance/evidence/account-grant-scope.json")
    records=src["records"]
    if src.get("baseline")!=BASE or src.get("disposition")!="implemented-public-upstream-protocol" or set(records)!=expected:
        raise SystemExit("Missing normal upstream account protocol implementation")
    catalog=load(NATIVE/"Acceptance/evidence/account-messages-signoff.json")["records"]
    for key,record in records.items():
        if current[key]["state"]!="implemented" or catalog[key]["verdict"] not in {"implemented","verified"} or record.get("state")!="implemented" or record.get("requires"):
            raise SystemExit("Account action is not fully implemented: "+key)
        if not evidence_files(record["evidence"],("Checks/","Acceptance/evidence/")):raise SystemExit("Missing grant evidence: "+key)
        needed_original={"lib/http/login.dart|static Future codePoll(String authCode)","lib/http/login.dart|Api.loginByPwdApi",
                         "lib/pages/login/controller.dart|tokenInfo['access_token']","lib/pages/login/controller.dart|tokenInfo['refresh_token']",
                         "lib/utils/app_sign.dart|static void appSign("}
        needed_client={"Account/QRLogin.swift|struct QRLoginView","Account/CookieLogin.swift|struct CookieLogin",
                       "Account/WebsiteLogin.swift|WebLoginIdentity.verify","Account/MobileAuthorization.swift|func mobileIdentity",
                       "Account/QRLogin.swift|找回密码","Account/MobileClientSigning.swift|enum MobileClientSigning",
                       "Account/NativeLoginForm.swift|struct NativeLoginForm"}
        if key=="page:login_devices":
            needed_original={"lib/http/login.dart|Future<LoadingState<LoginDevicesData>> loginDevices()",
                             "lib/http/login.dart|AppSign.appSign(params)","lib/http/login.dart|Api.loginDevices"}
            needed_client={"Account/MobilePassport.swift|/x/safecenter/user_login_devices","Account/LoginDevices.swift|MobilePassport.deviceListRequest","Account/LoginDevices.swift|is_current_device",
                           "Account/LoginDevices.swift|h5/account-h5/device","Account/MobileAuthorization.swift|func mobileIdentity"}
        if not (isinstance(record.get("original"),list) and isinstance(record.get("clients"),list)
                and needed_original<=set(record["original"]) and needed_client<=set(record["clients"])):
            raise SystemExit("Missing normal account protocol witnesses: "+key)
        for witness in record["original"]:
            file,marker=witness.split("|",1)
            if not file.startswith("lib/") or marker not in git("show",BASE+":"+file):raise SystemExit("Missing pinned account action: "+key)
        for witness in record["clients"]:
            file,marker=witness.split("|",1)
            f="Sources/PiliNative/"+file
            if not evidence_files([f],("Sources/PiliNative/",),".swift") or marker not in (NATIVE/f).read_text(encoding="utf-8"):
                raise SystemExit("Missing native account action: "+key)
    return []

def main():
    p=argparse.ArgumentParser(); mode=p.add_mutually_exclusive_group()
    mode.add_argument("--complete",action="store_true")
    mode.add_argument("--client-complete",action="store_true",help="Strict complete review for signing; no partial exceptions")
    mode.add_argument("--verify-delivery",action="store_true",help="Repeat the client review and compare the intended signed device IPA")
    p.add_argument("--artifacts",type=Path,default=Path(os.environ.get("PILI_REVIEW_ARTIFACTS",str(DEFAULT))))
    p.add_argument("--ipa",type=Path);p.add_argument("--ipa-sha256");p.add_argument("--device-id")
    p.add_argument("--init",action="store_true");p.add_argument("--fingerprint",action="store_true");p.add_argument("--summary",action="store_true");args=p.parse_args()
    if args.verify_delivery and not all((args.ipa,args.ipa_sha256,args.device_id)):p.error("Delivery verification requires --ipa, --ipa-sha256 and --device-id")
    if args.fingerprint: print(fingerprint());return
    source=baseline()
    if args.init:
        if MANIFEST.exists(): raise SystemExit("Inventory already exists")
        MANIFEST.write_text(json.dumps({k:{"source":v,"state":"pending"} for k,v in sorted(source.items())},indent=2,ensure_ascii=False)+"\n",encoding="utf-8")
    current=load(MANIFEST)
    if set(current)!=set(source): raise SystemExit("Inventory omits or adds baseline IDs: "+repr(set(current)^set(source)))
    for k,row in current.items():
        if row["source"]!=source[k] or row["state"] not in {"pending","partial","implemented","not-ios","source-note"}:raise SystemExit("Invalid record: "+k)
        if row["state"] in {"partial","implemented"}:
            if not evidence_files(row.get("swift"),("Sources/PiliNative/","Wire/Sources/PiliWire/"),".swift"):raise SystemExit("Missing Swift implementation: "+k)
        if row["state"]=="implemented" and not evidence_files(row.get("evidence"),("Checks/","Wire/Tests/","Acceptance/evidence/")):raise SystemExit("Missing acceptance evidence: "+k)
        if row["state"]=="not-ios":
            scope=row.get("platformScope",{}); path=scope.get("file","")
            if not row.get("reason") or not re.fullmatch(r"(?:lib/[\w/]+\.dart|README\.md)",path):
                raise SystemExit("Missing platform source: "+k)
            a,b=scope.get("first",0),scope.get("last",0)
            if not (isinstance(a,int) and isinstance(b,int) and 1<=a<=b and b-a<35):raise SystemExit("Invalid platform source range: "+k)
            lines=git("show",BASE+":"+path).splitlines()
            excerpt="\n".join(lines[a-1:b])
            if b>len(lines) or not all(isinstance(scope.get(t),str) and scope[t] and scope[t] in excerpt for t in ("guard","feature")):
                raise SystemExit("Platform claim does not match the pinned source: "+k)
            equivalent=scope.get("equivalent")
            if equivalent and (equivalent not in current or current[equivalent]["state"]=="not-ios"):
                raise SystemExit("Missing iOS counterpart for platform claim: "+k)
    notes=source_notes(current,require_all=args.complete or args.client_complete or args.verify_delivery)
    counts=Counter(row["state"] for row in current.values())
    print("Baseline coverage records (overlapping indexes, not distinct feature counts):",dict(counts))
    if args.summary:
        for kind in sorted({k.split(":")[0] for k in current}):
            by=Counter(row["state"] for k,row in current.items() if k.split(":")[0]==kind)
            print(kind, sum(by.values()), dict(by))
    if args.complete or args.client_complete or args.verify_delivery:
        limited=account_implementation(current)
        review,rev,frozen=final_review(args.artifacts)
        if review.get("scope")!="all-feasible-ios" or review.get("issuerDependent")!=limited or review.get("sourceNotes")!=notes:
            raise SystemExit("Final review must contain no issuer exceptions and must retain the exact source notes")
        print("Complete native review passed; no partial or pending baseline actions")
        if args.verify_delivery:
            from review_delivery import verify
            verify(args.ipa.resolve(),args.ipa_sha256,args.device_id,args.artifacts.resolve()/"unsigned.ipa",rev,frozen)
if __name__=="__main__":
    try:main()
    except (ValueError,OSError,KeyError,subprocess.CalledProcessError) as exc:raise SystemExit(str(exc))
