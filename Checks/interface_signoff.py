"""Validate the interface audit against the pinned upstream and a staged, synthetic build."""
from collections import Counter
from functools import lru_cache
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import struct
import sys
import tempfile
from inspect_ipa import device_executable

NATIVE = Path(__file__).resolve().parents[1]
ROOT = NATIVE.parent
BASE = "d9e9626f1a3f89cd9ca85e18f61aaba02634e12a"
EVIDENCE = NATIVE / "Acceptance/evidence"


def unique(items):
    result = dict(items)
    if len(result) != len(items):
        raise ValueError("Duplicate JSON key in acceptance evidence")
    return result


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)


def present(path, marker):
    path = path.resolve()
    assert path.is_relative_to(NATIVE), str(path)
    assert marker and marker in path.read_text(encoding="utf-8"), (path, marker)


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True, encoding="utf-8")


@lru_cache
def pinned(file):
    assert not Path(file).is_absolute() and ".." not in Path(file).parts
    return git("show", BASE + ":" + file)


def check_stamp():
    with tempfile.TemporaryDirectory(prefix="pili-interface-stamp-") as folder:
        outer = Path(folder)
        subprocess.run(["git", "init", "-q", str(outer)], check=True)
        # An archive checked out below another repo must never borrow that repo's HEAD.
        subprocess.run(["git", "-C", str(outer), "-c", "user.name=Fixture", "-c",
                        "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "fixture"], check=True)
        native = outer / "archive" / "Native"
        native.mkdir(parents=True)
        dest = native / "Info.plist"
        dest.write_bytes(plistlib.dumps({"PiliNativeSourceRevision": "stale", "Keep": 42}))
        env = {**os.environ, "SOURCE_DATE_EPOCH": "1"}
        env.pop("PILI_SOURCE_REV", None)
        cmd = [sys.executable, str(NATIVE / "Tools/build_stamp.py"), "--root", str(native), "--plist", str(dest)]
        subprocess.run(cmd, check=True, env=env)
        staged = plistlib.loads(dest.read_bytes())
        assert staged == {"Keep": 42, "PiliNativeBuildDate": "1970-01-01T00:00:01Z"}
        subprocess.run(cmd, check=True, env={**env, "PILI_SOURCE_REV": "AB" * 20})
        assert plistlib.loads(dest.read_bytes())["PiliNativeSourceRevision"] == "ab" * 20
        assert subprocess.run(cmd, env={**env, "PILI_SOURCE_REV": "1234567"},
                              stderr=subprocess.DEVNULL).returncode != 0
        sdk = outer / "iPhoneOS.sdk"
        system = sdk / "System/Library/CoreServices/SystemVersion.plist"
        system.parent.mkdir(parents=True)
        (sdk / "SDKSettings.json").write_text(json.dumps({"Version": "27.1", "CanonicalName": "iphoneos27.1"}), encoding="utf-8")
        system.write_bytes(plistlib.dumps({"ProductVersion": "27.1", "ProductBuildVersion": "24A94232"}))
        result = subprocess.check_output(cmd + ["--sdk", str(sdk), "--print-sdk-version"], env=env, text=True)
        assert result.strip() == "27.1"
        staged = plistlib.loads(dest.read_bytes())
        assert staged["DTSDKName"] == "iphoneos27.1" and staged["DTSDKBuild"] == "24A94232"
        assert subprocess.run(cmd + ["--sdk", str(sdk), "--compiled-sdk", str(outer / "different.sdk")],
                              env=env, stderr=subprocess.DEVNULL).returncode != 0
        staged.update(CFBundleSupportedPlatforms=["iPhoneOS"], MinimumOSVersion="26.0")
        header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
        def executable(linked):
            return header + struct.pack("<6I", 0x32, 24, 2, 26 << 16, linked, 0)
        device_executable(executable((27 << 16) | (1 << 8)), staged)
        try:
            device_executable(executable(26 << 16), staged)
        except SystemExit as error:
            assert "Linked SDK differs" in str(error)
        else:
            raise AssertionError("A deployment-target SDK stamp was accepted")
    ios = plistlib.loads((NATIVE / "Resources/Info.plist").read_bytes())
    assert len(ios["UISupportedInterfaceOrientations"]) == 3
    assert len(ios["UISupportedInterfaceOrientations~ipad"]) == 4
    assert ios["UIApplicationSupportsIndirectInputEvents"] and ios["CADisableMinimumFrameDurationOnPhone"]
    assert "audio" in ios["UIBackgroundModes"]
    assert {"piliplus", "bilibili"} <= set(ios["CFBundleURLTypes"][0]["CFBundleURLSchemes"])


def main():
    audit = read_json(EVIDENCE / "interface-signoff.json")
    feedback = read_json(EVIDENCE / "haptic-actions.json")
    parity = read_json(NATIVE / "parity.json")
    assert audit["baseline"] == BASE == feedback["baseline"]
    checkout = (ROOT / ".git").exists() and (ROOT / "lib").is_dir()
    if checkout:
        git("cat-file", "-e", BASE + "^{commit}")
        style = set(re.findall(r"SettingBoxKey\.([a-zA-Z0-9_]+)", pinned("lib/pages/setting/models/style_settings.dart")))
        assert {"preference:SettingBoxKey/" + name for name in style} <= set(audit["records"]), "style settings omitted"
    for k, rec in audit["records"].items():
        assert k in parity and rec["behavior"] and rec["consumers"] and rec["evidence"], k
        assert rec["verdict"] in {"verified", "implemented", "cross-domain", "platform-equivalent", "not-ios", "partial"}, k
        for ref in rec["consumers"]:
            present(NATIVE / ref["file"], ref["symbol"])
        for ref in rec["evidence"]:
            assert (NATIVE / ref).is_file(), (k, ref)
        ref = rec["upstream"]
        if checkout:
            assert ref["symbol"] in pinned(ref["file"]), (k, ref)
    actions = feedback["source_calls"]
    if checkout:
        matches = git("grep", "-n", "-E", r"\bfeedBack\(\)", BASE, "--", "lib")
        found = set()
        for row in matches.splitlines():
            _, file, num, code = row.split(":", 3)
            if file != "lib/utils/feed_back.dart":
                found.add(file + ":" + num)
        assert set(actions) == found, sorted(found ^ set(actions))
    for act, data in actions.items():
        assert data["action"]
        for ref in data["native"]:
            present(NATIVE / ref["file"], ref["symbol"])
        if not data["native"]:
            assert act == "lib/pages/video/introduction/ugc/widgets/menu_row.dart:95"
            if checkout:
                header = pinned("lib/pages/video/widgets/header_control.dart")
                section = header.split("if (PlatformUtils.isDesktop) ...[")[-1].split("],", 1)[0]
                assert section.count("ActionIconItem(") == 2
                inst = git("grep", "-nF", "ActionIconItem(", BASE, "--", "lib")
                assert len(inst.splitlines()) == 3  # Two uses and the widget constructor.
    check_stamp()
    print("PASS", len(audit["records"]), "interface record IDs,", len(actions), "haptic source actions;",
          "pinned Git sources checked;" if checkout else "Native archive (upstream comparison skipped);",
          "synthetic build stamp and native plist")
    print(dict(Counter(i["verdict"] for i in audit["records"].values())))


if __name__ == "__main__":
    main()
