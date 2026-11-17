"""Generate exact host + path attribution for account-specific HTTP services at the port baseline."""
import argparse, json, re, subprocess
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]
BASE = "d9e9626f1a3f89cd9ca85e18f61aaba02634e12a"
OUTPUT = ROOT / "Native/Sources/PiliNative/Account/AccountServices.swift"
def source(path):
    return subprocess.check_output(["git", "-C", str(ROOT), "show", BASE + ":" + path]).decode()
def definitions(path):
    return {key:value for key, _, value in re.findall(r"""static const (?:String )?(\w+)\s*=\s*(['"])(.*?)\2\s*;""", source(path), re.S)}
def render():
    api = definitions("lib/http/api.dart")
    base = definitions("lib/http/constants.dart")
    raw = re.sub(r"//[^\n]*", "", source("lib/utils/accounts/api_type.dart"))
    entries = {}
    for role, members in re.findall(r"AccountType\.(\w+):\s*\{([^}]+)\}",raw):
        for key in re.findall(r"Api\.(\w+)",members):
            address = re.sub(r"\$\{HttpString\.(\w+)\}",lambda m:base[m[1]],api[key])
            u = urlsplit(base["apiBaseUrl"] + address if address.startswith("/") else address)
            assert u.scheme=="https" and u.netloc and u.path and not u.query and "$" not in u.path, key
            name = u.netloc + u.path
            assert name not in entries, name
            entries[name]=role
    return "// Generated from the pinned ApiType table by Checks/account_routes.py\nextension AccountRoutes {\n  static let services: [String:AccountRole] = [\n" + "".join("    "+json.dumps(name)+": ."+role+",\n" for name,role in sorted(entries.items()))+"  ]\n}\n"
if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("--write",action="store_true");args=p.parse_args()
    generated=render()
    if args.write: OUTPUT.write_text(generated,encoding="utf-8",newline="\n")
    elif OUTPUT.read_text(encoding="utf-8")!=generated: raise SystemExit("Account routing table differs from the pinned upstream")
