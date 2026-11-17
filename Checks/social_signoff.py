"""Check each social/account ledger anchor against the pinned Flutter source and current Swift consumers."""
import json
import subprocess
from collections import Counter
from pathlib import Path

native = Path(__file__).resolve().parents[1]
root = native.parent
baseline = "d9e9626f1a3f89cd9ca85e18f61aaba02634e12a"
manifest = json.loads((native/"parity.json").read_text(encoding="utf8"))
source_cache = {}
native_cache = {}
all_records = {}
for name in ("account-messages-signoff.json","social-reading-signoff.json"):
    ledger = json.loads((native/"Acceptance/evidence"/name).read_text(encoding="utf8"))
    assert ledger["baseline"] == baseline and ledger["domain"]
    for key,row in ledger["records"].items():
        assert key in manifest and key not in all_records,key
        assert row["ownership"] and row["fixed_actions"] and row["behavior"],key
        assert row["verdict"] in {"verified","implemented","partial","not-ios"},key
        if row["verdict"]=="partial":
            assert row["device_or_remaining"],key
        cited = row["upstream"]; f = cited["file"]
        if f not in source_cache:
            source_cache[f] = subprocess.check_output(["git","show",baseline+":"+f],cwd=root).decode("utf8")
        assert cited["symbol"] in source_cache[f],(key,cited)
        assert row["consumers"] and row["evidence"],key
        for item in row["consumers"]:
            path = (native/item["file"]).resolve()
            assert path.is_relative_to(native) and path.suffix==".swift",(key,path)
            if path not in native_cache:
                native_cache[path] = path.read_text(encoding="utf8")
            assert item["symbol"] in native_cache[path],(key,item)
        for f in row["evidence"]:
            path=(native/f).resolve()
            assert path.is_relative_to(native) and path.is_file(),(key,f)
        all_records[key]=row
    print(name, dict(Counter(x["verdict"] for x in ledger["records"].values())))
assert {"page:login","page:space_setting","page:msg_feed_top","page:whisper_detail","page:dynamics_detail","page:dynamics_create","page:article","screen:video/note","screen:video/reply_new"} <= all_records.keys()
print(f"{len(all_records)} unique IDs; {len(source_cache)} pinned sources; {len(native_cache)} native consumers")
