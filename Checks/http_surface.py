"""Cross-reference pinned Dart HTTP capabilities and native implementation locations for manual review."""
import argparse
import csv
import json
from collections import Counter, defaultdict
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit

from account_routes import BASE, ROOT, source

def definitions(path):
    # Delete full-line comments without treating https:// literals as comments.
    text = "\n".join("" if line.lstrip().startswith("//") else line for line in source(path).splitlines())
    return {m[1]: (m[3], text.count("\n",0,m.start())+1) for m in re.finditer(
        r'''static\s+const\s+(?:String\s+)?(\w+)\s*=\s*(['"])([^'"\r\n]*)\2\s*;''',text)}

def rows():
    paths = definitions("lib/http/api.dart")
    bases = definitions("lib/http/constants.dart")
    refs = defaultdict(set)
    lines = subprocess.check_output(["git","-C",str(ROOT),"grep","-n","-E",r"Api\.[A-Za-z]",BASE,"--","lib","!lib/grpc"],encoding="utf-8").splitlines()
    for line in lines:
        _, file, number, code = line.split(":",3)
        if file in ("lib/utils/accounts/api_type.dart","lib/http/api.dart") or code.lstrip().startswith(("//","*")): continue
        for name in re.findall(r"\bApi\.(\w+)",code): refs[name].add(file+":"+number)
    native = ROOT / "Native"
    sources = [p for base in ("Sources/PiliNative","Wire/Sources/PiliWire") for p in (native/base).rglob("*.swift")
               if p.name != "AccountServices.swift" and "Generated" not in p.parts and not p.name.endswith(".pb.swift")]
    tokens = defaultdict(set)
    for file in sources:
        for line,code in enumerate(file.read_text("utf-8").splitlines(),1):
            if code.lstrip().startswith("//"): continue
            for value in re.findall(r'"((?:https?://|/)[^"\s]*)"',code):
                path = urlsplit(value).path if value.startswith(("http:","https:")) else value.split("?",1)[0]
                tokens[path].add(file.relative_to(native).as_posix()+":"+str(line))
    for name,(raw,line) in paths.items():
        uri = re.sub(r"\$\{HttpString\.(\w+)\}",lambda m:bases[m[1]][0],raw)
        u = urlsplit(bases["apiBaseUrl"][0] + uri if uri.startswith("/") else uri)
        uses = sorted(refs[name])
        matches = sorted(tokens[u.path])
        status = "no-baseline-call" if not uses else "native-path" if matches else "inspect"
        yield (status,name,u.netloc,u.path,str(line),";".join(uses),";".join(matches))

if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--output",type=Path)
    parser.add_argument("--reviewed-output",type=Path,help="Write the path index plus the audited cross-client disposition for each constant.")
    args=parser.parse_args()
    result=list(rows())
    print("Pinned HTTP constants and call sites:",dict(sorted(Counter(row[0] for row in result).items())))
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        with args.output.open("w",encoding="utf-8",newline="\n") as out:
            out.write("status\tconstant\thost\tpath\tbaseline_definition_line\tbaseline_uses\tnative_path_references\n")
            for row in result: out.write("\t".join(row)+"\n")

    if args.reviewed_output:
        ledger=json.loads((ROOT/"Native/Acceptance/evidence/http-service-matrix.json").read_text(encoding="utf-8"))
        if ledger["baseline"]!=BASE or set(ledger["constants"])!={r[1] for r in result}:
            raise ValueError("The reviewed HTTP ledger is not for this baseline")
        args.reviewed_output.parent.mkdir(parents=True,exist_ok=True)
        with args.reviewed_output.open("w",encoding="utf-8",newline="") as out:
            tab=csv.writer(out,delimiter="\t",lineterminator="\n")
            tab.writerow(["scan","constant","host","path","review","upstream_call","native_consumer","notes"])
            for scan,k,host,path,_,calls,locations in result:
                v=ledger["constants"][k]
                if scan=="inspect" and v["verdict"]=="literal-index-only":
                    raise ValueError("Missing native consumer: "+k)
                native=";".join(row["file"]+"@"+row["symbol"] for row in v.get("native",[]))
                tab.writerow([scan,k,host,path,v["verdict"],calls,native or locations,v.get("review","")])
