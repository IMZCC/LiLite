"""Trace fixed upstream unary RPC wrappers and audit residual HTTP aliases, without contacting a service."""
import json
from functools import lru_cache
from pathlib import Path
import re
import subprocess
from account_routes import BASE, ROOT
from http_surface import rows as http_rows

NATIVE = ROOT / "Native"
EVIDENCE = NATIVE / "Acceptance/evidence"
def no_comments(text):
    text = re.sub(r"/\*[\s\S]*?\*/", lambda m: "\n" * m[0].count("\n"), text)
    return "\n".join("" if line.lstrip().startswith("//") else line for line in text.splitlines())
@lru_cache
def source(path):
    return subprocess.check_output(["git","-C",str(ROOT),"show",BASE+":"+path],encoding="utf-8")
def unique(pairs):
    obj = dict(pairs)
    if len(obj) != len(pairs): raise ValueError("duplicate key")
    return obj
def read(f):
    return json.loads(f.read_text(encoding="utf-8"),object_pairs_hook=unique)
def anchor(root, item):
    name = Path(item["file"])
    assert not name.is_absolute() and ".." not in name.parts and item["symbol"], item
    if root == ROOT and (ROOT/".git").exists(): text=source(name.as_posix())
    else:
        p = root/name
        if root == ROOT and not p.exists(): return
        text=p.read_text(encoding="utf-8")
    assert item["symbol"] in text, item
def rpc_source():
    base_file="lib/grpc/url.dart"
    consts=dict(re.findall(r"static const (\w+)\s*=\s*'([^']+)';",no_comments(source(base_file))))
    for k,v in list(consts.items()):
        consts[k]=re.sub(r"\$(\w+)",lambda m:consts[m[1]],v)
    gs={}
    for f in ("audio","dm","dyn","im","reply","space","view"):
        path=f"lib/grpc/{f}.dart"
        code=no_comments(source(path))
        klass=re.search(r"class (\w+Grpc)\b",code)[1]
        defs=list(re.finditer(r"\bstatic\s+Future[^\n]*?\b(\w+)\s*\(",code))
        for i,decl in enumerate(defs):
            body=code[decl.end():defs[i+1].start() if i+1<len(defs) else len(code)]
            for key in re.findall(r"\bGrpcUrl\.(\w+)",body):
                fn=klass+"."+decl[1]
                assert key not in gs and fn not in (v["method"] for v in gs.values())
                gs[key]={"method":fn,"rpc":consts[key],"wrapper":{"file":path,"symbol":"GrpcUrl."+key},"calls":[]}
    keys={v["method"]:v for v in gs.values()}
    invocation=r"\b("+"|".join(re.escape(k) for k in keys)+r")\b"
    paths=subprocess.check_output(["git","-C",str(ROOT),"grep","-l","-E",r"(Audio|Dm|Dyn|Im|Reply|Space|View)Grpc\.",BASE,"--","lib"],encoding="utf-8")
    for p in paths.splitlines():
        path=p.split(":",1)[1]
        if path.startswith("lib/grpc/"):continue
        for line,code in enumerate(no_comments(source(path)).splitlines(),1):
            for name in re.findall(invocation,code):
                keys[name]["calls"].append({"file":path,"line":line,"symbol":name})
    return gs
def validate():
    g=read(EVIDENCE/"grpc-service-matrix.json");h=read(EVIDENCE/"http-service-matrix.json")
    sign=read(EVIDENCE/"service-protocol-signoff.json")
    assert all(x["baseline"]==BASE for x in (g,h,sign))
    has_git=(ROOT/".git").exists()
    if has_git:
        actual=rpc_source()
        assert g["methods"].keys()==actual.keys()
    for key,v in g["methods"].items():
        if has_git:
            for f in ("wrapper","rpc","method","calls"): assert v[f]==actual[key][f],(key,f)
        if v["calls"]:
            assert v["verdict"]=="native-rpc" and v["consumers"] and v["behavior"] and v["evidence"],key
        else:
            assert v["verdict"]=="unused-upstream-wrapper",key
        for ref in v["consumers"]:anchor(NATIVE,ref)
        assert all((NATIVE/f).is_file() for f in v["evidence"])
    if has_git:
        http={x[1]:x for x in http_rows()}
        assert h["constants"].keys()==http.keys()
    for key,v in h["constants"].items():
        if has_git:
            row=http[key]
            assert (v["host"],v["path"],v["upstream_constant_line"]) == (row[2],row[3],int(row[4])),key
            if row[0]=="inspect": assert v["verdict"] not in {"literal-index-only","no-upstream-constant-reference"},key
            if row[0]=="no-baseline-call":assert v["verdict"]=="no-upstream-constant-reference",key
        for ref in v.get("native",[]):anchor(NATIVE,ref)
        for ref in v.get("upstream_control",[]):anchor(ROOT,ref)
        assert v["verdict"],key
    record=sign["records"]["subsystem:grpc"]
    anchor(ROOT,record["upstream"])
    for ref in record["consumers"]:anchor(NATIVE,ref)
    assert record["verdict"]=="implemented" and all((NATIVE/p).is_file() for p in record["evidence"])
    print(f"Protocol matrix: {len(g['methods'])} unary wrappers, {sum(bool(v['calls']) for v in g['methods'].values())} with executable upstream callers; {len(h['constants'])} HTTP constants, each current nonliteral request reviewed")
if __name__=="__main__":validate()
