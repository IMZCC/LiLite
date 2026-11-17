"""Validate the 31 fixed common page inputs, their direct Dart consumers and the native action anchors."""
import json
import re
import subprocess
import tempfile
from pathlib import Path

n = Path(__file__).resolve().parents[1]
r = n.parent
b = "d9e9626f1a3f89cd9ca85e18f61aaba02634e12a"
def git(*args):
    return subprocess.check_output(["git", *args], cwd=r).decode()
def source(file):
    return git("show", f"{b}:{file}")
def get_importers():
    result = {}
    for line in git("grep", "-n", "-e", "package:PiliPlus/pages/common/", b, "--", "lib").splitlines():
        hit = re.match(r"[^:]+:([^:]+):\d+:.*?(?:import|export)\s+['\"]package:PiliPlus/(pages/common/[^'\"]+\.dart)['\"]", line)
        if hit: result.setdefault("lib/"+hit[2], set()).add(hit[1])
    return result
manifest = json.loads((n/"parity.json").read_text())
ledger = json.loads((n/"Acceptance/evidence/common-page-actions.json").read_text())
assert ledger["baseline"] == b
files = set(git("ls-tree","-r","--name-only",b,"lib/pages/common").splitlines())
assert files == {e["upstream"] for dd in ledger["directories"].values() for e in dd}
orig = get_importers()
for directory, entries in ledger["directories"].items():
    for row in entries:
        p = row["upstream"]
        assert Path(p).parent.as_posix() == directory
        assert row["source_symbol"] in source(p)
        assert row["actions"] and row["native"]
        assert sorted(orig.get(p, set())) == row["direct_importers"], p
        for node in row["native"]:
            f = (n/node["file"]).resolve()
            assert f.is_relative_to(n) and node["symbol"] in f.read_text(), node
for k, v in ledger["records"].items():
    assert k in manifest and v["verdict"] == "implemented"
readme = source("README.md").splitlines()
scope = json.loads((n/"Acceptance/evidence/common-readme-scope.json").read_text())
assert scope["baseline"] == b
for k, row in scope["entries"].items():
    line = row["line"]
    assert k in manifest and readme[line-1] == row["literal"]
    blame = git("blame","--line-porcelain","-L",f"{line},{line}",b,"--","README.md").splitlines()[0].split()[0]
    assert row["introduced_by_blame"] == blame
    if row["disposition"] == "unspecified-summary":
        assert row["eligible"] is False and not row["children"]
    else:
        children = []
        for x in readme[line:]:
            if not x.startswith("  - [x] "): break
            children.append("upstream:功能/"+x[8:].strip())
        assert children == row["children"] and all(i in manifest for i in children)
with tempfile.TemporaryDirectory() as work:
    p = Path(work)
    m = p/"main.swift"
    m.write_text('''import Foundation
var b = PageBoundary()
precondition(b.next("1",after:nil,reset:true) == "1")
precondition(b.next("2",after:"1",reset:false) == "2")
precondition(b.next("1",after:"2",reset:false) == nil)
precondition(b.next("1",after:nil,reset:true) == "1")
precondition(b.next("",after:"1",reset:false) == nil)
b.failed(refresh:false); precondition(!b.failedRefresh)
b.failed(refresh:true); precondition(b.failedRefresh)
precondition(!PageBoundary.nearFooter(y:2000,height:640) && !PageBoundary.nearFooter(y:20,height:0))
precondition(PageBoundary.nearFooter(y:644,height:640) && !PageBoundary.nearFooter(y:-5,height:640))
''')
    exe=p/"run"
    subprocess.run(["swiftc", str(n/"Sources/PiliNative/Library/PageBoundary.swift"), str(m), "-o", str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print(f"PASS: {len(files)} pinned Dart inputs, {len(ledger['directories'])} directories, five literal README entries, paging failure and visibility state")
