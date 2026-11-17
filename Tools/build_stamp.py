"""Stamp only the staged app plist, never infer a git identity from an unrelated parent."""
from pathlib import Path
import argparse, datetime, json, os, plistlib, re, subprocess

def sdk_metadata(sdk):
    settings = json.loads((sdk / "SDKSettings.json").read_text(encoding="utf-8"))
    version = settings["Version"]
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", version):
        raise ValueError("Invalid iOS SDK version")
    if settings.get("CanonicalName") != "iphoneos" + version:
        raise ValueError("An iPhoneOS device SDK is required")
    with (sdk / "System/Library/CoreServices/SystemVersion.plist").open("rb") as f:
        system = plistlib.load(f)
    if system["ProductVersion"] != version:
        raise ValueError("SDK settings and system version differ")
    return version, {
        "DTSDKName": settings["CanonicalName"],
        "DTSDKBuild": system["ProductBuildVersion"],
        "DTPlatformName": "iphoneos",
        "DTPlatformVersion": version,
    }

def revision(native, env):
    explicit = env.get("PILI_SOURCE_REV")
    if explicit is not None:
        if not re.fullmatch(r"[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?", explicit):
            raise ValueError("PILI_SOURCE_REV must be a full Git object ID")
        return explicit.lower()
    repo = native.resolve().parent
    if not (repo / ".git").exists():
        return None
    try:
        root = Path(subprocess.check_output(["git", "-C", str(repo), "rev-parse", "--show-toplevel"], text=True).strip()).resolve()
        if root != repo: return None
        subprocess.run(["git", "-C", str(repo), "ls-files", "--error-unmatch", "Native/build.sh"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    except (OSError, subprocess.CalledProcessError): return None

def stamp(native, dest, sdk=None, compiled_sdk=None):
    if compiled_sdk is not None and (sdk is None or sdk.resolve() != compiled_sdk.resolve()):
        raise ValueError("PILI_IOS_SDK differs from the SDK selected for Swift compilation")
    with dest.open("rb") as f: values=plistlib.load(f)
    rev=revision(native, os.environ)
    if rev: values["PiliNativeSourceRevision"]=rev
    else: values.pop("PiliNativeSourceRevision",None)
    epoch=os.environ.get("SOURCE_DATE_EPOCH")
    now=datetime.datetime.fromtimestamp(int(epoch),datetime.timezone.utc) if epoch else datetime.datetime.now(datetime.timezone.utc)
    values["PiliNativeBuildDate"]=now.replace(microsecond=0).isoformat().replace("+00:00","Z")
    version = None
    if sdk is not None:
        version, metadata = sdk_metadata(sdk)
        values.update(metadata)
    with dest.open("wb") as f: plistlib.dump(values,f,sort_keys=False)
    return version

if __name__=="__main__":
    ap=argparse.ArgumentParser();ap.add_argument("--root",type=Path,required=True);ap.add_argument("--plist",type=Path,required=True)
    ap.add_argument("--sdk",type=Path)
    ap.add_argument("--compiled-sdk",type=Path)
    ap.add_argument("--print-sdk-version",action="store_true")
    args=ap.parse_args()
    if args.print_sdk_version and args.sdk is None: ap.error("--print-sdk-version requires --sdk")
    version=stamp(args.root,args.plist,args.sdk,args.compiled_sdk)
    if args.print_sdk_version: print(version)
