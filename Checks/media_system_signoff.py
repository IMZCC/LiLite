"""Verify actual upstream consumers and the native-media ledger; no sockets or accounts."""
import json
import subprocess
from functools import lru_cache
from pathlib import Path

native = Path(__file__).resolve().parents[1]
root = native.parent
base = "d9e9626f1a3f89cd9ca85e18f61aaba02634e12a"
def unique(pairs):
    d = dict(pairs)
    if len(d) != len(pairs):
        raise ValueError("duplicate record key")
    return d
def get(p):
    return json.loads(p.read_text(encoding="utf-8"), object_pairs_hook=unique)
def safe(dir, rel):
    assert rel and not Path(rel).is_absolute() and ".." not in Path(rel).parts, rel
    p = (dir/rel).resolve()
    assert p.is_relative_to(dir.resolve()), rel
    return p
@lru_cache
def pinned(f):
    p = safe(root, f)
    if (root/".git").exists():
        return subprocess.check_output(["git","-C",str(root),"show",base+":"+f], encoding="utf-8")
    return p.read_text(encoding="utf-8") if p.is_file() else None
report = get(native/"Acceptance/evidence/media-system-signoff.json")
records = report["records"]
assert report["baseline"] == base and report["domain"] == "native-media-network-system"
assert records.keys() <= get(native/"parity.json").keys()
required = ("CDNService cdnSpeedTest disableAudioCDN defaultVideoQa defaultVideoQaCellular defaultAudioQa "
            "defaultAudioQaCellular preferCodecs preferCodecsCellular liveCdnUrl liveQuality liveQualityCellular "
            "enableHA hardwareDecoding p1080 enableSystemProxy systemProxyHost systemProxyPort badCertificateCallback "
            "enableHttp2 retryCount retryDelay openInBrowser defaultPicQa previewQuality enableLivePhoto enableImgMenu "
            "horizontalPreview silentDownImg maxCacheSize imageSavePath autoPiP pauseOnMinimize continuePlayInBackground "
            "audioOutput superResolutionType bufferSize bufferSec liveBufferSize liveBufferSec autosync videoSync "
            "audioNormalization fallbackNormalization").split()
assert {"preference:SettingBoxKey/"+k for k in required} == {k for k in records if k.startswith("preference:")}
assert "platform:ios/Runner/PipPlugin.swift" in records
for k,v in records.items():
    assert set(v)=={"verdict","upstream","consumers","behavior","evidence","device_or_remaining"}, k
    assert v["verdict"] in {"implemented","verified","platform-equivalent","not-ios","partial"}, k
    assert v["behavior"] and v["consumers"] and v["evidence"]
    f,a = v["upstream"]["file"],v["upstream"]["symbol"]
    t = pinned(f)
    assert a and (t is None or a in t), (k,f,a)
    for row in v["consumers"]:
        assert row["symbol"] and row["symbol"] in safe(native,row["file"]).read_text(encoding="utf-8"),(k,row)
    for path in v["evidence"]:
        assert safe(native,path).is_file(),(k,path)
assert records["preference:SettingBoxKey/badCertificateCallback"]["verdict"] == "implemented"
print(f"Native media: {len(records)} records, {len(required)} settings; pinned operations, native consumers and evidence verified")
