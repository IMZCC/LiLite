"""Stage Firebase's official static iOS frameworks and their resources for xtool."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from zipfile import ZipFile

VERSION = "13.2.0"
SHA256 = "528356de371830b3bbd0c32dbb649c080c8d36a6ef3d057590739eff6deaefcb"
PRODUCTS = {
    "FirebaseAnalytics": (
        "FirebaseAnalytics", "GoogleAppMeasurement", "FirebaseCore", "FirebaseCoreInternal",
        "FirebaseInstallations", "GoogleUtilities", "FBLPromises", "nanopb",
    ),
    "FirebaseCrashlytics": (
        "FirebaseCrashlytics", "FirebaseSessions", "FirebaseCoreExtension",
        "GoogleDataTransport", "FirebaseRemoteConfigInterop",
    ),
}


def verified_archive():
    cache = Path.home() / ".cache/lilite-firebase"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f"Firebase-{VERSION}.zip"
    if archive.exists():
        with archive.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() == SHA256:
                return archive
    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as stream:
        temp = Path(stream.name)
    try:
        url = f"https://github.com/firebase/firebase-ios-sdk/releases/download/{VERSION}/Firebase.zip"
        subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(temp), url], check=True)
        with temp.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != SHA256:
                raise ValueError("Firebase SDK checksum mismatch")
        temp.replace(archive)
    finally:
        temp.unlink(missing_ok=True)
    return archive


def stage(root, work):
    dest = work / "FirebaseSDK"
    resources = []
    with ZipFile(verified_archive()) as sdk:
        dest.mkdir(exist_ok=True)
        for product, names in PRODUCTS.items():
            for name in names:
                prefix = f"Firebase/{product}/{name}.xcframework/ios-arm64/"
                framework = dest / f"{name}.framework"
                for item in sdk.infolist():
                    if item.is_dir() or not item.filename.startswith(prefix):
                        continue
                    path = dest / item.filename.removeprefix(prefix)
                    path.parent.mkdir(parents=True, exist_ok=True)
                    # Preserve mtimes for unchanged headers between incremental builds.
                    data = sdk.read(item)
                    if not path.exists() or path.read_bytes() != data:
                        path.write_bytes(data)
                if not (framework / name).is_file():
                    raise ValueError(f"Missing Firebase device framework: {name}")
                resources.extend(sorted(framework.glob("*.bundle")))
        notices = dest / "Firebase-NOTICES.txt"
        notices.write_bytes(sdk.read("Firebase/NOTICES"))
        resources.append(notices)
    config = Path(os.environ.get("LILITE_FIREBASE_PLIST", root / "Resources/GoogleService-Info.plist"))
    with config.open("rb") as stream:
        values = plistlib.load(stream)
    if values.get("BUNDLE_ID") != "com.liuliuya.PiliNative" or not all(
        values.get(key) for key in ("GOOGLE_APP_ID", "PROJECT_ID", "GCM_SENDER_ID", "API_KEY")
    ):
        raise ValueError("Expected the Firebase Apple configuration for com.liuliuya.PiliNative")
    staged = work / "Resources/GoogleService-Info.plist"
    shutil.copyfile(config, staged)
    resources.append(staged)
    with (work / "xtool.yml").open("a") as manifest:
        manifest.write("\nresources:\n")
        for resource in resources:
            manifest.write(f"  - {resource.relative_to(work)}\n")


if __name__ == "__main__":
    stage(Path(sys.argv[1]), Path(sys.argv[2]))
