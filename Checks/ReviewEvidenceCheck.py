"""Local negative checks for review lineage, receipts and device delivery. No account or signing operations."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import parity
import review_receipts as receipts
import review_delivery as delivery
from inspect_ipa import application_identity, BASE_BUNDLE_ID


class ReviewChecks(unittest.TestCase):
    def test_personal_team_prefix_is_only_a_verified_signing_identity(self):
        team="ABCDEFGHIJ"
        def profile():return {"TeamIdentifier":[team],"ApplicationIdentifierPrefix":[team],"Entitlements":{"application-identifier":team+".*"}}
        def signed(bundle):return {"com.apple.developer.team-identifier":team,"application-identifier":team+"."+bundle}
        prefixed="XTL-"+team+"."+BASE_BUNDLE_ID
        self.assertEqual(application_identity({"CFBundleIdentifier":BASE_BUNDLE_ID}),BASE_BUNDLE_ID)
        for bundle in (BASE_BUNDLE_ID,prefixed):
            self.assertEqual(application_identity({"CFBundleIdentifier":bundle},signed(bundle),profile()),BASE_BUNDLE_ID)
        with self.assertRaises(SystemExit):application_identity({"CFBundleIdentifier":prefixed})
        for bundle in ("XTL-1234567890."+BASE_BUNDLE_ID,"XTL-"+team+".com.example.other","com.example.other"):
            with self.assertRaises(SystemExit):application_identity({"CFBundleIdentifier":bundle},signed(bundle),profile())
        with self.assertRaises(SystemExit):application_identity({"CFBundleIdentifier":prefixed},signed(prefixed),dict(profile(),TeamIdentifier=["1234567890"]))
        with self.assertRaises(SystemExit):application_identity({"CFBundleIdentifier":prefixed},signed(BASE_BUNDLE_ID),profile())

    def test_duplicate_json_keys_rejected(self):
        with self.assertRaises(ValueError):json.loads('{"status":1,"status":2}',object_pairs_hook=receipts.obj)

    def test_no_partial_exceptions_and_required_account_witnesses(self):
        current={k:{"state":"implemented"} for k in ("page:login","route:/loginPage","page:login_devices")}
        self.assertEqual(parity.account_implementation(current),[])
        for key in current:
            bad=copy.deepcopy(current);bad[key]["state"]="partial"
            with self.assertRaises(SystemExit):parity.account_implementation(bad)
        with self.assertRaises(SystemExit):parity.account_implementation(dict(current,**{"page:video":{"state":"pending"}}))
        original=receipts.load
        def without_witnesses(path):
            value=original(path)
            if path.name=="account-grant-scope.json":value["records"]["page:login"]["clients"]=[]
            return value
        with patch.object(parity,"load",without_witnesses),self.assertRaises(SystemExit):parity.account_implementation(current)

    def test_source_notes_are_fixed_bare_lines_only(self):
        notes={k:{"state":"source-note","evidence":["Acceptance/evidence/common-readme-scope.json"]} for k in parity.SOURCE_NOTES}
        self.assertEqual(parity.source_notes(notes,True),sorted(notes))
        with self.assertRaises(SystemExit):parity.source_notes(dict(notes,**{"page:video":{"state":"source-note"}}))
        bad=copy.deepcopy(notes);bad[next(iter(bad))]["evidence"]=[]
        with self.assertRaises(SystemExit):parity.source_notes(bad,True)

    def test_actual_source_tree_and_final_only_commit_lineage(self):
        with tempfile.TemporaryDirectory(prefix="pili-review-tree-") as t:
            root=Path(t);n=root/"Native"
            files={"Native/Checks/gate.py":b"pass\n","Native/Sources/App.swift":b"print(1)\n",
                   "Native/Acceptance/evidence/review.md":b"local review\n","Native/Acceptance/final.json":b"{}\n",
                   "Native/Wire/Package.swift":b"// source\n",
                   "ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png":b"not-an-image\0"}
            for name,data in files.items():p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
            def git(*args):return subprocess.check_output(["git","-C",str(root),*args],stderr=subprocess.PIPE)
            git("init","-q");git("add",".");git("-c","user.name=Fixture","-c","user.email=fixture@localhost","commit","-qm","source")
            first=git("rev-parse","HEAD").decode().strip()
            with patch.object(receipts,"ROOT",root),patch.object(receipts,"NATIVE",n):
                frozen=receipts.checkout(first)
                (n/"Acceptance/final.json").write_text('{"status":"pending"}')
                git("add",".");git("-c","user.name=Fixture","-c","user.email=fixture@localhost","commit","-qm","review conclusion")
                second=git("rev-parse","HEAD").decode().strip()
                self.assertNotEqual(first,second)
                self.assertEqual(frozen,receipts.checkout(second))
                p=n/"Sources/New.swift";p.write_text("// untracked input")
                with self.assertRaises(ValueError):receipts.checkout(first)
                p.unlink()
                p=n/"Sources/App.swift";p.write_text("print(2)")
                with self.assertRaises(ValueError):receipts.checkout(first)
                p.write_bytes(files["Native/Sources/App.swift"])
                if hasattr(os,"symlink"):
                    alias=n/"Sources/external";alias.symlink_to(root,target_is_directory=True)
                    with self.assertRaises(ValueError):receipts.current_fingerprint()
                    alias.unlink()

    def test_frozen_receipts_detect_missing_step_changed_log_and_stale_code(self):
        rev="a"*40;fingerprint="b"*64
        with tempfile.TemporaryDirectory(prefix="pili-review-logs-") as t:
            folder=Path(t);(folder/"unsigned.ipa").write_bytes(b"unsigned fixture; package validation is separately exercised")
            review={"sourceRevision":rev,"fingerprint":fingerprint,"receipts":{}}
            for kind,commands in receipts.CAPTURE.items():
                text="".join("$ "+" ".join(c)+"\nresult\n$ exit 0\n" for c in commands)
                (folder/(kind+".log")).write_text(text)
                data=dict(kind=kind,schema=1,revision=rev,fingerprint=fingerprint,commands=commands,
                          logSHA256=receipts.sha_file(folder/(kind+".log")))
                if kind=="unsigned":data.update(discovery="personal",ipaSHA256=receipts.sha_file(folder/"unsigned.ipa"))
                (folder/(kind+".json")).write_text(json.dumps(data))
                review["receipts"][kind]=receipts.sha_file(folder/(kind+".json"))
            with patch.object(receipts,"revision",lambda v:v),patch.object(receipts,"checkout",lambda v:fingerprint),patch.object(receipts,"unsigned_check") as check:
                self.assertEqual(receipts.validate(review,folder),(rev,fingerprint));check.assert_called_once()
                original=(folder/"host.log").read_bytes();(folder/"host.log").write_bytes(original+b"changed")
                with self.assertRaises(ValueError):receipts.validate(review,folder)
                (folder/"host.log").write_bytes(original)
                bad=copy.deepcopy(review);bad["fingerprint"]="c"*64
                with self.assertRaises(ValueError):receipts.validate(bad,folder)
                p=folder/"host.json";data=receipts.load(p);data["commands"]=[];p.write_text(json.dumps(data))
                bad=copy.deepcopy(review);bad["receipts"]["host"]=receipts.sha_file(p)
                with self.assertRaises(ValueError):receipts.validate(bad,folder)

    def test_domain_pass_requires_specific_evidence(self):
        review={"status":"passed","baseline":parity.BASE,"fingerprint":"b"*64,
                "domains":{k:{"result":"passed","evidence":["Acceptance/evidence/"+f for f in v]} for k,v in receipts.WITNESSES.items()}}
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)/"review.json";p.write_text(json.dumps(review))
            with patch.object(parity,"REVIEW",p),patch.object(parity,"fingerprint",lambda:"b"*64),patch.object(parity,"validate",return_value=("a"*40,"b"*64)) as validate:
                self.assertEqual(parity.final_review()[1],"a"*40);validate.assert_called_once()
                review["domains"]["playback"]["evidence"]=["Acceptance/evidence/retained-discovery.md"]
                p.write_text(json.dumps(review))
                with self.assertRaises(SystemExit):parity.final_review()

    def test_device_and_personal_entitlements(self):
        uid="01234567-0123456789abcdef"
        profile={"ProvisionedDevices":[uid],"Platform":["iOS"],"Entitlements":{"get-task-allow":True}}
        delivery.for_device(profile,uid.upper())
        with self.assertRaises(ValueError):delivery.for_device(profile,"11234567-0123456789abcdef")
        with self.assertRaises(ValueError):delivery.for_device(dict(profile,ProvisionsAllDevices=True),uid)
        fields={"application-identifier":"T.com.example","com.apple.developer.team-identifier":"T","get-task-allow":True,"keychain-access-groups":["T.com.example"]}
        allowed={"get-task-allow":True,"keychain-access-groups":["T.*"]}
        delivery.personal_entitlements(fields,allowed)
        with self.assertRaises(ValueError):delivery.personal_entitlements(dict(fields,**{"com.apple.developer.networking.multicast":True}),allowed)
        with self.assertRaises(ValueError):delivery.personal_entitlements(fields,dict(allowed,**{"keychain-access-groups":["OTHER.*"]}))

    def test_executable_normalization_is_limited_to_signing_bytes(self):
        def segment(name,off,size,sections=b""):
            return struct.pack("<II16s4Q4I",0x19,72+len(sections),name,0x100000000+off,4096,off,size,7,5,len(sections)//80,0)+sections
        section=struct.pack("<16s16sQQ8I",b"__text",b"__TEXT",0x100001000,4096,4096,2,0,0,0,0,0,0)
        def binary(signed,change=False):
            payload=(b"A" if not change else b"B")*4096+b"linker-bytes"*4
            sig=b"fixture-not-a-signature"*7 if signed else b""
            end=4096+len(payload)
            commands=segment(b"__TEXT",0,8192,section)+segment(b"__LINKEDIT",8192,len(payload)-4096+len(sig))
            if signed:commands+=struct.pack("<4I",0x1d,16,end,len(sig))
            header=struct.pack("<8I",0xfeedfacf,0x100000c,0,2,3 if signed else 2,len(commands),0,0)
            return header+commands+b"\0"*(4096-len(header)-len(commands))+payload+sig
        self.assertEqual(delivery.executable_digest(binary(False)),delivery.executable_digest(binary(True)))
        self.assertNotEqual(delivery.executable_digest(binary(False)),delivery.executable_digest(binary(True,True)))
        b=bytearray(binary(True));b[300]=1
        with self.assertRaises(ValueError):delivery.executable_digest(b)

    def test_artifact_path_escape_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            for name in ("../receipt.json","/etc/passwd","a//b","a\\b"):
                with self.assertRaises(ValueError):receipts.file_at(Path(t),name)


def saved_ipa(path):
    from apple_seal import verify_development
    with zipfile.ZipFile(path) as z:
        name=next(n for n in z.namelist() if n.endswith(".app/embedded.mobileprovision"));prefix=name[:-len("embedded.mobileprovision")]
        profile=delivery.profile_issued_by_apple(z.read(name))
        verify_development(z,prefix,profile)
        executable=prefix+plistlib.loads(z.read(prefix+"Info.plist"))["CFBundleExecutable"]
        binary=z.read(executable);delivery.development_certificate(binary,profile)
        delivery.for_device(profile,profile["ProvisionedDevices"][0])
        delivery.personal_entitlements(delivery.executable_entitlements(binary),profile["Entitlements"])
        application_identity(plistlib.loads(z.read(prefix+"Info.plist")),delivery.executable_entitlements(binary),profile)
        delivery.executable_digest(binary)
        tampered=bytearray(z.read(name));tampered[len(tampered)//2]^=1
        try:delivery.profile_issued_by_apple(tampered)
        except (ValueError,subprocess.CalledProcessError):pass
        else:raise AssertionError("Altered Apple profile accepted")
    print("Saved development package: Apple-issued profile, authorized current signing leaf and intended device checked; altered CMS rejected; no identifiers displayed")


if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("--saved-ipa",type=Path);a=p.parse_args()
    tests=unittest.defaultTestLoader.loadTestsFromTestCase(ReviewChecks)
    result=unittest.TextTestRunner(verbosity=2).run(tests)
    if not result.wasSuccessful():raise SystemExit(1)
    if a.saved_ipa:saved_ipa(a.saved_ipa)
